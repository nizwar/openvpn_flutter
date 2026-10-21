import 'dart:convert';

/// Details of the current VPN connection: since when it is up and how much
/// traffic went through it.
class VpnStatus {
  /// Creates a status. Use [VpnStatus.empty] for "not connected".
  VpnStatus({
    this.duration,
    this.connectedOn,
    this.byteIn,
    this.byteOut,
    this.packetsIn,
    this.packetsOut,
    this.speedIn,
    this.speedOut,
  });

  /// When the tunnel came up. Null while not connected.
  final DateTime? connectedOn;

  /// How long the tunnel has been up, as `HH:mm:ss`.
  final String? duration;

  /// Bytes received through the tunnel, as a decimal string.
  final String? byteIn;

  /// Bytes sent through the tunnel, as a decimal string.
  final String? byteOut;

  /// Packets received through the tunnel (iOS and macOS only).
  final String? packetsIn;

  /// Packets sent through the tunnel (iOS and macOS only).
  final String? packetsOut;

  /// Current download speed in bytes per second.
  final int? speedIn;

  /// Current upload speed in bytes per second.
  final int? speedOut;

  /// The status of a VPN that is not connected.
  factory VpnStatus.empty() => VpnStatus(
        duration: "00:00:00",
        connectedOn: null,
        byteIn: "0",
        byteOut: "0",
        packetsIn: "0",
        packetsOut: "0",
        speedIn: 0,
        speedOut: 0,
      );

  /// Parses the status reported by the native side.
  ///
  /// Accepts the map the bundled engines send, the JSON string sent by
  /// openvpn_flutter 1.x on Android, and the `connectedOn_packetsIn_packetsOut_bytesIn_bytesOut`
  /// string written by 1.x iOS packet tunnel providers.
  factory VpnStatus.fromNative(Object? value, {DateTime? now}) {
    final Map<Object?, Object?>? map;
    if (value is Map) {
      map = value;
    } else if (value is String && value.trim().startsWith('{')) {
      final decoded = _tryJsonDecode(value);
      map = decoded is Map ? decoded : null;
    } else if (value is String && value.contains('_')) {
      return _fromLegacyString(value, now: now);
    } else {
      map = null;
    }
    if (map == null) return VpnStatus.empty();

    final connectedOn = _parseDate(map['connected_on']);
    return VpnStatus(
      connectedOn: connectedOn,
      duration: formatDuration(connectedOn, now: now),
      byteIn: _parseCount(map['byte_in']),
      byteOut: _parseCount(map['byte_out']),
      packetsIn: _parseOptionalCount(map['packets_in']),
      packetsOut: _parseOptionalCount(map['packets_out']),
      speedIn: _parseInt(map['speed_in']),
      speedOut: _parseInt(map['speed_out']),
    );
  }

  static VpnStatus _fromLegacyString(String value, {DateTime? now}) {
    final parts = value.split('_');
    final connectedOn = DateTime.tryParse(parts[0].trim());
    String part(int index) =>
        index < parts.length ? _parseCount(parts[index]) : '0';
    return VpnStatus(
      connectedOn: connectedOn,
      duration: formatDuration(connectedOn, now: now),
      packetsIn: part(1),
      packetsOut: part(2),
      byteIn: part(3),
      byteOut: part(4),
    );
  }

  /// Formats the time since [connectedOn] as `HH:mm:ss`; `00:00:00` when null.
  static String formatDuration(DateTime? connectedOn, {DateTime? now}) {
    if (connectedOn == null) return "00:00:00";
    final duration = (now ?? DateTime.now()).difference(connectedOn).abs();
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    return "${twoDigits(duration.inHours)}:"
        "${twoDigits(duration.inMinutes.remainder(60))}:"
        "${twoDigits(duration.inSeconds.remainder(60))}";
  }

  /// A copy with the given speeds.
  VpnStatus withSpeed({int? speedIn, int? speedOut}) => VpnStatus(
        connectedOn: connectedOn,
        duration: duration,
        byteIn: byteIn,
        byteOut: byteOut,
        packetsIn: packetsIn,
        packetsOut: packetsOut,
        speedIn: speedIn,
        speedOut: speedOut,
      );

  /// Converts to a JSON-encodable map.
  Map<String, dynamic> toJson() => {
        "connected_on": connectedOn?.toIso8601String(),
        "duration": duration,
        "byte_in": byteIn,
        "byte_out": byteOut,
        "packets_in": packetsIn,
        "packets_out": packetsOut,
        "speed_in": speedIn,
        "speed_out": speedOut,
      };

  @override
  String toString() => toJson().toString();

  static Object? _tryJsonDecode(String value) {
    try {
      return jsonDecode(value);
    } on FormatException {
      return null;
    }
  }

  static DateTime? _parseDate(Object? value) {
    if (value is int) {
      return value > 0 ? DateTime.fromMillisecondsSinceEpoch(value) : null;
    }
    if (value is String && value.trim().isNotEmpty) {
      final millis = int.tryParse(value.trim());
      if (millis != null) return _parseDate(millis);
      return DateTime.tryParse(value.trim());
    }
    return null;
  }

  static int? _parseInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static String _parseCount(Object? value) =>
      (_parseInt(value) ?? 0).toString();

  static String? _parseOptionalCount(Object? value) =>
      _parseInt(value)?.toString();
}
