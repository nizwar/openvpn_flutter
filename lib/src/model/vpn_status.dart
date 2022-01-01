///To store datas of VPN Connection's status detail
class VpnStatus {
  VpnStatus({
    this.duration,
    this.lastPacketReceive,
    this.byteIn,
    this.byteOut,
  });

  ///Duration of vpn usage
  final String? duration;

  ///Last packet received by connection
  final String? lastPacketReceive;

  ///Download byte usages
  final String? byteIn;

  ///Upload byte usages
  final String? byteOut;

  /// VPNStatus as empty data
  factory VpnStatus.empty() => VpnStatus(
        duration: "00:00:00",
        lastPacketReceive: "0",
        byteIn: "0",
        byteOut: "0",
      );

  ///Convert to JSON
  Map<String, dynamic> toJson() => {
        "duration": duration,
        "last_packet_receive": lastPacketReceive,
        "byte_in": byteIn,
        "byte_out": byteOut,
      };

  @override
  String toString() => toJson().toString();
}
