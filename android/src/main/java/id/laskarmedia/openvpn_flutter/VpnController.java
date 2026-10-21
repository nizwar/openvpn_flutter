package id.laskarmedia.openvpn_flutter;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.RemoteException;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CopyOnWriteArraySet;

import de.blinkt.openvpn.VpnProfile;
import de.blinkt.openvpn.core.ConnectionStatus;
import de.blinkt.openvpn.core.LogItem;
import de.blinkt.openvpn.core.OpenVPNManagement;
import de.blinkt.openvpn.core.OpenVPNService;
import de.blinkt.openvpn.core.OpenVPNThread;
import de.blinkt.openvpn.core.ProfileManager;
import de.blinkt.openvpn.core.VPNLaunchHelper;
import de.blinkt.openvpn.core.VpnStatus;

/**
 * Process-wide view of the VPN connection.
 * <p>
 * The VPN service runs in the app process and outlives any FlutterEngine (and
 * activity), so the connection state lives here rather than in a plugin
 * instance. Every attached plugin instance registers a {@link Listener}.
 * All state is read and written on the main thread.
 */
final class VpnController implements VpnStatus.StateListener, VpnStatus.ByteCountListener, VpnStatus.LogListener {
    private static final String TAG = "OpenVPNFlutter";

    /** How often an armed session timeout is checked while no traffic flows. */
    private static final long EXPIRY_CHECK_INTERVAL_MS = 15_000;
    /** A stop requested before the engine is listening is retried this often... */
    private static final long STOP_RETRY_INTERVAL_MS = 500;
    /** ...for at most this long. */
    private static final int STOP_RETRY_ATTEMPTS = 20;

    interface Listener {
        void onStage(@NonNull String stage);

        void onLog(@NonNull Map<String, Object> log);
    }

    /** A connect() or requestPermission() waiting for the user to answer the VPN dialog. */
    static final class PendingPermission {
        @Nullable
        final VpnProfile profile;
        final long expireAt;
        @NonNull
        final ResultCallback callback;

        PendingPermission(@Nullable VpnProfile profile, long expireAt, @NonNull ResultCallback callback) {
            this.profile = profile;
            this.expireAt = expireAt;
            this.callback = callback;
        }
    }

    interface ResultCallback {
        void success(boolean granted);

        void error(@NonNull String code, @Nullable String message);
    }

    private static VpnController instance;

    private final Context context;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Set<Listener> listeners = new CopyOnWriteArraySet<>();

    private String stage = "disconnected";
    private long connectedSince;
    private long bytesIn;
    private long bytesOut;
    private long speedIn;
    private long speedOut;
    @Nullable
    private String lastError;
    @Nullable
    private String lastExitReason;

    /** Between a connect() and the end of that connection. */
    private boolean connectionRequested;
    /** The current connection is being stopped on purpose (disconnect, timeout). */
    private boolean stopRequested;

    private long expireAt;
    private final Runnable expiryCheck = this::checkExpiry;
    private int stopRetriesLeft;
    private final Runnable stopRetry = this::retryStop;

    @Nullable
    private PendingPermission pendingPermission;

    static synchronized VpnController get(@NonNull Context context) {
        if (instance == null) {
            instance = new VpnController(context.getApplicationContext());
        }
        return instance;
    }

    /** The controller if a plugin instance created it in this process. */
    @Nullable
    static synchronized VpnController peek() {
        return instance;
    }

    private VpnController(Context context) {
        this.context = context;
        VpnStatus.initLogCache(context.getCacheDir());
        // Each of these replays the current value immediately.
        VpnStatus.addLogListener(this);
        VpnStatus.addByteCountListener(this);
        VpnStatus.addStateListener(this);
    }

    void addListener(@NonNull Listener listener) {
        listeners.add(listener);
    }

    void removeListener(@NonNull Listener listener) {
        listeners.remove(listener);
    }

