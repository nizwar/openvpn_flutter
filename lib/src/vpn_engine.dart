import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'model/vpn_status.dart';

enum VPNStage {
  prepare,
  authenticating,
  connecting,
  authentication,
  connected,
  disconnected,
  disconnecting,
  denied,
  error,
// ignore: constant_identifier_names
  wait_connection,
// ignore: constant_identifier_names
  vpn_generate_config,
// ignore: constant_identifier_names
  get_config,
// ignore: constant_identifier_names
  tcp_connect,
// ignore: constant_identifier_names
  assign_ip,
  unknown
}

class OpenVPN {
  static const String _eventChannelVpnStage =
      "id.laskarmedia.openvpn_flutter/vpnstage";
  static const String _methodChannelVpnControl =
      "id.laskarmedia.openvpn_flutter/vpncontrol";

  static const MethodChannel _channelControl =
      MethodChannel(_methodChannelVpnControl);

  static Stream<VPNStage> _vpnStageSnapshot() =>
      const EventChannel(_eventChannelVpnStage)
          .receiveBroadcastStream()
          .map<VPNStage>((event) => _strToStage(event));

  Timer? _vpnStatusTimer;

  bool _initialized = false;
  DateTime? _tempDateTime;

  final Function(VpnStatus? data)? onVpnStatusChanged;
  final Function(VPNStage data)? onVpnStageChanged;

  /// onVpnStatusChanged is a listener to see vpn status detail
  /// onVpnStageChanged is a listener to see what stage the connection was
  OpenVPN({this.onVpnStatusChanged, this.onVpnStageChanged});

  ///This function should be called before any usage of OpenVPN
  ///All params required for iOS, make sure you read the plugin's documentation
  ///
  ///
  ///providerBundleIdentfier is for your Network Extension identifier
  ///
  ///localizedDescription is for Description to show user in settings
  ///
  ///
  ///Will return latest VPNStage
  Future<VPNStage> initialize(
      {String? providerBundleIdentifier,
      String? localizedDescription,
      String? groupIdentifier}) async {
    if (Platform.isIOS) {
      assert(
          groupIdentifier != null &&
              providerBundleIdentifier != null &&
              localizedDescription != null,
          "These values are required for ios.");
    }
    onVpnStatusChanged?.call(VpnStatus.empty());
    _initialized = true;
    _initializeListener();
    return _channelControl.invokeMethod("initialize", {
      "groupIdentifier": groupIdentifier,
      "providerBundleIdentifier": providerBundleIdentifier,
      "localizedDescription": localizedDescription,
    }).then((value) {
      return stage();
    });
  }

  ///Connect to VPN
  ///
  ///bypassPackages to exclude some apps to access/use the VPN Connection, it was List<String> of applications package's name (Android Only)
  void connect(String config, String name,
      {String? username,
      String? password,
      List<String>? bypassPackages,
      bool certIsRequired = false}) async {
    if (!_initialized) throw ("OpenVPN need to be initialized");
    if (!certIsRequired) config += "client-cert-not-required";
    _tempDateTime = DateTime.now();
    _channelControl.invokeMethod("connect", {
      "config": config,
      "name": name,
      "username": username,
      "password": password,
      "bypass_packages": bypassPackages ?? []
    });
  }

  ///Disconnect from VPN
  void disconnect() {
    _tempDateTime = null;
    _channelControl.invokeMethod("disconnect");
    if (_vpnStatusTimer?.isActive ?? false) {
      _vpnStatusTimer?.cancel();
      _vpnStatusTimer = null;
    }
  }

  ///Check if connected to vpn
  Future<bool> isConnected() async =>
      stage().then((value) => value == VPNStage.connected);

  ///Get latest connection stage
  static Future<VPNStage> stage() async {
    String? stage = await _channelControl.invokeMethod("stage");
    return _strToStage(stage ?? "disconnected");
  }

  ///Sometimes config script has too many Remotes, it cause ANR in several devices,
  ///This happened because the plugin check every remote and somehow affected the UI to freeze
  ///
  ///Use this function if you wanted to force user to use 1 remote by randomize the remotes provided
  static Future<String?> filteredConfig(String? config) async {
    List<String> remotes = [];
    List<String> output = [];
    if (config == null) return null;
    var raw = config.split("\n");

    for (var item in raw) {
      if (item.trim().toLowerCase().startsWith("remote ")) {
        if (!output.contains("REMOTE_HERE")) {
          output.add("REMOTE_HERE");
        }
        remotes.add(item);
      } else {
        output.add(item);
      }
    }
    String fastestServer = remotes[Random().nextInt(remotes.length - 1)];
    int indexRemote = output.indexWhere((element) => element == "REMOTE_HERE");
    output.removeWhere((element) => element == "REMOTE_HERE");
    output.insert(indexRemote, fastestServer);
    return output.join("\n");
  }

  String _duration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }

  static VPNStage _strToStage(String stage) {
    if (stage.trim().isEmpty || stage.trim() == "idle") {
      return VPNStage.disconnected;
    }
    var indexStage = VPNStage.values.indexWhere((element) =>
        element.name.trim().toLowerCase() ==
        stage.toString().trim().toLowerCase());
    if (indexStage >= 0) return VPNStage.values[indexStage];
    return VPNStage.unknown;
  }

  void _initializeListener() {
    _vpnStageSnapshot().listen((event) {
      onVpnStageChanged?.call(event);
      if (event != VPNStage.disconnected) {
        if (_vpnStatusTimer != null) return;
        _vpnStatusTimer ??= Timer.periodic(const Duration(seconds: 1), (timer) {
          _channelControl.invokeMethod("status").then((data) {
            if (data == null) {
              return onVpnStatusChanged?.call(VpnStatus.empty());
            }

            if (Platform.isIOS) {
              var splitted = data.split("_");
              var connectedOn = DateTime.tryParse(splitted[0]);
              if (connectedOn == null) {
                return onVpnStatusChanged?.call(VpnStatus.empty());
              }

              onVpnStatusChanged?.call(VpnStatus(
                duration:
                    _duration(DateTime.now().difference(connectedOn).abs()),
                byteIn: splitted[2],
                byteOut: splitted[3],
                lastPacketReceive: splitted[1],
              ));
            } else {
              var value = jsonDecode(data);
              var connectedOn =
                  DateTime.tryParse(value["connected_on"].toString()) ??
                      _tempDateTime;
              if (connectedOn == null) {
                return onVpnStatusChanged?.call(VpnStatus.empty());
              }

              String byteIn =
                  value["byte_in"] != null ? value["byte_in"].toString() : "0";
              String byteOut = value["byte_out"] != null
                  ? value["byte_out"].toString()
                  : "0";

              if (byteIn.trim().isEmpty) byteIn = "0";
              if (byteOut.trim().isEmpty) byteOut = "0";

              onVpnStatusChanged?.call(VpnStatus(
                duration:
                    _duration(DateTime.now().difference(connectedOn).abs()),
                byteIn: byteIn,
                byteOut: byteOut,
                lastPacketReceive: value["last_packet_receive"],
              ));
            }
          });
        });
      }
    });
  }
}
