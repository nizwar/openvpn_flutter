import 'dart:async';

import 'package:openvpn_flutter/openvpn_flutter.dart';

import 'package:vpn_plugin_interface/vpn_plugin_interface.dart';

class Vpn implements IVpn {
  late final OpenVPN _openVPN;

  late final StreamController<ConnectionStatusItem> _connectionStatusController;
  late final StreamController<String> _logsController;
  late ConnectionStatus _vpnStatus;

  Future<void> init() async {
    _openVPN = OpenVPN(onVpnStageChanged: _onVpnStageChanged);
    await _openVPN.initialize(
      groupIdentifier: 'group.com.aventus.atvpn',
      providerBundleIdentifier: 'app.atvpn.VPNExtension',
      localizedDescription: 'atVPN',
    );
  }

  /// Sends signal for an underlying plugin to establish VPN connection.
  ///
  /// Note that this future resolves after signal to connect has been sent and
  /// not after connection successfully resolved. If you want to know when
  /// user has been connected, please, use [getConnectionInfo] stream.
  ///
  ///
  /// VPN config must be passed to [params.сonfig]
  @override
  Future<void> connectVPN({
    required String server,
    required String username,
    required String password,
    Map<String, dynamic>? params,
  }) async {
    try {
      if (params == null || params['config'] == null) {
        throw Exception('[config] must be passed');
      }
      _openVPN.connect(
        params['config'].toString(),
        server,
        username: username,
        password: password,
        certIsRequired: true,
      );
      _logsController.add('Connected');
    } on Exception catch (err) {
      _logsController.add('Connecting error: $err');
    }
  }

  @override
  Future<void> disconnectVPN() async {
    try {
      _openVPN.disconnect();
      _logsController.add('Disconnected');
    } on Exception catch (err) {
      _logsController.add('Disconnecting error: $err');
    }
  }

  @override
  Stream<ConnectionStatusItem> getConnectionInfo() {
    _connectionStatusController = StreamController<ConnectionStatusItem>.broadcast(
      onListen: () async {
        _connectionStatusController.add(ConnectionStatusItem(_vpnStatus));
      },
    );
    return _connectionStatusController.stream;
  }

  @override
  Stream<String> getLogs() {
    _logsController = StreamController<String>.broadcast();
    return _logsController.stream;
  }

  void _onVpnStageChanged(VPNStage stage, _) {
    _vpnStatus = _mapVpnStageToConnectionStatus(stage);
    _logsController.add('Connection status: $_vpnStatus');
    _connectionStatusController.add(ConnectionStatusItem(_vpnStatus));
  }

  ConnectionStatus _mapVpnStageToConnectionStatus(VPNStage stage) {
    switch (stage) {
      case VPNStage.prepare:
      case VPNStage.vpn_generate_config:
      case VPNStage.resolve:
      case VPNStage.wait_connection:
      case VPNStage.authenticating:
      case VPNStage.get_config:
      case VPNStage.assign_ip:
      case VPNStage.connecting:
      case VPNStage.authentication:
        return ConnectionStatus.connecting;
      case VPNStage.connected:
        return ConnectionStatus.connected;
      case VPNStage.disconnected:
        return ConnectionStatus.disconnected;
      case VPNStage.disconnecting:
        return ConnectionStatus.disconnecting;
      case VPNStage.denied:
      case VPNStage.error:
      case VPNStage.tcp_connect:
      case VPNStage.udp_connect:
      case VPNStage.exiting:
      case VPNStage.unknown:
        return ConnectionStatus.disconnected;
    }
  }
}
