// End-to-end test against a real OpenVPN server.
//
// flutter test integration_test/connection_test.dart \
//   --dart-define=OVPN_CONFIG=$(base64 < client.ovpn) \
//   [--dart-define=OVPN_USERNAME=... --dart-define=OVPN_PASSWORD=...]
//
// On Android the VPN permission must be granted beforehand (once per install):
//   adb shell appops set id.laskarmedia.openvpn_flutter_example ACTIVATE_VPN allow
// Network extensions do not run on the iOS simulator; use a device.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';

const String _configBase64 = String.fromEnvironment('OVPN_CONFIG');
const String _username = String.fromEnvironment('OVPN_USERNAME');
const String _password = String.fromEnvironment('OVPN_PASSWORD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late OpenVPN vpn;
  final stages = <VPNStage>[];
  final logs = <VpnLog>[];
  StreamSubscription<VPNStage>? stageSubscription;
  StreamSubscription<VpnLog>? logSubscription;

  setUp(() async {
    stages.clear();
    logs.clear();
    vpn = OpenVPN();
    await vpn.initialize(
      groupIdentifier: 'group.com.laskarmedia.vpn',
      providerBundleIdentifier:
          'id.laskarmedia.openvpnFlutterExample.VPNExtension',
      localizedDescription: 'OpenVPN Flutter Example',
    );
    stageSubscription = vpn.stageStream.listen(stages.add);
    logSubscription = vpn.logStream.listen(logs.add);
  });

  tearDown(() async {
    await vpn.disconnect();
    await stageSubscription?.cancel();
    await logSubscription?.cancel();
    vpn.dispose();
  });

  Future<VPNStage> settle(Duration timeout) => vpn.stageStream
      .firstWhere((stage) => stage.isConnected || stage.isDisconnected)
      .timeout(timeout, onTimeout: () => vpn.currentStage);

  Future<String> diagnostics() async => 'stages: $stages\n'
      'last error: ${await vpn.lastError()}\n'
      'log:\n${logs.join('\n')}';

  testWidgets('starts disconnected', (tester) async {
    expect(await vpn.stage(), VPNStage.disconnected);
    expect(await vpn.isConnected(), isFalse);
    final status = await vpn.status();
    expect(status.connectedOn, isNull);
    expect(status.duration, '00:00:00');
    // Nothing to stop: must complete without throwing.
    await vpn.disconnect();
  });

  testWidgets('rejects an invalid configuration', (tester) async {
    await expectLater(
      vpn.connect('this is not an openvpn configuration', 'invalid'),
      throwsA(isA<PlatformException>()),
    );
    expect(await vpn.stage(), VPNStage.disconnected);
  });

  testWidgets('connects, reports traffic and disconnects', (tester) async {
    if (_configBase64.isEmpty) {
      markTestSkipped('Pass --dart-define=OVPN_CONFIG=<base64 .ovpn>');
      return;
    }
    final config = utf8.decode(base64.decode(_configBase64));

    final started = await vpn.connect(
      config,
      'integration test',
      username: _username.isEmpty ? null : _username,
      password: _password.isEmpty ? null : _password,
    );
    expect(started, isTrue, reason: 'VPN permission not granted');

    final stage = await settle(const Duration(seconds: 90));
    expect(stage, VPNStage.connected, reason: await diagnostics());
    expect(stages.any((stage) => stage.isConnecting), isTrue);

    // Generate some traffic through the tunnel and let the counters update.
    await Future<void>.delayed(const Duration(seconds: 6));
    final status = await vpn.status();
    expect(status.connectedOn, isNotNull);
    expect(status.duration, isNot('00:00:00'));
    expect(int.parse(status.byteIn!), greaterThan(0));
    expect(vpn.currentStatus.connectedOn, isNotNull);

    await vpn.disconnect();
    expect(vpn.currentStage.isDisconnected, isTrue);
    expect(await vpn.stage(), VPNStage.disconnected);
    expect(stages, contains(VPNStage.disconnecting));
    expect((await vpn.status()).connectedOn, isNull);
    expect(await vpn.getLogs(), isNotEmpty);
  });

  testWidgets('switches servers without disconnecting first', (tester) async {
    if (_configBase64.isEmpty) {
      markTestSkipped('Pass --dart-define=OVPN_CONFIG=<base64 .ovpn>');
      return;
    }
    final config = utf8.decode(base64.decode(_configBase64));

    await vpn.connect(config, 'first');
    expect(await settle(const Duration(seconds: 90)), VPNStage.connected,
        reason: await diagnostics());

    stages.clear();
    await vpn.connect(config, 'second');
    final stage = await vpn.stageStream
        .firstWhere((stage) => stage.isConnected || stage == VPNStage.error)
        .timeout(const Duration(seconds: 90));
    expect(stage, VPNStage.connected, reason: await diagnostics());
  });

  testWidgets('disconnects when the session expires', (tester) async {
    if (_configBase64.isEmpty) {
      markTestSkipped('Pass --dart-define=OVPN_CONFIG=<base64 .ovpn>');
      return;
    }
    final config = utf8.decode(base64.decode(_configBase64));

    await vpn.connect(
      config,
      'expiring',
      expireAt: DateTime.now().add(const Duration(seconds: 45)),
    );
    expect(await settle(const Duration(seconds: 40)), VPNStage.connected,
        reason: await diagnostics());
    final end = await vpn.stageStream
        .firstWhere((stage) => stage.isDisconnected)
        .timeout(const Duration(seconds: 60));
    expect(end, VPNStage.disconnected);
  });
}
