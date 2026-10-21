package id.laskarmedia.openvpn_flutter;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.net.VpnService;
import android.provider.Settings;
import android.text.TextUtils;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.io.IOException;
import java.io.StringReader;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;

import de.blinkt.openvpn.R;
import de.blinkt.openvpn.VpnProfile;
import de.blinkt.openvpn.core.ConfigParser;
import de.blinkt.openvpn.core.OpenVPNService;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/**
 * OpenVPN for Flutter, Android side.
 * <p>
 * The connection itself is owned by {@link VpnController}, shared by every
 * FlutterEngine of the process; this class only bridges one engine to it.
 */
public class OpenVPNFlutterPlugin implements FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
        PluginRegistry.ActivityResultListener, VpnController.Listener {
    private static final String TAG = "OpenVPNFlutter";

    private static final String METHOD_CHANNEL_VPN_CONTROL = "id.laskarmedia.openvpn_flutter/vpncontrol";
    private static final String EVENT_CHANNEL_VPN_STAGE = "id.laskarmedia.openvpn_flutter/vpnstage";
    private static final String EVENT_CHANNEL_VPN_LOG = "id.laskarmedia.openvpn_flutter/vpnlog";

    /**
     * Request code of the system VPN permission dialog. Kept from 1.x, where apps
     * forwarded it from their activity through {@link #connectWhileGranted(boolean)}.
     */
    static final int VPN_PERMISSION_REQUEST_CODE = 24;

    /** Ciphers OpenVPN 2.6+ negotiates by default (--data-ciphers). */
    private static final String DEFAULT_DATA_CIPHERS = "AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305";

    private Context context;
    private VpnController controller;
    private MethodChannel methodChannel;
    private EventChannel stageChannel;
    private EventChannel logChannel;
    @Nullable
    private EventChannel.EventSink stageSink;
    @Nullable
    private EventChannel.EventSink logSink;
    @Nullable
    private ActivityPluginBinding activityBinding;

    /**
     * Not needed anymore: the plugin receives the VPN permission result itself.
     * Calling it is harmless, so apps that still forward the result keep working.
     */
    @Deprecated
    public static void connectWhileGranted(boolean granted) {
        VpnController controller = VpnController.peek();
        // A refusal (or any other request code) reaches the plugin's own
        // activity result listener, which knows the request it belongs to.
        if (granted && controller != null) {
            controller.onPermissionResult(true);
        }
    }

    // region FlutterPlugin

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        controller = VpnController.get(context);

        methodChannel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL_VPN_CONTROL);
        methodChannel.setMethodCallHandler(this);

        stageChannel = new EventChannel(binding.getBinaryMessenger(), EVENT_CHANNEL_VPN_STAGE);
        stageChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                stageSink = events;
                events.success(controller.getStage());
            }

            @Override
            public void onCancel(Object arguments) {
                stageSink = null;
            }
        });

        logChannel = new EventChannel(binding.getBinaryMessenger(), EVENT_CHANNEL_VPN_LOG);
        logChannel.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                logSink = events;
            }

            @Override
            public void onCancel(Object arguments) {
                logSink = null;
            }
        });

        controller.addListener(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        controller.removeListener(this);
        methodChannel.setMethodCallHandler(null);
        stageChannel.setStreamHandler(null);
        logChannel.setStreamHandler(null);
        stageSink = null;
        logSink = null;
    }

    // endregion

    // region ActivityAware

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activityBinding = binding;
        binding.addActivityResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        if (activityBinding != null) {
            activityBinding.removeActivityResultListener(this);
            activityBinding = null;
        }
    }

    @Override
    public boolean onActivityResult(int requestCode, int resultCode, @Nullable Intent data) {
        if (requestCode != VPN_PERMISSION_REQUEST_CODE) {
            return false;
        }
        return controller.onPermissionResult(resultCode == Activity.RESULT_OK);
    }

    @Nullable
    private Activity getActivity() {
        return activityBinding != null ? activityBinding.getActivity() : null;
    }

    // endregion

    // region VpnController.Listener

    @Override
    public void onStage(@NonNull String stage) {
        if (stageSink != null) {
            stageSink.success(stage);
        }
    }

    @Override
    public void onLog(@NonNull Map<String, Object> log) {
        if (logSink != null) {
            logSink.success(log);
        }
    }

    // endregion

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "initialize":
                initialize(call);
                result.success(controller.getStage());
                break;
            case "connect":
                connect(call, result);
                break;
            case "disconnect":
                controller.stop();
                result.success(null);
                break;
            case "stage":
                result.success(controller.getStage());
                break;
            case "status":
                result.success(controller.getStatus());
                break;
            case "request_permission":
                requestPermission(result);
                break;
            case "logs":
                result.success(controller.getLogs());
                break;
            case "last_error":
                result.success(controller.getLastError());
                break;
            case "open_vpn_settings":
                result.success(openVpnSettings());
                break;
            case "dispose":
                result.success(null);
                break;
            default:
                result.notImplemented();
        }
    }

    private void initialize(@NonNull MethodCall call) {
        Boolean showTraffic = call.argument("show_traffic_in_notification");
        if (showTraffic != null) {
            OpenVPNService.setShowByteCountInNotification(showTraffic);
        }
        Boolean stopOnTaskRemoved = call.argument("disconnect_on_task_removed");
        if (stopOnTaskRemoved != null) {
            OpenVPNService.setStopOnTaskRemoved(stopOnTaskRemoved);
        }
    }

    private void connect(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        VpnProfile profile;
        try {
            profile = buildProfile(call);
        } catch (InvalidProfileException e) {
            result.error(e.code, e.getMessage(), null);
            return;
        }

        Number expireAtArgument = call.argument("expire_at");
        long expireAt = expireAtArgument != null ? expireAtArgument.longValue() : 0;
        if (expireAt > 0 && expireAt <= System.currentTimeMillis()) {
            result.error("invalid_argument", "expireAt is in the past", null);
            return;
        }

        VpnController.ResultCallback callback = new VpnController.ResultCallback() {
            @Override
            public void success(boolean started) {
                result.success(started);
            }

            @Override
            public void error(@NonNull String code, @Nullable String message) {
                result.error(code, message, null);
            }
        };

        Intent permission = VpnService.prepare(context);
        if (permission == null) {
            try {
                controller.start(profile, expireAt);
                callback.success(true);
            } catch (RuntimeException e) {
                Log.e(TAG, "Could not start the VPN service", e);
                callback.error("start_failed", e.getMessage());
            }
            return;
        }

        Activity activity = getActivity();
        if (activity == null) {
            result.error("permission_required",
                    "The VPN permission has not been granted yet and there is no activity to ask for it. "
                            + "Call requestPermissionAndroid() (or connect) from the app's UI first.",
                    null);
            return;
        }
        controller.setPendingPermission(new VpnController.PendingPermission(profile, expireAt, callback));
        controller.markWaitingForPermission();
        try {
            activity.startActivityForResult(permission, VPN_PERMISSION_REQUEST_CODE);
        } catch (ActivityNotFoundException e) {
            // Some devices (Android TV builds, work profiles) cannot show the dialog.
            controller.onPermissionResult(false);
        }
    }

    private void requestPermission(@NonNull MethodChannel.Result result) {
        Intent permission = VpnService.prepare(context);
        if (permission == null) {
            result.success(true);
            return;
        }
        Activity activity = getActivity();
        if (activity == null) {
            result.success(false);
            return;
        }
        controller.setPendingPermission(new VpnController.PendingPermission(null, 0, new VpnController.ResultCallback() {
            @Override
            public void success(boolean granted) {
                result.success(granted);
            }

            @Override
            public void error(@NonNull String code, @Nullable String message) {
                result.error(code, message, null);
            }
        }));
        try {
            activity.startActivityForResult(permission, VPN_PERMISSION_REQUEST_CODE);
        } catch (ActivityNotFoundException e) {
            controller.onPermissionResult(false);
        }
    }

    /** Opens the system VPN settings, where "Always-on VPN" and "Block connections without VPN" live. */
    private boolean openVpnSettings() {
        Intent intent = new Intent(Settings.ACTION_VPN_SETTINGS);
        Activity activity = getActivity();
        try {
            if (activity != null) {
                activity.startActivity(intent);
            } else {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                context.startActivity(intent);
            }
            return true;
        } catch (ActivityNotFoundException e) {
            return false;
        }
    }

    // region Profile

    private static final class InvalidProfileException extends Exception {
        final String code;

        InvalidProfileException(String code, String message) {
            super(message);
            this.code = code;
        }
    }

    @NonNull
    private VpnProfile buildProfile(@NonNull MethodCall call) throws InvalidProfileException {
        String config = call.argument("config");
        if (config == null || config.trim().isEmpty()) {
            throw new InvalidProfileException("invalid_config", "The OpenVPN configuration is empty");
        }

        VpnProfile profile;
        try {
            ConfigParser parser = new ConfigParser();
            parser.parseConfig(new StringReader(config));
            profile = parser.convertProfile();
        } catch (IOException | ConfigParser.ConfigParseError e) {
            throw new InvalidProfileException("invalid_config", "Could not read the OpenVPN configuration: " + e.getMessage());
        }

        String name = call.argument("name");
        profile.mName = TextUtils.isEmpty(name) ? "VPN" : name;
        profile.mProfileCreator = context.getPackageName();

        String username = call.argument("username");
        String password = call.argument("password");
        String keyPassword = call.argument("private_key_password");
        if (username != null) {
            profile.mUsername = username;
        }
        if (password != null) {
            profile.mPassword = password;
        }
        if (keyPassword != null) {
            profile.mKeyPassword = keyPassword;
        }

        applyAuthentication(profile, call.argument("cert_is_required"), !TextUtils.isEmpty(username));
        applyPerAppRules(profile, call.argument("allowed_packages"), call.argument("bypass_packages"));
        addCipherFallback(profile);

        int problem = profile.checkProfile(context);
        if (problem != R.string.no_error_found) {
            String message = context.getString(problem);
            if (problem == R.string.no_keystore_cert_selected) {
                message = "The configuration has no client certificate (<cert>/<key>) and no auth-user-pass. "
                        + "Add them to the configuration, or pass a username and password.";
            }
            throw new InvalidProfileException("invalid_config", message);
        }
        return profile;
    }

    /**
     * Configurations without a client certificate convert to a keystore profile,
     * which then fails with "You must select a User certificate". When no
     * certificate is expected, authenticate with username and password instead.
     */
    private static void applyAuthentication(@NonNull VpnProfile profile, @Nullable Boolean certIsRequired,
                                            boolean hasUsername) {
        boolean noClientCertificate = profile.mAuthenticationType == VpnProfile.TYPE_KEYSTORE
                && profile.mAlias == null;
        if (!noClientCertificate) {
            return;
        }
        boolean certRequired = certIsRequired != null && certIsRequired;
        if (!certRequired && (hasUsername || certIsRequired != null)) {
            profile.mAuthenticationType = VpnProfile.TYPE_USERPASS;
        }
    }

    private static void applyPerAppRules(@NonNull VpnProfile profile, @Nullable List<String> allowed,
                                         @Nullable List<String> bypass) throws InvalidProfileException {
        boolean hasAllowed = allowed != null && !allowed.isEmpty();
        boolean hasBypass = bypass != null && !bypass.isEmpty();
        if (hasAllowed && hasBypass) {
            // VpnService.Builder cannot mix allowed and disallowed applications.
            throw new InvalidProfileException("invalid_argument",
                    "allowedPackages and bypassPackages cannot be used together");
        }
        if (hasAllowed) {
            profile.mAllowedAppsVpnAreDisallowed = false;
            profile.mAllowedAppsVpn = new HashSet<>(allowed);
        } else if (hasBypass) {
            profile.mAllowedAppsVpnAreDisallowed = true;
            profile.mAllowedAppsVpn = new HashSet<>(bypass);
        }
    }

    /**
     * OpenVPN 2.6+ ignores --cipher when negotiating the data channel cipher, so
     * servers that cannot negotiate (OpenVPN 2.3 and older, SoftEther/VPN Gate)
     * fail with "No usable data channel cipher". Restore what the configuration
     * asks for: accept its cipher and fall back to it, like OpenVPN 2.4 did.
     */
    static void addCipherFallback(@NonNull VpnProfile profile) {
        String cipher = profile.mCipher == null ? "" : profile.mCipher.trim();
        if (cipher.isEmpty() || cipher.equalsIgnoreCase("none")) {
            return;
        }
        String custom = profile.mCustomConfigOptions == null ? "" : profile.mCustomConfigOptions;
        StringBuilder extra = new StringBuilder();
        if (!hasOption(custom, "data-ciphers") && !hasOption(custom, "ncp-ciphers")) {
            extra.append("data-ciphers ").append(dataCiphersWith(cipher)).append('\n');
        }
        if (!hasOption(custom, "data-ciphers-fallback")) {
            extra.append("data-ciphers-fallback ").append(cipher).append('\n');
        }
        if (isLegacyCipher(cipher) && !hasOption(custom, "providers")) {
            // BF-CBC, DES, CAST... live in OpenSSL 3's legacy provider.
            extra.append("providers legacy default\n");
        }
        if (extra.length() == 0) {
            return;
        }
        if (!custom.isEmpty() && !custom.endsWith("\n")) {
            custom += "\n";
        }
        profile.mCustomConfigOptions = custom + extra;
        profile.mUseCustomConfig = true;
    }

    private static boolean hasOption(@NonNull String options, @NonNull String option) {
        return Pattern.compile("(?m)^\\s*" + Pattern.quote(option) + "(\\s|$)").matcher(options).find();
    }

    @NonNull
    private static String dataCiphersWith(@NonNull String cipher) {
        for (String known : DEFAULT_DATA_CIPHERS.split(":")) {
            if (known.equalsIgnoreCase(cipher)) {
                return DEFAULT_DATA_CIPHERS;
            }
        }
        return DEFAULT_DATA_CIPHERS + ":" + cipher;
    }

    private static boolean isLegacyCipher(@NonNull String cipher) {
        String upper = cipher.toUpperCase(Locale.ROOT);
        return upper.startsWith("BF-") || upper.startsWith("CAST") || upper.startsWith("DES")
                || upper.startsWith("RC2") || upper.startsWith("SEED") || upper.startsWith("IDEA");
    }

    // endregion
}
