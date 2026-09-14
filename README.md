Connect to the OpenVPN service using Flutter. Contributions through issues and pull requests are highly appreciated!

## Android Setup

### 1. Permission Handler

#### Java
Include the following code in the `onActivityResult` method of `MainActivity.java` (if you are using Java):

```java
OpenVPNFlutterPlugin.connectWhileGranted(requestCode == 24 && resultCode == RESULT_OK);
```

The complete method should look like this:

```java
...
import id.laskarmedia.openvpn_flutter.OpenVPNFlutterPlugin;
...

@Override
protected void onActivityResult(int requestCode, int resultCode, Intent data) {
    OpenVPNFlutterPlugin.connectWhileGranted(requestCode == 24 && resultCode == RESULT_OK);
    super.onActivityResult(requestCode, resultCode, data);
}
```

#### Kotlin
Include the following code in the `onActivityResult` method of `MainActivity.kt` (if you are using Kotlin):

```kotlin
OpenVPNFlutterPlugin.connectWhileGranted(requestCode == 24 && resultCode == RESULT_OK);
```

The complete method should look like this:

```kotlin
...
import id.laskarmedia.openvpn_flutter.OpenVPNFlutterPlugin
...
override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    OpenVPNFlutterPlugin.connectWhileGranted(requestCode == 24 && resultCode == RESULT_OK)
    super.onActivityResult(requestCode, resultCode, data)
}
```

### 2. App Bundle Build Not Connecting

If you encounter issues with the app not connecting using the latest Flutter SDK, apply the following quick fix:

Ensure that you include the following attribute within the `<application>` tag in your `AndroidManifest.xml` file:

```xml
<application
    ...
    android:extractNativeLibs="true"
    ...>
</application>
```

## iOS Setup

### 1. Add Capabilities

Add the `App Groups` and `Network Extensions` capabilities to the Runner's target. Refer to the image below for detailed instructions:

<img src="https://blogger.googleusercontent.com/img/a/AVvXsEjYWGJ2ug4JM5g8_WslvdRY0Q-UUizOdmoCG8Ybhte9LiIv8_SSYFDHl-PzWApnAxvTA0hdpnBzca7C_zU5pHnyD8NLNoMw1ZOty7Zo6PTF22oIk7liB0aCXQnRAI1R0Zv9XfnuwuHuourtUR6lzf1ztrU_PTa6QFAU8kRPK-4h5MVu7QVzmpVs4Fvl=s600"/>

### 2. Add New Target

Click the `+` button on the bottom left, choose `NETWORK EXTENSION`, and follow the instructions in the image below:

<img src="https://blogger.googleusercontent.com/img/a/AVvXsEirvK1MMCqLADbXdtjppE-z1QC_cDPBnCWZ1EPkNLCM7TYyG3c2IGf8zlb1svW6aP6UB4eNOpX3svFwP_e9D0iP9Mb-dlXVtnUsYlg3iIQVqi_mmw4vLH5d8peEt7UGORikSlB3Hy0o1vj4XIBJNv5g8bIellHTXo4Zu4toh7Dt0jw4ZMyWDAoepLp7=s600"/>

Add the same capabilities to the VPNExtension as you did for the Runner's target:

<img src="https://blogger.googleusercontent.com/img/a/AVvXsEgEj_1oXmgRSaVISGFHutY88enlUG1V8ynqfDHso-uS6vKEBLa-dhhChjZQ12iN7UpNM6thCHLmll3h6p_lW9URAPca-pXkwIN1pmATdfk3NnqnmlYtgUAicbr-zDZmNF7JJ4l4EArFtdrb_IjxH_FpLJGCURkpGO9qBtkw9WYs3k2vRSa3c8ga9b6S=s600"/>

### 3. Copy and Paste

Add the following lines to your Podfile (`ios/Podfile`):

```dart
target 'VPNExtension' do
  use_frameworks!
  pod 'OpenVPNAdapter', :git => 'https://github.com/ss-abramchuk/OpenVPNAdapter.git', :tag => '0.8.0'
end
```

