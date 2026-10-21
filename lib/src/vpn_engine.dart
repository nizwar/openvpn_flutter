import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'model/vpn_log.dart';
import 'model/vpn_stage.dart';
import 'model/vpn_status.dart';

export 'model/vpn_stage.dart';

/// Connects to OpenVPN servers.
///
/// Create one instance, call [initialize] once, then [connect] and
/// [disconnect]. Progress is reported through [onVpnStageChanged] and
/// [stageStream], traffic through [onVpnStatusChanged] and [statusStream],
/// and the engine's log through [logStream].
class OpenVPN {
  static const MethodChannel _channelControl =
      MethodChannel("id.laskarmedia.openvpn_flutter/vpncontrol");
  static const EventChannel _stageChannel =
      EventChannel("id.laskarmedia.openvpn_flutter/vpnstage");
  static const EventChannel _logChannel =
      EventChannel("id.laskarmedia.openvpn_flutter/vpnlog");

  /// How often [onVpnStatusChanged] and [statusStream] are updated while
  /// connected.
  static const Duration statusInterval = Duration(seconds: 1);

  /// How long [disconnect] waits for the tunnel to go down.
  static const Duration disconnectTimeout = Duration(seconds: 10);

  /// Called with the connection details every [statusInterval] while
  /// connected, and with [VpnStatus.empty] once the tunnel is down.
  final Function(VpnStatus? data)? onVpnStatusChanged;

  /// Called whenever the stage changes, with the raw stage name reported by
  /// the native side.
  final Function(VPNStage stage, String rawStage)? onVpnStageChanged;

  /// Creates the engine. The listeners are optional: [stageStream] and
  /// [statusStream] report the same information.
  OpenVPN({this.onVpnStatusChanged, this.onVpnStageChanged});

  bool _initialized = false;

  /// Whether [initialize] completed.
  bool get initialized => _initialized;

  VPNStage _stage = VPNStage.disconnected;
  VPNStage? _reportedStage;
  VpnStatus _status = VpnStatus.empty();
  StreamSubscription<dynamic>? _stageSubscription;
  Timer? _statusTimer;
  _TrafficSample? _lastSample;

  final StreamController<VPNStage> _stageController =
      StreamController<VPNStage>.broadcast();
  final StreamController<VpnStatus> _statusController =
      StreamController<VpnStatus>.broadcast();

  /// The last stage reported by the native side.
  VPNStage get currentStage => _stage;

  /// The last status reported while connected, or [VpnStatus.empty].
  VpnStatus get currentStatus => _status;

  /// Stage changes, starting after [initialize].
  Stream<VPNStage> get stageStream => _stageController.stream;

  /// Connection details, every [statusInterval] while connected.
  Stream<VpnStatus> get statusStream => _statusController.stream;

  /// The engine's log, as it is written.
  ///
  /// On iOS and macOS the log comes from the packet tunnel provider; see the
  /// README for the provider code that forwards it.
  Stream<VpnLog> get logStream => _logChannel
      .receiveBroadcastStream()
      .where((event) => event is Map)
      .map((event) => VpnLog.fromMap(event as Map<Object?, Object?>));

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get _isApple =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Prepares the engine; call it once before anything else.
  ///
  /// iOS and macOS need [providerBundleIdentifier] (the bundle identifier of
  /// your Network Extension target), [groupIdentifier] (the App Group shared
  /// by the app and the extension, Team ID prefixed on macOS) and
  /// [localizedDescription] (the name shown in the system VPN settings).
  ///
  /// Android options:
  /// * [showTrafficInNotification]: refresh the connection notification with
  ///   the traffic counters (default). Turn it off for a static notification.
  /// * [disconnectOnTaskRemoved]: stop the VPN when the user removes the app
  ///   from the recent apps screen. Off by default.
  ///
  /// [lastStage] and [lastStatus] receive the state of a VPN that was already
  /// running, for example when the app is reopened while connected.
  Future<void> initialize({
    String? providerBundleIdentifier,
    String? localizedDescription,
    String? groupIdentifier,
    Function(VpnStatus status)? lastStatus,
    Function(VPNStage stage)? lastStage,
    bool? showTrafficInNotification,
    bool? disconnectOnTaskRemoved,
  }) async {
    if (_isApple) {
      assert(
          groupIdentifier != null &&
              providerBundleIdentifier != null &&
              localizedDescription != null,
          "groupIdentifier, providerBundleIdentifier and localizedDescription "
          "are required on iOS and macOS.");
    }
    onVpnStatusChanged?.call(VpnStatus.empty());
    _listenToStages();

    final raw = await _channelControl.invokeMethod<String>("initialize", {
      "groupIdentifier": groupIdentifier,
      "providerBundleIdentifier": providerBundleIdentifier,
      "localizedDescription": localizedDescription,
      if (showTrafficInNotification != null)
        "show_traffic_in_notification": showTrafficInNotification,
      if (disconnectOnTaskRemoved != null)
        "disconnect_on_task_removed": disconnectOnTaskRemoved,
    });
    _initialized = true;
    _onStage(raw);

    final status = await this.status();
    lastStatus?.call(status);
    lastStage?.call(_stage);
  }

