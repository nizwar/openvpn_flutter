///To store datas of VPN Connection's status detail
class VpnStatus {
  VpnStatus({
    this.duration,
    this.connectedOn,
    this.byteIn,
    this.byteOut,
    this.packetsIn,
    this.packetsOut,
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
      };

  @override
  String toString() => toJson().toString();
}