    @NonNull
    String getStage() {
        return stage;
    }

    @Nullable
    String getLastError() {
        return lastError;
    }

    boolean isActive() {
        return connectionRequested || !"disconnected".equals(stage) || VpnStatus.isVPNActive();
    }

    @NonNull
    Map<String, Object> getStatus() {
        Map<String, Object> status = new HashMap<>();
        boolean connected = "connected".equals(stage) && connectedSince > 0;
        status.put("connected_on", connected ? connectedSince : null);
        status.put("byte_in", bytesIn);
        status.put("byte_out", bytesOut);
        status.put("speed_in", speedIn);
        status.put("speed_out", speedOut);
        return status;
    }

    @NonNull
    List<Map<String, Object>> getLogs() {
        List<Map<String, Object>> logs = new ArrayList<>();
        for (LogItem item : VpnStatus.getlogbuffer()) {
            logs.add(toMap(item));
        }
        return logs;
    }

    // region Connect / disconnect

    /** Starts the VPN service with [profile]. The VPN permission must already be granted. */
    void start(@NonNull VpnProfile profile, long expireAt) {
        main.removeCallbacks(stopRetry);
        lastError = null;
        lastExitReason = null;
        stopRequested = false;
        connectionRequested = true;
        // A new session (possibly replacing a running one, which the engine handles).
        connectedSince = 0;
        bytesIn = 0;
        bytesOut = 0;
        speedIn = 0;
        speedOut = 0;
        ProfileManager.setTemporaryProfile(context, profile);
        VPNLaunchHelper.startOpenVpn(profile, context);
        armExpiry(expireAt);
    }

    /** Stops the VPN if one is running or starting. Safe to call at any time. */
    void stop() {
        disarmExpiry();
        if (!isActive()) {
            connectionRequested = false;
            return;
        }
        stopRequested = true;
        emitStage("disconnecting");
        ProfileManager.setConntectedVpnProfileDisconnected(context);
        stopRetriesLeft = STOP_RETRY_ATTEMPTS;
        requestServiceStop();
    }

    /**
     * Asks the running service to stop OpenVPN. Right after connect() the
     * engine may not listen yet; the stop is then retried until it does.
     */
    private void requestServiceStop() {
        Intent intent = new Intent(context, OpenVPNService.class);
        intent.setAction(OpenVPNService.START_SERVICE);
        ServiceConnection connection = new ServiceConnection() {
            @Override
            public void onServiceConnected(ComponentName name, IBinder binder) {
                boolean stopped = false;
                if (binder instanceof OpenVPNService.LocalBinder) {
                    try {
                        stopped = ((OpenVPNService.LocalBinder) binder).getService().stopVPN(false);
                    } catch (RemoteException e) {
                        Log.w(TAG, "Graceful stop failed", e);
                    }
                }
                safeUnbind(this);
                if (!stopped) {
                    scheduleStopRetry();
                }
            }

            @Override
            public void onServiceDisconnected(ComponentName name) {
            }
        };
        boolean bound = false;
        try {
            bound = context.bindService(intent, connection, Context.BIND_AUTO_CREATE);
        } catch (SecurityException e) {
            Log.w(TAG, "Could not bind to OpenVPNService", e);
        }
        if (!bound) {
            scheduleStopRetry();
        }
    }

    private void scheduleStopRetry() {
        main.removeCallbacks(stopRetry);
        if (stopRetriesLeft-- > 0) {
            main.postDelayed(stopRetry, STOP_RETRY_INTERVAL_MS);
        } else {
            // The engine never answered: end the process directly, and stop
            // reporting a connection that is not there.
            OpenVPNThread.stop();
            main.postDelayed(() -> {
                if (stopRequested && !"disconnected".equals(stage)) {
                    resetConnection();
                    emitStage("disconnected");
                }
            }, STOP_RETRY_INTERVAL_MS * 4);
        }
    }

