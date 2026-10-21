import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openvpn_flutter_example/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(
      const MethodChannel('id.laskarmedia.openvpn_flutter/vpncontrol'),
      (call) async => switch (call.method) {
        'initialize' || 'stage' => 'disconnected',
        'logs' => <Object?>[],
        _ => null,
      },
    );
    for (final name in ['vpnstage', 'vpnlog']) {
      messenger.setMockStreamHandler(
        EventChannel('id.laskarmedia.openvpn_flutter/$name'),
        MockStreamHandler.inline(onListen: (arguments, events) {}),
      );
    }
  });

  testWidgets('shows the disconnected state and the controls', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('OpenVPN Flutter'), findsOneWidget);
    expect(find.text('disconnected'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
  });
}
