Connect OpenVPN service with Flutter, Issues and PRs are very welcome!

## Android Setup
### <b>1. Permission handler</b>
Add this to your onActivityResult in MainActivity.java

```java
    OpenVPNFlutterPlugin.connectWhileGranted(requestCode == 24 && resultCode == RESULT_OK);
```
So it look like this
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

## iOS Setup

### <b>1. Add Capabillity</b>
Add 2 capabillity on Runner's Target, <b>App Groups</b> and <b>Network Extensions</b>, Look at the image below to get clearer details

<img src="https://blogger.googleusercontent.com/img/a/AVvXsEjYWGJ2ug4JM5g8_WslvdRY0Q-UUizOdmoCG8Ybhte9LiIv8_SSYFDHl-PzWApnAxvTA0hdpnBzca7C_zU5pHnyD8NLNoMw1ZOty7Zo6PTF22oIk7liB0aCXQnRAI1R0Zv9XfnuwuHuourtUR6lzf1ztrU_PTa6QFAU8kRPK-4h5MVu7QVzmpVs4Fvl=s600"/>

### <b>2. Add New Target</b>
Click + button on bottom left, Choose <b>NETWORK EXTENSION</b>, and follow instruction's image bellow

<img src="https://blogger.googleusercontent.com/img/a/AVvXsEirvK1MMCqLADbXdtjppE-z1QC_cDPBnCWZ1EPkNLCM7TYyG3c2IGf8zlb1svW6aP6UB4eNOpX3svFwP_e9D0iP9Mb-dlXVtnUsYlg3iIQVqi_mmw4vLH5d8peEt7UGORikSlB3Hy0o1vj4XIBJNv5g8bIellHTXo4Zu4toh7Dt0jw4ZMyWDAoepLp7=s600"/>

Add Capabillity on VPNExtension, Do it same like Runner's Capabillitiy

<img src="https://blogger.googleusercontent.com/img/a/AVvXsEgEj_1oXmgRSaVISGFHutY88enlUG1V8ynqfDHso-uS6vKEBLa-dhhChjZQ12iN7UpNM6thCHLmll3h6p_lW9URAPca-pXkwIN1pmATdfk3NnqnmlYtgUAicbr-zDZmNF7JJ4l4EArFtdrb_IjxH_FpLJGCURkpGO9qBtkw9WYs3k2vRSa3c8ga9b6S=s600"/>

### <b>3. Copy Paste</b>
Add the following lines to your Podfile (`ios/Podfile`)

```dart
target 'VPNExtension' do
  use_frameworks!
  pod 'OpenVPNAdapter', :git => 'https://github.com/ss-abramchuk/OpenVPNAdapter.git', :tag => '0.8.0'
end
```

Open VPNExtension > PacketTunnelProvider.swift and copy paste this script <a href="https://raw.githubusercontent.com/nizwar/openvpn_flutter/master/example/ios/VPNExtension/PacketTunnelProvider.swift">PacketTunnelProvider.swift</a>

<img src="https://blogger.googleusercontent.com/img/a/AVvXsEhPf7Vl_8LPYMTTCn0UbpR3f3qzaFPFRMikSg8xetWRyfTuViq6o3fdrjU4-jD-xZtkOZV_i2WoNXkcHLn7znHengHZGgtlJlNbNk6vjNYgI2jYg8ToOYIQjR7QBd443ee4GqpEww0FYPrIiIpabUthpur6SakiPJM1dsDNCBW9ROWixuEzrk61aIod=s600">

## Note
You must use iOS Devices instead of Simulator to connect



## Recipe

### Initialize
Before start, you have to initialize the OpenVPN plugin.

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
    // In iOS connection can stuck in "connecting" if this flag is "false". 
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
1. You can use appbundle to publish the app
2. Add this to your files in `android` folder (special thanks to https://github.com/nizwar/openvpn_flutter/issues/10). Otherwise connection will not be
established in some cases and will siliently report "disconnected" when trying to connect. Most likely it's related to some symbols stripping by
Google Play.
```
gradle.properties > android.bundle.enableUncompressedNativeLibs=false
AndroidManifest > android:extractNativeLibs="true" in application tag
```

### iOS
1. View [Apple Guidelines](https://developer.apple.com/app-store/review/guidelines/#vpn-apps) Relating to VPN
2. This plugin DOES use Encryption BUT, It uses Exempt Encryptions

## Licenses
* [openvpn_flutter](https://github.com/nizwar/openvpn_flutter/blob/master/LICENSE) for this plugin
* [ics-openvpn](https://github.com/schwabe/ics-openvpn) for Android Engine 
* [OpenVPNAdapter](https://github.com/ss-abramchuk/OpenVPNAdapter) for iOS Engine
# Love my work?
Don't forget to give me a 👍 &nbsp;or support me with a cup of ☕️  

<a href="https://paypal.me/nizwar/"><img src="https://raw.githubusercontent.com/andreostrovsky/donate-with-paypal/master/blue.svg" height="40"></a> 
