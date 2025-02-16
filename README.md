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