  /// Connects to the server described by [config], the content of an
  /// `.ovpn` file.
  ///
  /// * [name]: shown in the Android notification.
  /// * [username], [password]: for configurations with `auth-user-pass`.
  /// * [privateKeyPassword]: decrypts an encrypted `<key>`.
  /// * [certIsRequired]: whether the configuration authenticates with a client
  ///   certificate. Detected from the configuration when null.
  /// * [bypassPackages] (Android): apps whose traffic does not use the VPN.
  /// * [allowedPackages] (Android): the only apps whose traffic uses the VPN.
  ///   Cannot be combined with [bypassPackages].
  /// * [expireAt]: disconnects at that time, even with the app closed (on
  ///   iOS/macOS this needs the packet tunnel provider from the README).
  ///
  /// Returns `true` once the connection is starting; follow [stageStream] or
  /// [onVpnStageChanged] for its progress. Returns `false` when the user
  /// refuses the VPN permission (the stage becomes [VPNStage.denied]).
  /// Throws a [PlatformException] when the configuration is invalid or the VPN
  /// cannot be started.
  Future<bool> connect(
    String config,
    String name, {
    String? username,
    String? password,
    List<String>? bypassPackages,
    List<String>? allowedPackages,
    bool? certIsRequired,
    String? privateKeyPassword,
    DateTime? expireAt,
  }) async {
    if (!_initialized) {
      throw StateError("OpenVPN needs to be initialized before connecting");
    }
    if ((allowedPackages?.isNotEmpty ?? false) &&
        (bypassPackages?.isNotEmpty ?? false)) {
      throw ArgumentError(
          "allowedPackages and bypassPackages cannot be used together");
    }

    var effectiveConfig = config;
    if (_isApple && !(certIsRequired ?? hasClientCertificate(config))) {
      // OpenVPN 3 (iOS/macOS) expects a client certificate unless told otherwise.
      effectiveConfig = withClientCertNotRequired(config);
    }

    final started = await _channelControl.invokeMethod<Object?>("connect", {
      "config": effectiveConfig,
      "name": name,
      "username": username,
      "password": password,
      "bypass_packages": bypassPackages ?? const <String>[],
      "allowed_packages": allowedPackages ?? const <String>[],
      "cert_is_required": certIsRequired,
      "private_key_password": privateKeyPassword,
      "expire_at": expireAt?.millisecondsSinceEpoch,
    });
    // 1.x iOS providers answer null on success.
    return started is bool ? started : true;
  }

  /// Disconnects, and completes once the tunnel is down (or after
  /// [disconnectTimeout]). Never throws; does nothing when not connected.
  Future<void> disconnect() async {
    try {
      await _channelControl.invokeMethod("disconnect");
    } on PlatformException catch (e) {
      debugPrint("openvpn_flutter: disconnect failed: ${e.message}");
    } on MissingPluginException {
      return;
    }
    if (_stageSubscription == null || _stage.isDisconnected) return;
    try {
      await stageStream
          .firstWhere((stage) => stage.isDisconnected)
          .timeout(disconnectTimeout);
    } on TimeoutException {
      // The engine keeps stopping in the background.
    } on StateError {
      // dispose() closed the stream.
    }
  }

  /// Whether the tunnel is up.
  Future<bool> isConnected() async =>
      stage().then((value) => value == VPNStage.connected);

  /// The current stage, asked from the native side.
  Future<VPNStage> stage() async {
    final stage = await _channelControl.invokeMethod<String>("stage");
    return VPNStage.fromRaw(stage);
  }

  /// The current connection details, asked from the native side.
  /// [VpnStatus.empty] when not connected.
  Future<VpnStatus> status() async {
    if (await stage() != VPNStage.connected) return VpnStatus.empty();
    return _fetchStatus();
  }

  Future<VpnStatus> _fetchStatus() async {
    final value = await _channelControl.invokeMethod<Object?>("status");
    return VpnStatus.fromNative(value);
  }

  /// Asks for the Android VPN permission, showing the system dialog if needed.
  ///
  /// Completes with whether the permission is granted. [connect] asks for it
  /// too, so calling this first is optional. Always `true` on other
  /// platforms, which ask when the VPN configuration is first saved.
  Future<bool> requestPermissionAndroid() async {
    if (!_isAndroid) return true;
    final granted =
        await _channelControl.invokeMethod<bool>("request_permission");
    return granted ?? false;
  }

  /// The engine's log so far (Android keeps the last 1000 lines; iOS and
  /// macOS what the packet tunnel provider wrote).
  Future<List<VpnLog>> getLogs() async {
    final logs = await _channelControl.invokeMethod<List<Object?>>("logs");
    return [
      for (final log in logs ?? const <Object?>[])
        if (log is Map) VpnLog.fromMap(log),
    ];
  }

  /// Why the last connection failed or stopped, when the engine knows it.
  ///
  /// On iOS 16+ and macOS 13+ this is the system's last disconnect error.
  Future<String?> lastError() =>
      _channelControl.invokeMethod<String>("last_error");

