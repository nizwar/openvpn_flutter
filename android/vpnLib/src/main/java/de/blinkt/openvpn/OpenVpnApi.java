package de.blinkt.openvpn;

import android.annotation.TargetApi;
import android.content.Context;
import android.os.Build;
import android.os.RemoteException;
import android.text.TextUtils;
import android.util.Log;

import java.io.IOException;
import java.io.StringReader;
import java.util.HashSet;
import java.util.List;

import de.blinkt.openvpn.core.ConfigParser;
import de.blinkt.openvpn.core.ProfileManager;
import de.blinkt.openvpn.core.VPNLaunchHelper;

public class OpenVpnApi {

    private static final String TAG = "OpenVpnApi";

    @TargetApi(Build.VERSION_CODES.ICE_CREAM_SANDWICH_MR1)
    public static void startVpn(Context context, String config, String name, String username, String password, List<String> bypassPackages) throws RemoteException {
        if (TextUtils.isEmpty(config)) throw new RemoteException("config is empty");
        startVpnInternal(context, config, name, username, password, bypassPackages);
    }

    static void startVpnInternal(Context context, String config, String name, String username, String password, List<String> bypassPackages) throws RemoteException {
        ConfigParser cp = new ConfigParser();
        try {
            cp.parseConfig(new StringReader(config));
            VpnProfile vp = cp.convertProfile();// Analysis.ovpn
            vp.mName = name;
            if (vp.checkProfile(context) != de.blinkt.openvpn.R.string.no_error_found) {
                throw new RemoteException(context.getString(vp.checkProfile(context)));
            }
            vp.mProfileCreator = context.getPackageName();
            vp.mUsername = username;
            vp.mPassword = password;
            if(bypassPackages.size() > 0){
                vp.mAllowAppVpnBypass = true;
                vp.mAllowedAppsVpn = new HashSet<>(bypassPackages);
            }

            ProfileManager.setTemporaryProfile(context, vp);
            VPNLaunchHelper.startOpenVpn(vp, context);
        } catch (IOException | ConfigParser.ConfigParseError e) {
            throw new RemoteException(e.getMessage());
        }
    }
}
