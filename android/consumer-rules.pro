# openvpn_flutter: keep the OpenVPN engine intact in minified release builds.
# Profiles are restored with Java serialization when the system restarts the
# VPN service, and the native helpers are bound through JNI.
-keep class de.blinkt.openvpn.** { *; }
-dontwarn de.blinkt.openvpn.**
-keep class id.laskarmedia.openvpn_flutter.** { *; }