    private void retryStop() {
        if (stopRequested && isActive()) {
            requestServiceStop();
        }
    }

    private void safeUnbind(ServiceConnection connection) {
        try {
            context.unbindService(connection);
        } catch (IllegalArgumentException ignored) {
            // Already unbound.
        }
    }

    // endregion

    // region VPN permission

    /**
     * Registers the operation waiting for the VPN permission dialog. A previous
     * one that never got an answer is resolved as denied.
     */
    void setPendingPermission(@NonNull PendingPermission pending) {
        PendingPermission previous = pendingPermission;
        pendingPermission = pending;
        if (previous != null) {
            previous.callback.success(false);
        }
    }

    /** The system VPN dialog is about to be shown for a connection attempt. */
    void markWaitingForPermission() {
        emitStage("prepare");
    }

    /** Answers the pending permission request. Returns false if there was none. */
    boolean onPermissionResult(boolean granted) {
        PendingPermission pending = pendingPermission;
        if (pending == null) {
            return false;
        }
        pendingPermission = null;
        if (!granted) {
            if (pending.profile != null) {
                // The attempt ends here: report the refusal, then the idle state.
                emitStage("denied");
                emitStage("disconnected");
            }
            pending.callback.success(false);
            return true;
        }
        if (pending.profile == null) {
            pending.callback.success(true);
            return true;
        }
        try {
            start(pending.profile, pending.expireAt);
            pending.callback.success(true);
        } catch (RuntimeException e) {
            Log.e(TAG, "Could not start the VPN service", e);
            connectionRequested = false;
            pending.callback.error("start_failed", e.getMessage());
        }
        return true;
    }

    // endregion

    // region Session timeout

    private void armExpiry(long expireAt) {
        disarmExpiry();
        this.expireAt = expireAt;
        if (expireAt > 0) {
            main.post(expiryCheck);
        }
    }

    private void disarmExpiry() {
        expireAt = 0;
        main.removeCallbacks(expiryCheck);
    }

    /**
     * Uses the wall clock, which keeps counting while the device sleeps;
     * handler delays alone would not.
     */
    private void checkExpiry() {
        main.removeCallbacks(expiryCheck);
        if (expireAt <= 0) {
            return;
        }
        long remaining = expireAt - System.currentTimeMillis();
        if (remaining <= 0) {
            VpnStatus.logInfo("Session expired, disconnecting");
            stop();
            return;
        }
        main.postDelayed(expiryCheck, Math.min(remaining, EXPIRY_CHECK_INTERVAL_MS));
    }

    // endregion

    // region VpnStatus listeners (called on engine threads)

    @Override
    public void updateState(String state, String logmessage, int localizedResId, ConnectionStatus level, Intent intent) {
        main.post(() -> onState(state, logmessage, level));
    }

    @Override
    public void setConnectedVPN(String uuid) {
    }

    @Override
    public void updateByteCount(long in, long out, long diffIn, long diffOut) {
        main.post(() -> {
            bytesIn = in;
            bytesOut = out;
            speedIn = Math.max(0, diffIn / OpenVPNManagement.mBytecountInterval);
            speedOut = Math.max(0, diffOut / OpenVPNManagement.mBytecountInterval);
            if (expireAt > 0 && System.currentTimeMillis() >= expireAt) {
                checkExpiry();
            }
        });
    }

    @Override
    public void newLog(LogItem logItem) {
        Map<String, Object> log = toMap(logItem);
        main.post(() -> {
            if (logItem.getLogLevel() == VpnStatus.LogLevel.ERROR) {
                lastError = (String) log.get("message");
            }
            for (Listener listener : listeners) {
                listener.onLog(log);
            }
        });
    }

    // endregion

