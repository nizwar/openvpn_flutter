Connect OpenVPN service with Flutter, Issues and PRs are very welcome!

## Installation

Add this to your package's pubspec.yaml file:

```dart
dependencies:
  openvpn_flutter: ^1.0.1

```

Run the command and you're ready to go
 

```dart
$ flutter pub get
```
 
## Android Installation
No need to setup anything on android 🤭


## iOS Installation

### <b>1. Add Capabillity</b>
Add 2 capabillity on Runner's Target, <b>App Groups</b> and <b>Network Extensions</b>, Look at the image below to get clearer details

<img src="https://blogger.googleusercontent.com/img/a/AVvXsEjYWGJ2ug4JM5g8_WslvdRY0Q-UUizOdmoCG8Ybhte9LiIv8_SSYFDHl-PzWApnAxvTA0hdpnBzca7C_zU5pHnyD8NLNoMw1ZOty7Zo6PTF22oIk7liB0aCXQnRAI1R0Zv9XfnuwuHuourtUR6lzf1ztrU_PTa6QFAU8kRPK-4h5MVu7QVzmpVs4Fvl=s600"/>

### <b>2. Add New Target</b>
Click + button on bottom left, Choose <b>NETWORK EXTENSION</b>, and follow instruction's image bellow

<img src="https://blogger.googleusercontent.com/img/a/AVvXsEirvK1MMCqLADbXdtjppE-z1QC_cDPBnCWZ1EPkNLCM7TYyG3c2IGf8zlb1svW6aP6UB4eNOpX3svFwP_e9D0iP9Mb-dlXVtnUsYlg3iIQVqi_mmw4vLH5d8peEt7UGORikSlB3Hy0o1vj4XIBJNv5g8bIellHTXo4Zu4toh7Dt0jw4ZMyWDAoepLp7=s600"/>

Add Capabillity on VPNExtension, Do it same like Runner's Capabillitiy

<img src="https://blogger.googleusercontent.com/img/a/AVvXsEgEj_1oXmgRSaVISGFHutY88enlUG1V8ynqfDHso-uS6vKEBLa-dhhChjZQ12iN7UpNM6thCHLmll3h6p_lW9URAPca-pXkwIN1pmATdfk3NnqnmlYtgUAicbr-zDZmNF7JJ4l4EArFtdrb_IjxH_FpLJGCURkpGO9qBtkw9WYs3k2vRSa3c8ga9b6S=s600"/>

All done, lets go back to flutter


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
    void connect(){
        openvpn.connect(config, name, username: username, password: password, bypassPackages: [], certIsRequired: false);
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

### iOS
1. View [Apple Guidelines](https://developer.apple.com/app-store/review/guidelines/#vpn-apps) Relating to VPN
2. This plugin DOES use Encryption BUT, It uses Exempt Encryptions


# Love my work?
☕️  ☕️  ☕️

<a href="https://paypal.me/nizwar/"><img src="https://raw.githubusercontent.com/andreostrovsky/donate-with-paypal/master/blue.svg" height="40"></a> 