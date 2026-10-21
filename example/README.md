# openvpn_flutter_example

Demonstrates the [openvpn_flutter](https://pub.dev/packages/openvpn_flutter) plugin:
connect with a pasted `.ovpn` configuration, follow the stage, traffic and speed,
and read the engine log.

## Run

```sh
flutter run
```

Paste a configuration in the app, or pass one when starting it:

```sh
flutter run --dart-define=OVPN_CONFIG=$(base64 < client.ovpn | tr -d '\n')
```

- **Android:** works on devices and emulators. The `android` project shows the
  required `useLegacyPackaging` setting.
- **iOS:** needs a device and a signing team with the Network Extensions
  capability; set your team, bundle identifiers and App Group in Xcode and in
  `lib/main.dart`. `ios/VPNExtension/PacketTunnelProvider.swift` is the packet
  tunnel provider to copy into your app.
- **macOS:** the runner builds the plugin; connecting needs a packet tunnel
  extension (see the plugin README).

When cloning the plugin repository, `git submodule update --init` fetches the
Android engine sources (`openvpn_library`), which the example then builds from;
pass `-Popenvpn.useJitpack=true` to Gradle to use the published engine instead.

## Integration tests

`integration_test/connection_test.dart` connects to a real server:

```sh
# Android: grant the VPN permission once per install
adb shell appops set id.laskarmedia.openvpn_flutter_example ACTIVATE_VPN allow
flutter test integration_test/connection_test.dart \
  --dart-define=OVPN_CONFIG=$(base64 < client.ovpn | tr -d '\n')
```
