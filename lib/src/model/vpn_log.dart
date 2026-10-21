/// Severity of a [VpnLog] line.
enum VpnLogLevel {
  /// Detailed diagnostics.
  debug,

  /// More detail than [info].
  verbose,

  /// Regular progress messages.
  info,

  /// Something unexpected that the engine could recover from.
  warning,

  /// A failure; often the reason a connection does not come up.
  error;

  static VpnLogLevel _fromName(Object? name) {
    for (final level in values) {
      if (level.name == name) return level;
    }
    return info;
  }
}

/// A line of the VPN engine's log.
class VpnLog {
  /// Creates a log line.
  const VpnLog({
    required this.time,
    required this.level,
    required this.message,
  });

  /// Parses a log line sent by the native side.
  factory VpnLog.fromMap(Map<Object?, Object?> map) {
    final time = map['time'];
    return VpnLog(
      time: time is int
          ? DateTime.fromMillisecondsSinceEpoch(time)
          : DateTime.tryParse('$time') ?? DateTime.now(),
      level: VpnLogLevel._fromName(map['level']),
      message: '${map['message'] ?? ''}',
    );
  }

  /// When the line was logged.
  final DateTime time;

  /// The severity.
  final VpnLogLevel level;

  /// The message.
  final String message;

  @override
  String toString() => '${time.toIso8601String()} [${level.name}] $message';
}
