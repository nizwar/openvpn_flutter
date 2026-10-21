# openvpn_flutter

[![pub package](https://img.shields.io/pub/v/openvpn_flutter.svg)](https://pub.dev/packages/openvpn_flutter)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://github.com/nizwar/openvpn_flutter/blob/master/LICENSE)

Connect to OpenVPN servers from Flutter apps on **Android**, **iOS** and **macOS**.
Contributions through issues and pull requests are highly appreciated!

- **Android:** a bundled OpenVPN 2.7 engine (ics-openvpn, OpenSSL 3.5) with
  **16 KB page size** support required by Google Play, per-app VPN (allow or
  bypass apps), a connection notification and no `MainActivity` changes.
- **iOS and macOS:** a NetworkExtension packet tunnel running OpenVPN 3 in your
  app's extension, with the same Dart API.
- One API everywhere: stage, traffic and log streams, an awaitable `connect()`
  and `disconnect()`, error reasons, session timeouts and encrypted private keys.

|                      | Android                     | iOS                         | macOS                       |
| -------------------- | --------------------------- | --------------------------- | --------------------------- |
| Minimum version      | 5.0 (API 21)                | 12.0                        | 10.15                       |
| Engine               | OpenVPN 2.7, bundled        | OpenVPN 3 (OpenVPNAdapter) in your Network Extension | same as iOS |
| Detailed stages      | yes                         | connecting / connected / reconnect / disconnecting | same as iOS |
| Per-app VPN          | `allowedPackages`, `bypassPackages` | –                   | –                           |
| Session timeout      | yes                         | yes (with the provided extension code) | same as iOS      |
| Engine log           | yes                         | yes (with the provided extension code) | same as iOS      |

Flutter 3.10 / Dart 3.0 or newer.

## Contents

- [Installation](#installation)
- [Android setup](#android-setup)
- [iOS setup](#ios-setup)
- [macOS setup](#macos-setup)
- [Usage](#usage)
- [Migrating from 1.x](#migrating-from-1x)
- [Troubleshooting](#troubleshooting)
- [Licenses](#licenses)

## Installation

```sh
flutter pub add openvpn_flutter
```

## Android setup

### 1. Extract native libraries (required)

OpenVPN runs as its own process from a native library, so the library must be
extracted when the app is installed. Recent Android Gradle Plugin versions do
not extract native libraries unless the app asks for it, and the VPN then stops
right after connecting ("OpenVPN process exited"). Add this to the `android`
block of `android/app/build.gradle.kts`:

```kotlin
android {
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}
```

or, in `android/app/build.gradle`:

```groovy
android {
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}
```

This covers APKs and App Bundles (Google Play). Without it, `connect()` fails
with a `native_libraries_not_extracted` error that says the same, and the
Gradle build prints a warning.

### 2. Notification permission

The VPN runs as a foreground service with a notification. On Android 13+ ask
for the notification permission, for example with
[permission_handler](https://pub.dev/packages/permission_handler):

```dart
await Permission.notification.request();
```

The VPN works without it, but the notification is then hidden.

### 3. Publishing on Google Play

- Fill in the VPN declaration in the Play Console (VpnService).
- Declare the **systemExempted** foreground service type (used for VPN apps on
  Android 14+) in the Play Console's foreground service declaration.
- Only ship the ABIs you need to make the app smaller:

  ```kotlin
  android {
      defaultConfig {
          ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
      }
  }
  ```

### Optional: the notification

- Icon: add your own `android/app/src/main/res/drawable/ic_notification.png`
  (or `.xml`); it replaces the engine's icon.
- Title: the `name` you pass to `connect()`.
- "Disconnect" button label: override the `cancel_connection` string in
  `android/app/src/main/res/values/strings.xml`.
- `initialize(showTrafficInNotification: false)` keeps the notification static
  instead of refreshing it with the traffic every two seconds (some launchers
  show that as a blinking icon).

A foreground service cannot run without a notification, so it cannot be hidden.

### Optional: dependency resolution

The engine is downloaded from [JitPack](https://jitpack.io/#nizwar/openvpn_library).
The plugin adds that repository to the project. If your `settings.gradle(.kts)`
uses `dependencyResolutionManagement` with `RepositoriesMode.FAIL_ON_PROJECT_REPOS`,
add it there:

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}
```

Nothing else is needed: the plugin asks for the VPN permission itself, so the
`onActivityResult` / `connectWhileGranted` code of 1.x can be removed from your
`MainActivity` (it is harmless if it stays).

## iOS setup

VPN apps on iOS run the VPN in a Network Extension. You add one to your app and
put the provided `PacketTunnelProvider.swift` in it. VPN extensions do not run
in the simulator: test on a device.

### 1. Capabilities

Add the **App Groups** and **Network Extensions** (Packet Tunnel) capabilities to
the Runner target:

<img src="https://blogger.googleusercontent.com/img/a/AVvXsEjYWGJ2ug4JM5g8_WslvdRY0Q-UUizOdmoCG8Ybhte9LiIv8_SSYFDHl-PzWApnAxvTA0hdpnBzca7C_zU5pHnyD8NLNoMw1ZOty7Zo6PTF22oIk7liB0aCXQnRAI1R0Zv9XfnuwuHuourtUR6lzf1ztrU_PTa6QFAU8kRPK-4h5MVu7QVzmpVs4Fvl=s600"/>

### 2. Network Extension target

In Xcode, **File → New → Target… → Network Extension**, name it (for example)
`VPNExtension`, provider type **Packet Tunnel**:

<img src="https://blogger.googleusercontent.com/img/a/AVvXsEirvK1MMCqLADbXdtjppE-z1QC_cDPBnCWZ1EPkNLCM7TYyG3c2IGf8zlb1svW6aP6UB4eNOpX3svFwP_e9D0iP9Mb-dlXVtnUsYlg3iIQVqi_mmw4vLH5d8peEt7UGORikSlB3Hy0o1vj4XIBJNv5g8bIellHTXo4Zu4toh7Dt0jw4ZMyWDAoepLp7=s600"/>

Give the extension the same two capabilities and the **same App Group**:

<img src="https://blogger.googleusercontent.com/img/a/AVvXsEgEj_1oXmgRSaVISGFHutY88enlUG1V8ynqfDHso-uS6vKEBLa-dhhChjZQ12iN7UpNM6thCHLmll3h6p_lW9URAPca-pXkwIN1pmATdfk3NnqnmlYtgUAicbr-zDZmNF7JJ4l4EArFtdrb_IjxH_FpLJGCURkpGO9qBtkw9WYs3k2vRSa3c8ga9b6S=s600"/>

Set the extension's **Minimum Deployments** to the same iOS version as Runner.
An extension that requires a newer iOS than the device fails with
"Update required" in the system VPN settings.

### 3. OpenVPNAdapter

The extension runs OpenVPN with [OpenVPNAdapter](https://github.com/ss-abramchuk/OpenVPNAdapter).
With CocoaPods, add a **top-level** target to `ios/Podfile` (not nested inside
`target 'Runner'`, or the extension inherits every Flutter plugin and fails to
link):

```ruby
target 'VPNExtension' do
  use_frameworks!
  pod 'OpenVPNAdapter', :git => 'https://github.com/ss-abramchuk/OpenVPNAdapter.git', :tag => '0.8.0'
end
```

Without CocoaPods, add it with Swift Package Manager instead: **File → Add Package
Dependencies…**, `https://github.com/ss-abramchuk/OpenVPNAdapter.git`, version
`0.8.0`, added to the `VPNExtension` target.

### 4. Packet tunnel provider

Replace `VPNExtension/PacketTunnelProvider.swift` with
[PacketTunnelProvider.swift](https://raw.githubusercontent.com/nizwar/openvpn_flutter/master/example/ios/VPNExtension/PacketTunnelProvider.swift).
It reads what the plugin sends (configuration, credentials, private key
password, session end), answers status requests and writes the OpenVPN log and
errors to the App Group so the app can show them.

<img src="https://blogger.googleusercontent.com/img/a/AVvXsEhPf7Vl_8LPYMTTCn0UbpR3f3qzaFPFRMikSg8xetWRyfTuViq6o3fdrjU4-jD-xZtkOZV_i2WoNXkcHLn7znHengHZGgtlJlNbNk6vjNYgI2jYg8ToOYIQjR7QBd443ee4GqpEww0FYPrIiIpabUthpur6SakiPJM1dsDNCBW9ROWixuEzrk61aIod=s600">

### 5. Build phase order

In the Runner target's **Build Phases**, drag **Embed Foundation Extensions**
(or "Embed App Extensions") above **Thin Binary** and **Run Script**. Otherwise
Xcode reports "Cycle inside Runner; building could produce unreliable results".

### 6. Initialize with your identifiers

Pass the App Group and the extension's bundle identifier to `initialize()`, see
[Usage](#usage).

## macOS setup

macOS uses the same `NETunnelProviderManager` API, so the Dart side and the
`PacketTunnelProvider.swift` above are the same. What differs is how the
provider is packaged:

| Distribution                     | Provider is a                | Entitlement value (`com.apple.developer.networking.networkextension`) |
| -------------------------------- | ---------------------------- | ----------------------------------------------- |
| Mac App Store                    | App Extension (`.appex`)     | `packet-tunnel-provider`                        |
| Developer ID (outside the store) | System Extension             | `packet-tunnel-provider-systemextension` (Developer ID profile), `packet-tunnel-provider` while developing |

- **App Group identifiers are Team ID prefixed on macOS**:
  `$(TeamIdentifierPrefix)group.com.example.app`. Pass that full value to
  `initialize(groupIdentifier:)`, otherwise the app and the extension use
  different containers and status and logs stay empty.
- A **System Extension** needs a `main.swift` (`autoreleasepool { NEProvider.startSystemExtensionMode() }`
  then `dispatchMain()`), an `Info.plist` with `NetworkExtension → NEProviderClasses`
  and `NEMachServiceName`, and the app must install it with
  `OSSystemExtensionManager` and the user approves it in **System Settings →
  General → Login Items & Extensions → Network Extensions**. macOS only installs
  system extensions of apps running from `/Applications`.
- CocoaPods does not embed frameworks into a System Extension: add a Run Script
  phase executing `"${PODS_ROOT}/Target Support Files/Pods-VPNExtension/Pods-VPNExtension-frameworks.sh"`
  as the extension's last build phase, or use Swift Package Manager for
  OpenVPNAdapter.
- Sign inside out: the framework, the extension with its entitlements, then the
  app (no `--deep`).

## Usage

### Initialize

```dart
import 'package:openvpn_flutter/openvpn_flutter.dart';

late final OpenVPN openvpn;

@override
void initState() {
  super.initState();
  openvpn = OpenVPN(
    onVpnStageChanged: (stage, raw) => setState(() => this.stage = stage),
    onVpnStatusChanged: (status) => setState(() => this.status = status),
  );
  openvpn.initialize(
    // iOS and macOS:
    groupIdentifier: 'group.com.example.vpn',
    providerBundleIdentifier: 'com.example.app.VPNExtension',
    localizedDescription: 'Example VPN', // name in the system VPN settings
    // State of a VPN that was already running (app reopened while connected):
    lastStage: (stage) => setState(() => this.stage = stage),
    lastStatus: (status) => setState(() => this.status = status),
  );
}
```

`stageStream`, `statusStream` and `logStream` report the same as the callbacks;
`currentStage` and `currentStatus` hold the latest values. Call `dispose()` when
you no longer need the instance (the VPN keeps running).

### Connect

```dart
try {
  final started = await openvpn.connect(
    ovpnFileContent, // the content of the .ovpn file
    'Japan #1',      // shown in the Android notification
    username: username, // for auth-user-pass configurations
    password: password,
  );
  if (!started) {
    // The user refused the VPN permission (stage: VPNStage.denied).
  }
} on PlatformException catch (e) {
  // Invalid configuration, missing engine, iOS entitlements, ...
  print('${e.code}: ${e.message}');
}
```

`connect()` completes once the connection is starting; the stages tell how it
goes. To wait for the outcome:

```dart
await openvpn.connect(config, 'Japan #1');
final stage = await openvpn.stageStream
    .firstWhere((stage) => stage.isConnected || stage.isDisconnected)
    .timeout(const Duration(seconds: 30), onTimeout: () => openvpn.currentStage);
if (!stage.isConnected) {
  print('Failed: ${await openvpn.lastError()}');
  await openvpn.disconnect(); // stop retrying
}
```

Other options:

```dart
await openvpn.connect(
  config,
  'Japan #1',
  // Encrypted <key>:
  privateKeyPassword: 'key passphrase',
  // Disconnect automatically, even with the app closed:
  expireAt: DateTime.now().add(const Duration(hours: 1)),
  // Android: only these apps use the VPN...
  allowedPackages: ['com.android.chrome'],
  // ...or every app except these (not both):
  // bypassPackages: ['com.example.banking'],
  // Whether the configuration uses a client certificate; detected when null.
  certIsRequired: null,
);
```

Calling `connect()` while connected switches to the new server.

### Disconnect

```dart
await openvpn.disconnect(); // completes once the tunnel is down
```

### Status

```dart
final status = await openvpn.status(); // or currentStatus / statusStream
status.connectedOn; // DateTime?, null while not connected
status.duration;    // '01:02:03'
status.byteIn;      // bytes received, as a string
status.byteOut;     // bytes sent
status.speedIn;     // bytes per second
status.speedOut;
```

### Stages

| Stage | Meaning |
| --- | --- |
| `prepare` | Waiting for the Android VPN permission dialog |
| `vpn_generate_config`, `resolve`, `tcp_connect`, `wait_connection`, `authenticating`, `get_config`, `assign_ip`, `add_routes` | Connection progress (Android) |
| `connecting` | Connecting |
| `connected` | The tunnel is up |
| `reconnect` | The connection dropped and is coming back |
| `no_network` / `paused` | Waiting for a network / paused while the screen is off (Android) |
| `auth_pending` | Waiting for extra authentication (Android) |
| `disconnecting`, `exiting` | Stopping |
| `disconnected` | No tunnel |
| `denied` | The user refused the VPN permission |
| `auth_failed` | The server rejected the credentials or certificate |
| `error` | The connection failed or stopped on its own; see `lastError()` |
| `unknown` | A stage this version does not know |

`stage.isConnected`, `stage.isConnecting` and `stage.isDisconnected` group them.

### Logs and errors

```dart
final logs = await openvpn.getLogs(); // the engine log so far
openvpn.logStream.listen((log) => print('${log.level.name}: ${log.message}'));
final reason = await openvpn.lastError(); // why the last connection failed
```

On iOS and macOS the log and errors come from the packet tunnel provider above.

### Kill switch and always-on (Android)

Android has these as system settings: "Always-on VPN" and "Block connections
without VPN". `openvpn.openVpnSettings()` opens that screen.

### Disconnect when the app is swiped away (Android)

```dart
openvpn.initialize(disconnectOnTaskRemoved: true);
```

### Without an activity (Android)

`initialize`, `connect`, `disconnect`, `status` and the streams also work from
background isolates and services (no activity). The VPN permission has to be
granted once from the UI first (`requestPermissionAndroid()` or a `connect()`).

### Configurations with many remotes

```dart
final config = await OpenVPN.filteredConfig(ovpnFileContent); // keeps one random remote
```

## Migrating from 1.x

1. **Android:** add `useLegacyPackaging = true` (see [Android setup](#1-extract-native-libraries-required)).
   The `onActivityResult` / `connectWhileGranted` code in `MainActivity` is no
   longer needed.
2. `connect()` returns `Future<bool>` (`false` when the permission is refused)
   and throws `PlatformException` for invalid configurations: wrap it in
   `try`/`catch`. On Android it used to never complete.
3. `disconnect()` returns a `Future` that completes once the tunnel is down.
4. New stages: `add_routes`, `reconnect`, `auth_pending`, `auth_failed`,
   `no_network`, `paused`. Exhaustive `switch`es over `VPNStage` need them;
   stages that used to be `unknown` (like `reconnect`) now have their own value.
5. `certIsRequired` is detected from the configuration when omitted. On Android
   it no longer appends `client-cert-not-required` to the configuration.
6. iOS: replace `PacketTunnelProvider.swift` with the new one, use OpenVPNAdapter
   `0.8.0`, and give the extension the same deployment target as the app.
7. `VpnStatus.packetsIn/packetsOut` are `null` on Android (they repeated the byte
   counts); `VpnStatus.toJson()` encodes `connected_on` as an ISO 8601 string.
8. `bypassPackages` only excludes those apps; it no longer lets every app bypass
   the VPN on its own.
9. The Android engine is OpenVPN 2.7 with OpenSSL 3.5. Servers that cannot
   negotiate ciphers keep working when the configuration names its `cipher`; see
   [Troubleshooting](#troubleshooting) for BF-CBC and weak certificates.

## Troubleshooting

`await openvpn.lastError()` and `await openvpn.getLogs()` usually tell what went
wrong; the issues below are the frequent ones.

**Android: "OpenVPN process exited", "no process running", connects then
disconnects, works in debug but not from Google Play.** The native libraries are
not extracted: add `useLegacyPackaging = true`
([Android setup](#1-extract-native-libraries-required)).

**Android: "You must select a User certificate".** The configuration has neither
a client certificate (`<cert>`/`<key>`) nor `auth-user-pass`. Pass a username and
password, or fix the configuration.

**"No usable data channel cipher", VPN Gate or OpenVPN 2.3 servers stuck
reconnecting.** OpenVPN 2.6+ only falls back to the configuration's `cipher` when
told to; the plugin adds `data-ciphers-fallback` for you on Android. For servers
that rely on the old BF-CBC default without a `cipher` line, add to the
configuration:

```
data-ciphers AES-256-GCM:AES-128-GCM:BF-CBC
data-ciphers-fallback BF-CBC
providers legacy default
```

**"FATAL: could not read Private Key", "private key password verification
failed".** The `<key>` is encrypted: pass `privateKeyPassword`.

**`auth_failed`.** Wrong credentials, or the server refused the session (some
public servers limit sessions per IP address).

**"MissingForegroundServiceTypeException".** Fixed since 1.3.4; update.

**16 KB page size warnings in Google Play.** Fixed in 2.0.0.

**iOS: connects and disconnects immediately.** Check `lastError()` and the log,
then: the extension's deployment target (see below), the App Group (same in
both targets and in `initialize()`), credentials for `auth-user-pass`
configurations, and options OpenVPN 3 does not support.

**iOS: "Update required" in the VPN settings.** The extension's deployment
target is newer than the device's iOS: lower it to match Runner.

**iOS: "permission denied" (NEConfigurationErrorDomain 10).** The app lacks the
Network Extensions capability or provisioning profile, or runs in the simulator.

**iOS: "Cycle inside Runner".** Move **Embed Foundation Extensions** above
**Thin Binary** ([iOS setup](#5-build-phase-order)).

**iOS: "Module 'openvpn_flutter' not found".** Open `Runner.xcworkspace`, not
`Runner.xcodeproj`, and run `pod install` in `ios/`. With Swift Package Manager
on Flutter versions before 3.44, use CocoaPods instead:
`flutter config --no-enable-swift-package-manager`.

**iOS: "Undefined symbol" errors (MarketplaceKit, `__swift_FORCE_LOAD_...`).**
The extension's Podfile target is nested inside `target 'Runner'`; make it a
top-level target.

**WireGuard, IKEv2, Windows, Linux.** Not supported; this plugin is for
OpenVPN on Android, iOS and macOS.

## Licenses

- [openvpn_flutter](https://github.com/nizwar/openvpn_flutter/blob/master/LICENSE) (GPLv3)
- [ics-openvpn](https://github.com/schwabe/ics-openvpn), through [openvpn_library](https://github.com/nizwar/openvpn_library), for the Android engine
- [OpenVPNAdapter](https://github.com/ss-abramchuk/OpenVPNAdapter) for the iOS and macOS engine

## Support

If you appreciate this work, give it a thumbs up or support it with a cup of coffee.

<a href="https://paypal.me/nizwar/"><img src="https://raw.githubusercontent.com/andreostrovsky/donate-with-paypal/master/blue.svg" height="40"></a>