Open `VPNExtension > PacketTunnelProvider.swift` and copy-paste the script from [PacketTunnelProvider.swift](https://raw.githubusercontent.com/nizwar/openvpn_flutter/master/example/ios/VPNExtension/PacketTunnelProvider.swift).

<img src="https://blogger.googleusercontent.com/img/a/AVvXsEhPf7Vl_8LPYMTTCn0UbpR3f3qzaFPFRMikSg8xetWRyfTuViq6o3fdrjU4-jD-xZtkOZV_i2WoNXkcHLn7znHengHZGgtlJlNbNk6vjNYgI2jYg8ToOYIQjR7QBd443ee4GqpEww0FYPrIiIpabUthpur6SakiPJM1dsDNCBW9ROWixuEzrk61aIod=s600">

## macOS Setup

macOS uses the same `NETunnelProviderManager` API as iOS, so the Dart side is
identical. What differs is how the provider is packaged, and there are two
answers depending on how you ship.

### 1. Pick your packaging

| Distribution | Provider is a | Lives in |
|---|---|---|
| Mac App Store | App Extension (`.appex`) | `Contents/PlugIns/` |
| Developer ID (outside the store) | **System Extension** | `Contents/Library/SystemExtensions/` |

The entitlement value differs by **profile**, not by packaging:

| Profile | `com.apple.developer.networking.networkextension` value |
|---|---|
| Development | `packet-tunnel-provider` |
| Developer ID | `packet-tunnel-provider-systemextension` |

Both spellings exist (they sit next to each other in the OS string table, along
with the app-proxy, content-filter and dns-proxy pairs). Xcode's templates seed
the bare value for **both** target types, which is correct for development and
wrong for Developer ID — a Developer ID profile does not grant the bare value,
and a development profile does not grant the `-systemextension` one. To see what
a given profile actually grants:

```bash
security cms -D -i YourProfile.provisionprofile \
  | plutil -extract Entitlements xml1 -o - -
```

In Xcode: **File → New → Target →** either *Network Extension* under
**Application Extension** or under **System Extension**.

### 2. Capabilities

Add **Network Extensions** and **App Groups** to both the Runner target and the
new target.

**The App Group must be Team-ID prefixed on macOS.** This is the difference that
costs the most time: iOS takes `group.com.example.app`, macOS takes
`$(TeamIdentifierPrefix)group.com.example.app`. Pass the prefixed form to
`initialize(groupIdentifier:)` on macOS, or the app and the extension end up
reading two different `UserDefaults` suites — the tunnel connects and the app
reports nothing.

### 3. System Extension specifics

A system extension is a standalone executable, not a loaded bundle, so it needs
a `main.swift`:

```swift
import Foundation
import NetworkExtension

autoreleasepool { NEProvider.startSystemExtensionMode() }
dispatchMain()
```

and an `Info.plist` naming the provider class:

```xml
<key>NetworkExtension</key>
<dict>
    <key>NEProviderClasses</key>
    <dict>
        <key>com.apple.networkextension.packet-tunnel</key>
        <string>$(PRODUCT_MODULE_NAME).PacketTunnelProvider</string>
    </dict>
    <key>NEMachServiceName</key>
    <string>$(TeamIdentifierPrefix)group.com.example.app</string>
</dict>
<key>NSSystemExtensionUsageDescription</key>
<string>Needed to run the VPN tunnel.</string>
```

The containing app must install it at runtime with
`OSSystemExtensionManager.shared.submitRequest(...)` and the user approves it in
**System Settings → Privacy & Security**. Until it is approved, `connect()`
fails because there is no provider to start.

To test before notarizing: `systemextensionsctl developer on` (needs SIP
disabled). A notarized build does not need developer mode.

### 4. Podfile

```ruby
target 'VPNExtension' do
  use_frameworks!
  pod 'OpenVPNAdapter', :git => 'https://github.com/ss-abramchuk/OpenVPNAdapter.git', :tag => '0.8.0'
end
```

`OpenVPNAdapter` supports macOS (`osx 10.11` in its podspec), so the engine
itself needs nothing special.

### 5. Provider implementation

Identical to the iOS `PacketTunnelProvider.swift` in this README's iOS section.
The adapter, the delegate callbacks and the `providerConfiguration` keys are the
same on both platforms.

## Note

You must use iOS devices instead of the simulator to connect.

## Recipe

### Initialize

Before starting, initialize the OpenVPN plugin:

```dart
late OpenVPN openvpn;

@override
void initState() {
    openvpn = OpenVPN(onVpnStatusChanged: _onVpnStatusChanged, onVpnStageChanged: _onVpnStageChanged);
    openvpn.initialize(
        groupIdentifier: "GROUP_IDENTIFIER", ///Example 'group.com.laskarmedia.vpn'
        providerBundleIdentifier: "NETWORK_EXTENSION_IDENTIFIER", ///Example 'id.laskarmedia.openvpnFlutterExample.VPNExtension'
        localizedDescription: "LOCALIZED_DESCRIPTION" ///Example 'Laskarmedia VPN'
    );
}

void _onVpnStatusChanged(VPNStatus? vpnStatus){
    setState((){
        this.status = vpnStatus;
    });
}

void _onVpnStageChanged(VPNStage? stage){
    setState((){
        this.stage = stage;
    });
}
```

### Connect to VPN

```dart
void connect() {
  openvpn.connect(
    config,
    name,
    username: username,
    password: password,
    bypassPackages: [],
    // In iOS connection can get stuck in "connecting" if this flag is "false". 
    // Solution is to switch it to "true".
    certIsRequired: false,
  );
}
```

### Disconnect

```dart
void disconnect(){
    openvpn.disconnect();
}
```

# Publishing to Play Store and App Store

### Android

1. You can use app bundles to publish the app.
2. Add the following to your files in the `android` folder (special thanks to https://github.com/nizwar/openvpn_flutter/issues/10). Otherwise, the connection may not be established in some cases and will silently report "disconnected" when trying to connect. This is likely related to some symbols being stripped by Google Play.

```
gradle.properties > android.bundle.enableUncompressedNativeLibs=false
AndroidManifest > android:extractNativeLibs="true" in the application tag
```

Add the following inside the `android` tag in `app/build.gradle`:

```gradle
android {
    ...
    //from here ======
    lintOptions {
        disable 'InvalidPackage'
        checkReleaseBuilds false
    }

    packagingOptions {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    bundle {
        language {
            enableSplit = false
        }
        density {
            enableSplit = false
        }
        abi {
            enableSplit = false
        }
    }
    //to here
    ...
}
```

#### Notifications

As the plugin shows notifications for connection status and connection details, you must request permission using third-party packages.

Example using [permission_handler](https://pub.dev/packages/permission_handler):

```dart
///Put it anywhere you wish, like once you initialize the VPN or pre-connect to the server
Permission.notification.isGranted.then((_) {
  if (!_) Permission.notification.request();
});
```

### iOS

1. View [Apple Guidelines](https://developer.apple.com/app-store/review/guidelines/#vpn-apps) relating to VPN.
2. This plugin DOES use encryption, but it uses exempt encryptions.

## Licenses

* [openvpn_flutter](https://github.com/nizwar/openvpn_flutter/blob/master/LICENSE) for this plugin
* [ics-openvpn](https://github.com/schwabe/ics-openvpn) for the Android engine
* [OpenVPNAdapter](https://github.com/ss-abramchuk/OpenVPNAdapter) for the iOS engine

# Support

If you appreciate my work, don't forget to give a thumbs up or support me with a cup of coffee.

<a href="https://paypal.me/nizwar/"><img src="https://raw.githubusercontent.com/andreostrovsky/donate-with-paypal/master/blue.svg" height="40"></a>