    private void onState(String state, String message, ConnectionStatus level) {
        String mapped = mapState(state, level);
        switch (mapped) {
            case "connected":
                if (connectedSince == 0) {
                    connectedSince = System.currentTimeMillis();
                }
                break;
            case "exiting":
                lastExitReason = message;
                break;
            case "disconnected":
                boolean intended = stopRequested || isSignalExit(lastExitReason);
                boolean failed = connectionRequested && !intended
                        && !"auth_failed".equals(stage) && !"denied".equals(stage)
                        && !"disconnected".equals(stage);
                if (failed) {
                    if (lastError == null) {
                        lastError = "The OpenVPN process stopped unexpectedly";
                    }
                    emitStage("error");
                }
                resetConnection();
                break;
            default:
                break;
        }
        emitStage(mapped);
    }

    private void resetConnection() {
        main.removeCallbacks(stopRetry);
        connectedSince = 0;
        bytesIn = 0;
        bytesOut = 0;
        speedIn = 0;
        speedOut = 0;
        connectionRequested = false;
        stopRequested = false;
        lastExitReason = null;
        disarmExpiry();
    }

    private void emitStage(String newStage) {
        if (newStage.equals(stage)) {
            return;
        }
        stage = newStage;
        for (Listener listener : listeners) {
            listener.onStage(newStage);
        }
    }

    /** OpenVPN reports the signal that ended it; SIGINT/SIGTERM mean someone stopped it. */
    private static boolean isSignalExit(@Nullable String reason) {
        if (reason == null) {
            return false;
        }
        String upper = reason.toUpperCase(Locale.ROOT);
        return upper.contains("SIGINT") || upper.contains("SIGTERM");
    }

    /** Maps ics-openvpn states to the stage names the Dart side understands. */
    @NonNull
    static String mapState(@NonNull String state, @Nullable ConnectionStatus level) {
        switch (state) {
            case "CONNECTED":
                return "connected";
            case "DISCONNECTED":
            case "NOPROCESS":
                return "disconnected";
            case "EXITING":
                return "exiting";
            case "CONNECTING":
                return "connecting";
            case "WAIT":
                return "wait_connection";
            case "AUTH":
                return "authenticating";
            case "GET_CONFIG":
                return "get_config";
            case "ASSIGN_IP":
                return "assign_ip";
            case "ADD_ROUTES":
                return "add_routes";
            case "RECONNECTING":
                return "reconnect";
            case "RESOLVE":
                return "resolve";
            case "TCP_CONNECT":
                return "tcp_connect";
            case "UDP_CONNECT":
                return "udp_connect";
            case "AUTH_PENDING":
            case "NEED":
            case "USER_INPUT":
                return "auth_pending";
            case "AUTH_FAILED":
                return "auth_failed";
            case "VPN_GENERATE_CONFIG":
                return "vpn_generate_config";
            case "NONETWORK":
                return "no_network";
            case "SCREENOFF":
            case "USERPAUSE":
                return "paused";
            case "USER_VPN_PERMISSION":
                return "prepare";
            case "USER_VPN_PERMISSION_CANCELLED":
                return "denied";
            default:
                if (level == ConnectionStatus.LEVEL_AUTH_FAILED) {
                    return "auth_failed";
                }
                return state.toLowerCase(Locale.ROOT);
        }
    }

    @NonNull
    private Map<String, Object> toMap(@NonNull LogItem item) {
        Map<String, Object> log = new HashMap<>();
        log.put("time", item.getLogtime());
        log.put("level", levelName(item.getLogLevel()));
        String message;
        try {
            message = item.getString(context);
        } catch (RuntimeException e) {
            message = item.toString();
        }
        log.put("message", message);
        return log;
    }

    @NonNull
    private static String levelName(@Nullable VpnStatus.LogLevel level) {
        if (level == null) {
            return "info";
        }
        switch (level) {
            case ERROR:
                return "error";
            case WARNING:
                return "warning";
            case VERBOSE:
                return "verbose";
            case DEBUG:
                return "debug";
            case INFO:
            default:
                return "info";
        }
    }
}
