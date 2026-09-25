///To store datas of VPN Connection's status detail
class VpnStatus {
  VpnStatus({
    this.duration,
    this.connectedOn,
    this.byteIn,
    this.byteOut,
    this.packetsIn,
    this.packetsOut,
    this.windowsDriver,
    this.windowsConnectMode,
  });

  ///Latest connection date
  ///Return null if vpn disconnected
  final DateTime? connectedOn;

  ///Duration of vpn usage
  final String? duration;

  ///Download byte usages
  final String? byteIn;

  ///Upload byte usages
  final String? byteOut;

  ///Packets in byte usages
  final String? packetsIn;

  ///Packets out byte usages
  final String? packetsOut;

  /// Active Windows driver: "ovpn-dco" or "tap-windows6" (Windows only).
  final String? windowsDriver;

  /// How openvpn.exe was launched: "service" or "direct" (Windows only).
  final String? windowsConnectMode;

  /// Human-readable Windows driver label for UI.
  String? get windowsDriverLabel {
    switch (windowsDriver) {
      case 'ovpn-dco':
        return 'Win-DCO';
      case 'tap-windows6':
        if (windowsConnectMode == 'direct') {
          return 'TAP (mode direct)';
        }
        return 'TAP (repli)';
      default:
        return null;
    }
  }

  /// VPNStatus as empty data
  factory VpnStatus.empty() => VpnStatus(
        duration: "00:00:00",
        connectedOn: null,
        byteIn: "0",
        byteOut: "0",
        packetsIn: "0",
        packetsOut: "0",
      );

  ///Convert to JSON
  Map<String, dynamic> toJson() => {
        "connected_on": connectedOn,
        "duration": duration,
        "byte_in": byteIn,
        "byte_out": byteOut,
        "packets_in": packetsIn,
        "packets_out": packetsOut,
        "windows_driver": windowsDriver,
        "windows_connect_mode": windowsConnectMode,
      };

  @override
  String toString() => toJson().toString();
}
