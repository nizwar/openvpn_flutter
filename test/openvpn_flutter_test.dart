import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';

const _control = MethodChannel('id.laskarmedia.openvpn_flutter/vpncontrol');
const _stageChannel = EventChannel('id.laskarmedia.openvpn_flutter/vpnstage');
const _logChannel = EventChannel('id.laskarmedia.openvpn_flutter/vpnlog');

/// Stands in for the native side.
class FakePlatform {
  String stage = 'disconnected';
  Object? status;
  final List<MethodCall> calls = [];
  MockStreamHandlerEventSink? stageSink;
  MockStreamHandlerEventSink? logSink;
  Object? connectResult = true;
  PlatformException? connectError;

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_control, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'initialize':
        case 'stage':
          return stage;
        case 'status':
          return status;
        case 'connect':
          if (connectError != null) throw connectError!;
          return connectResult;
        case 'disconnect':
          return null;
        case 'logs':
          return [
            {'time': 1000, 'level': 'error', 'message': 'TLS failed'},
            'ignored',
          ];
        case 'last_error':
          return 'TLS failed';
        case 'request_permission':
          return true;
        case 'open_vpn_settings':
          return true;
      }
      return null;
    });
    messenger.setMockStreamHandler(
      _stageChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) => stageSink = events,
        onCancel: (arguments) => stageSink = null,
      ),
    );
    messenger.setMockStreamHandler(
      _logChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) => logSink = events,
        onCancel: (arguments) => logSink = null,
      ),
    );
  }

  void emitStage(String value) {
    stage = value;
    stageSink?.success(value);
  }

  MethodCall last(String method) =>
      calls.lastWhere((call) => call.method == method);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VPNStage.fromRaw', () {
    test('maps every name to its stage', () {
      for (final stage in VPNStage.values) {
        expect(VPNStage.fromRaw(stage.name), stage);
      }
    });

    test('is case and whitespace insensitive', () {
      expect(VPNStage.fromRaw(' CONNECTED '), VPNStage.connected);
    });

    test('treats missing and idle names as disconnected', () {
      for (final raw in [null, '', 'idle', 'invalid', 'noprocess']) {
        expect(VPNStage.fromRaw(raw), VPNStage.disconnected, reason: '$raw');
      }
    });

    test('knows the names engines report', () {
      expect(VPNStage.fromRaw('reasserting'), VPNStage.reconnect);
      expect(VPNStage.fromRaw('connectretry'), VPNStage.reconnect);
      expect(VPNStage.fromRaw('no_connection'), VPNStage.no_network);
      expect(VPNStage.fromRaw('screenoff'), VPNStage.paused);
      expect(VPNStage.fromRaw('auth'), VPNStage.authenticating);
    });

    test('does not match partial names', () {
      // 1.x matched "connect" against "connecting" and "connected".
      expect(VPNStage.fromRaw('connect'), VPNStage.unknown);
      expect(VPNStage.fromRaw('something new'), VPNStage.unknown);
    });

    test('classifies stages', () {
      expect(VPNStage.connected.isConnected, isTrue);
      expect(VPNStage.tcp_connect.isConnecting, isTrue);
      expect(VPNStage.reconnect.isConnecting, isTrue);
      for (final stage in [
        VPNStage.disconnected,
        VPNStage.denied,
        VPNStage.error,
        VPNStage.auth_failed,
      ]) {
        expect(stage.isDisconnected, isTrue, reason: '$stage');
        expect(stage.isConnecting, isFalse, reason: '$stage');
      }
      expect(VPNStage.disconnecting.isConnecting, isFalse);
      expect(VPNStage.disconnecting.isDisconnected, isFalse);
    });
  });

  group('VpnStatus.fromNative', () {
    final now = DateTime(2026, 1, 1, 12, 0, 0);

    test('reads the map the engines send', () {
      final connectedOn = now.subtract(const Duration(hours: 1, seconds: 5));
      final status = VpnStatus.fromNative({
        'connected_on': connectedOn.millisecondsSinceEpoch,
        'byte_in': 2048,
        'byte_out': 1024,
        'speed_in': 300,
        'speed_out': 20,
      }, now: now);
      expect(status.connectedOn, connectedOn);
      expect(status.duration, '01:00:05');
      expect(status.byteIn, '2048');
      expect(status.byteOut, '1024');
      expect(status.packetsIn, isNull);
      expect(status.speedIn, 300);
      expect(status.speedOut, 20);
    });

    test('reads milliseconds sent as a double', () {
      final connectedOn = now.subtract(const Duration(minutes: 2));
      final status = VpnStatus.fromNative(
        {'connected_on': connectedOn.millisecondsSinceEpoch.toDouble()},
        now: now,
      );
      expect(status.duration, '00:02:00');
    });

    test('reads the JSON string of the 1.x Android plugin', () {
      final status = VpnStatus.fromNative(
        jsonEncode({
          'connected_on': '2026-01-01 11:59:00',
          'byte_in': ' ',
          'byte_out': '42',
        }),
        now: now,
      );
      expect(status.duration, '00:01:00');
      expect(status.byteIn, '0');
      expect(status.byteOut, '42');
    });

    test('reads the string of 1.x packet tunnel providers', () {
      final status = VpnStatus.fromNative(
        '2026-01-01 11:00:00_1591_786_1947882_62696',
        now: now,
      );
      expect(status.duration, '01:00:00');
      expect(status.packetsIn, '1591');
      expect(status.packetsOut, '786');
      expect(status.byteIn, '1947882');
      expect(status.byteOut, '62696');
    });

    test('survives truncated and empty values', () {
      expect(VpnStatus.fromNative('_1').byteIn, '0');
      expect(VpnStatus.fromNative(null).duration, '00:00:00');
      expect(VpnStatus.fromNative('{not json').connectedOn, isNull);
    });

    test('toJson is JSON encodable', () {
      final status = VpnStatus.fromNative(
          {'connected_on': now.millisecondsSinceEpoch, 'byte_in': 1},
          now: now);
      expect(() => jsonEncode(status.toJson()), returnsNormally);
      expect(status.toJson()['connected_on'], now.toIso8601String());
    });
  });

  group('VpnLog.fromMap', () {
    test('reads time, level and message', () {
      final log = VpnLog.fromMap(
          {'time': 1000, 'level': 'warning', 'message': 'careful'});
      expect(log.time, DateTime.fromMillisecondsSinceEpoch(1000));
      expect(log.level, VpnLogLevel.warning);
      expect(log.message, 'careful');
      expect(log.toString(), contains('[warning] careful'));
    });

    test('defaults unknown levels to info', () {
      expect(VpnLog.fromMap({'level': 'loud'}).level, VpnLogLevel.info);
    });
  });

  group('configuration helpers', () {
    test('detect client certificates', () {
      expect(OpenVPN.hasClientCertificate('client\n<cert>\nabc\n</cert>\n'),
          isTrue);
      expect(OpenVPN.hasClientCertificate('cert client.crt\n'), isTrue);
      expect(OpenVPN.hasClientCertificate('pkcs12 client.p12\n'), isTrue);
      expect(OpenVPN.hasClientCertificate('client\nauth-user-pass\n'), isFalse);
      expect(OpenVPN.hasClientCertificate('# cert in a comment\n'), isFalse);
    });

    test('add client-cert-not-required on its own line, once', () {
      // 1.x appended it to the last line of the configuration.
      expect(OpenVPN.withClientCertNotRequired('client\n</ca>'),
          'client\n</ca>\nclient-cert-not-required\n');
      expect(OpenVPN.withClientCertNotRequired('client\n'),
          'client\nclient-cert-not-required\n');
      const already = 'client\nclient-cert-not-required\n';
      expect(OpenVPN.withClientCertNotRequired(already), already);
    });

    test('filteredConfig keeps one of several remotes in place', () async {
      const config = 'client\nremote a 1\nremote b 2\nremote c 3\nproto udp';
      final filtered = (await OpenVPN.filteredConfig(config))!.split('\n');
      expect(
          filtered.where((line) => line.startsWith('remote ')), hasLength(1));
      expect(filtered.first, 'client');
      expect(filtered[1], startsWith('remote '));
      expect(filtered.last, 'proto udp');
    });

    test('filteredConfig handles zero or one remote', () async {
      expect(await OpenVPN.filteredConfig(null), isNull);
      expect(await OpenVPN.filteredConfig('client'), 'client');
      expect(await OpenVPN.filteredConfig('remote a 1'), 'remote a 1');
    });
  });

  group('OpenVPN', () {
    late FakePlatform platform;
    late OpenVPN vpn;
    late List<String> stageCallbacks;
    late List<VpnStatus?> statusCallbacks;

    setUp(() {
      platform = FakePlatform()..install();
      stageCallbacks = [];
      statusCallbacks = [];
      vpn = OpenVPN(
        onVpnStageChanged: (stage, raw) => stageCallbacks.add(raw),
        onVpnStatusChanged: statusCallbacks.add,
      );
    });

    tearDown(() {
      vpn.dispose();
      debugDefaultTargetPlatformOverride = null;
    });

    Future<void> initialize() => vpn.initialize(
          groupIdentifier: 'group.test',
          providerBundleIdentifier: 'test.extension',
          localizedDescription: 'Test',
        );

    test('connect requires initialize', () {
      expect(() => vpn.connect('client', 'name'), throwsStateError);
    });

    test('initialize reports the current stage and status once', () async {
      VPNStage? lastStage;
      VpnStatus? lastStatus;
      await vpn.initialize(
        groupIdentifier: 'group.test',
        providerBundleIdentifier: 'test.extension',
        localizedDescription: 'Test',
        lastStage: (stage) => lastStage = stage,
        lastStatus: (status) => lastStatus = status,
        showTrafficInNotification: false,
      );
      expect(vpn.initialized, isTrue);
      expect(lastStage, VPNStage.disconnected);
      expect(lastStatus?.connectedOn, isNull);
      expect(stageCallbacks, ['disconnected']);
      expect(platform.last('initialize').arguments,
          containsPair('show_traffic_in_notification', false));
    });

    test('connect sends the options and returns true', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await initialize();
      final expireAt = DateTime(2030);
      final started = await vpn.connect(
        'client\n<ca>\n</ca>',
        'Server',
        username: 'user',
        password: 'pass',
        allowedPackages: ['com.example.browser'],
        privateKeyPassword: 'secret',
        expireAt: expireAt,
      );
      expect(started, isTrue);
      final arguments =
          platform.last('connect').arguments as Map<Object?, Object?>;
      // Android gets the configuration untouched.
      expect(arguments['config'], 'client\n<ca>\n</ca>');
      expect(arguments['name'], 'Server');
      expect(arguments['username'], 'user');
      expect(arguments['password'], 'pass');
      expect(arguments['allowed_packages'], ['com.example.browser']);
      expect(arguments['bypass_packages'], isEmpty);
      expect(arguments['cert_is_required'], isNull);
      expect(arguments['private_key_password'], 'secret');
      expect(arguments['expire_at'], expireAt.millisecondsSinceEpoch);
    });

    test('connect adds client-cert-not-required for OpenVPN 3 (iOS)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await initialize();

      await vpn.connect('client\nauth-user-pass', 'no cert');
      expect((platform.last('connect').arguments as Map)['config'],
          'client\nauth-user-pass\nclient-cert-not-required\n');

      await vpn.connect('client\n<cert>\nx\n</cert>', 'cert');
      expect((platform.last('connect').arguments as Map)['config'],
          'client\n<cert>\nx\n</cert>');

      await vpn.connect('client', 'forced', certIsRequired: false);
      expect((platform.last('connect').arguments as Map)['config'],
          'client\nclient-cert-not-required\n');
    });

    test('connect returns false when the permission is refused', () async {
      await initialize();
      platform.connectResult = false;
      expect(await vpn.connect('client', 'name'), isFalse);
    });

    test('connect treats the null answer of 1.x iOS as success', () async {
      await initialize();
      platform.connectResult = null;
      expect(await vpn.connect('client', 'name'), isTrue);
    });

    test('connect rethrows configuration errors', () async {
      await initialize();
      platform.connectError =
          PlatformException(code: 'invalid_config', message: 'bad');
      await expectLater(
          vpn.connect('nope', 'name'), throwsA(isA<PlatformException>()));
    });

    test('connect rejects allowed and bypassed packages together', () async {
      await initialize();
      expect(
        () => vpn.connect('client', 'name',
            allowedPackages: ['a'], bypassPackages: ['b']),
        throwsArgumentError,
      );
    });

    test('reports stage changes once, to callbacks and the stream', () async {
      await initialize();
      final stages = <VPNStage>[];
      vpn.stageStream.listen(stages.add);
      for (final stage in ['connecting', 'connecting', 'wait_connection']) {
        platform.emitStage(stage);
      }
      await pumpEventQueue();
      expect(stages, [VPNStage.connecting, VPNStage.wait_connection]);
      expect(stageCallbacks, ['disconnected', 'connecting', 'wait_connection']);
      expect(vpn.currentStage, VPNStage.wait_connection);
    });

    test('reports status while connected and resets it after', () async {
      await initialize();
      final connectedOn = DateTime.now().subtract(const Duration(minutes: 5));
      platform.status = {
        'connected_on': connectedOn.millisecondsSinceEpoch,
        'byte_in': 1000,
        'byte_out': 10,
      };
      platform.emitStage('connected');
      await pumpEventQueue();
      expect(vpn.currentStatus.connectedOn?.millisecondsSinceEpoch,
          connectedOn.millisecondsSinceEpoch);
      expect(vpn.currentStatus.duration, startsWith('00:05:0'));
      expect(statusCallbacks.last?.byteIn, '1000');

      platform.emitStage('disconnected');
      await pumpEventQueue();
      expect(vpn.currentStatus.connectedOn, isNull);
      expect(statusCallbacks.last?.duration, '00:00:00');
    });

    test('status is empty while not connected', () async {
      await initialize();
      platform.status = {'connected_on': 1, 'byte_in': 5};
      final status = await vpn.status();
      expect(status.connectedOn, isNull);
      expect(status.byteIn, '0');
    });

    test('disconnect waits for the tunnel to go down', () async {
      await initialize();
      platform.emitStage('connected');
      await pumpEventQueue();

      var done = false;
      final disconnecting = vpn.disconnect().then((_) => done = true);
      await pumpEventQueue();
      expect(platform.last('disconnect'), isNotNull);
      expect(done, isFalse);

      platform.emitStage('disconnecting');
      await pumpEventQueue();
      expect(done, isFalse);

      platform.emitStage('disconnected');
      await disconnecting;
      expect(done, isTrue);
    });

    test('disconnect returns at once when not connected', () async {
      await initialize();
      await vpn.disconnect().timeout(const Duration(seconds: 1));
    });

    test('disconnect never throws', () async {
      await initialize();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_control, (call) async {
        throw PlatformException(code: 'boom');
      });
      await vpn.disconnect();
    });

    test('logs and last error', () async {
      await initialize();
      final logs = await vpn.getLogs();
      expect(logs.single.message, 'TLS failed');
      expect(logs.single.level, VpnLogLevel.error);
      expect(await vpn.lastError(), 'TLS failed');

      final streamed = <VpnLog>[];
      final subscription = vpn.logStream.listen(streamed.add);
      await pumpEventQueue();
      platform.logSink!.success({'time': 5, 'level': 'info', 'message': 'hi'});
      await pumpEventQueue();
      expect(streamed.single.message, 'hi');
      await subscription.cancel();
    });

    test('instances share the native event streams', () async {
      await initialize();
      final other = OpenVPN();
      await other.initialize(
        groupIdentifier: 'group.test',
        providerBundleIdentifier: 'test.extension',
        localizedDescription: 'Test',
      );
      final first = <VPNStage>[];
      final second = <VPNStage>[];
      vpn.stageStream.listen(first.add);
      other.stageStream.listen(second.add);
      platform.emitStage('connecting');
      await pumpEventQueue();
      expect(first, [VPNStage.connecting]);
      expect(second, [VPNStage.connecting]);

      // Disposing one instance must not cut the other off.
      other.dispose();
      platform.emitStage('connected');
      await pumpEventQueue();
      expect(first, [VPNStage.connecting, VPNStage.connected]);
    });

    test('dispose during initialize leaves nothing running', () async {
      platform.stage = 'connected';
      platform.status = {'connected_on': 1000, 'byte_in': 1};
      final initializing = initialize();
      vpn.dispose();
      await initializing;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(vpn.initialized, isFalse);
      expect(platform.calls.where((call) => call.method == 'status'), isEmpty);
    });

    test('Android-only helpers', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(await vpn.requestPermissionAndroid(), isTrue);
      expect(await vpn.openVpnSettings(), isTrue);

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      platform.calls.clear();
      expect(await vpn.requestPermissionAndroid(), isTrue);
      expect(await vpn.openVpnSettings(), isFalse);
      expect(platform.calls, isEmpty);
    });
  });
}