  /// Opens the system VPN settings (Android), where users can turn on
  /// "Always-on VPN" and "Block connections without VPN" (a kill switch).
  ///
  /// Returns whether the settings could be opened; always `false` on other
  /// platforms.
  Future<bool> openVpnSettings() async {
    if (!_isAndroid) return false;
    return await _channelControl.invokeMethod<bool>("open_vpn_settings") ??
        false;
  }

  /// Stops listening to the native side. The VPN itself keeps its state;
  /// create a new [OpenVPN] to use it again.
  void dispose() {
    _statusTimer?.cancel();
    _statusTimer = null;
    _stageSubscription?.cancel();
    _stageSubscription = null;
    _stageController.close();
    _statusController.close();
    _initialized = false;
  }

  /// Picks one random `remote` of [config] and drops the others.
  ///
  /// Configurations listing many remotes make some devices check each of
  /// them, which can freeze the app; use this to connect to a single one.
  static Future<String?> filteredConfig(String? config) async {
    if (config == null) return null;
    final lines = config.split("\n");
    final remotes = <String>[];
    final output = <String>[];
    var remoteIndex = -1;
    for (final line in lines) {
      if (line.trim().toLowerCase().startsWith("remote ")) {
        if (remoteIndex < 0) remoteIndex = output.length;
        remotes.add(line);
      } else {
        output.add(line);
      }
    }
    if (remotes.length < 2) return config;
    output.insert(remoteIndex, remotes[Random().nextInt(remotes.length)]);
    return output.join("\n");
  }

  /// Whether [config] authenticates with a client certificate.
  @visibleForTesting
  static bool hasClientCertificate(String config) => RegExp(
        r'^\s*(<cert>|cert\s|pkcs12\s|<pkcs12>)',
        multiLine: true,
        caseSensitive: false,
      ).hasMatch(config);

  /// Adds `client-cert-not-required` on a line of its own, once.
  @visibleForTesting
  static String withClientCertNotRequired(String config) {
    if (RegExp(r'^\s*client-cert-not-required\s*$', multiLine: true)
        .hasMatch(config)) {
      return config;
    }
    final separator = config.isEmpty || config.endsWith("\n") ? "" : "\n";
    return "$config${separator}client-cert-not-required\n";
  }

  void _listenToStages() {
    _stageSubscription ??= _stageChannel
        .receiveBroadcastStream()
        .listen((event) => _onStage(event is String ? event : null),
            onError: (Object error) {
      debugPrint("openvpn_flutter: stage stream error: $error");
    });
  }

  void _onStage(String? raw) {
    final stage = VPNStage.fromRaw(raw);
    _stage = stage;
    // The first stage is always reported, then only changes.
    if (stage != _reportedStage) {
      _reportedStage = stage;
      onVpnStageChanged?.call(stage, raw ?? stage.name);
      if (!_stageController.isClosed) _stageController.add(stage);
    }
    if (stage == VPNStage.connected) {
      _startStatusTimer();
    } else {
      _stopStatusTimer();
    }
  }

  void _startStatusTimer() {
    if (_statusTimer != null) return;
    _statusTimer = Timer.periodic(statusInterval, (_) => _refreshStatus());
    _refreshStatus();
  }

  void _stopStatusTimer() {
    final wasRunning = _statusTimer != null;
    _statusTimer?.cancel();
    _statusTimer = null;
    _lastSample = null;
    if (wasRunning || _status.connectedOn != null) {
      _emitStatus(VpnStatus.empty());
    }
  }

  Future<void> _refreshStatus() async {
    try {
      final status = _withSpeed(await _fetchStatus());
      if (_statusTimer == null) return;
      _emitStatus(status);
    } on PlatformException catch (e) {
      debugPrint("openvpn_flutter: status failed: ${e.message}");
    } on MissingPluginException {
      _stopStatusTimer();
    }
  }

  void _emitStatus(VpnStatus status) {
    _status = status;
    onVpnStatusChanged?.call(status);
    if (!_statusController.isClosed) _statusController.add(status);
  }

  /// Fills in the speed when the platform does not report it.
  VpnStatus _withSpeed(VpnStatus status) {
    final bytesIn = int.tryParse(status.byteIn ?? "") ?? 0;
    final bytesOut = int.tryParse(status.byteOut ?? "") ?? 0;
    final now = DateTime.now();
    final previous = _lastSample;
    _lastSample = _TrafficSample(bytesIn, bytesOut, now);
    if (status.speedIn != null && status.speedOut != null) return status;
    if (previous == null) return status.withSpeed(speedIn: 0, speedOut: 0);
    final seconds = now.difference(previous.time).inMilliseconds / 1000;
    if (seconds <= 0) return status.withSpeed(speedIn: 0, speedOut: 0);
    int rate(int current, int last) =>
        current >= last ? ((current - last) / seconds).round() : 0;
    return status.withSpeed(
      speedIn: rate(bytesIn, previous.bytesIn),
      speedOut: rate(bytesOut, previous.bytesOut),
    );
  }
}

class _TrafficSample {
  _TrafficSample(this.bytesIn, this.bytesOut, this.time);

  final int bytesIn;
  final int bytesOut;
  final DateTime time;
}
