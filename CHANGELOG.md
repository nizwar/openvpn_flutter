## 2.0.1

Documentation only.

* macOS: a complete guide to packaging the provider as a System Extension
  (#152, thanks @kekko7072). Its `main.swift` has to run the main run loop with
  `CFRunLoopRun()`: with `dispatchMain()`, as the 2.0.0 README said, the tunnel
  connects but never receives packets.

## 2.0.0

A major update: a new Android engine, macOS support, one shared iOS/macOS
implementation and a reworked Dart API. See "Migrating from 1.x" in the README.

### Android
* New engine: OpenVPN 2.7 with OpenSSL 3.5 and native libraries aligned for
  16 KB memory pages, as Google Play requires (#145).
* No `MainActivity` changes anymore: the plugin handles the VPN permission
  result itself (`connectWhileGranted` still works).
* `connect()`, `disconnect()` and `requestPermissionAndroid()` complete; the
  permission request waits for the user's answer (#96, #144).
* Configuration problems are returned as errors instead of being logged, and
  configurations without a client certificate use username/password instead of
  failing with "You must select a User certificate" (#90, #149).
* A clear `native_libraries_not_extracted` error (and a build warning) when the
  app packages native libraries without extracting them, the cause of "OpenVPN
  process exited" and of connections failing only in release builds or from
  Google Play (#51, #67, #68, #97, #125, #128, #133, #143).
* Servers that cannot negotiate ciphers (OpenVPN 2.3, VPN Gate/SoftEther) work
  again: the configuration's `cipher` is used as fallback, and BF-CBC & co. load
  OpenSSL's legacy provider (#73, #94, #95, #122).
* Works without an activity, from background isolates and services (#127, #146).
* Every engine state is reported (no more `unknown` for reconnecting, no
  network, ...), "error" when OpenVPN stops on its own (#70, #83).
* One connection notification instead of two, no `startForeground()` on every
  traffic update, and `showTrafficInNotification: false` for a static one
  (#71, #140). The notification and the system VPN settings open the app.
* `allowedPackages`: only the listed apps use the VPN (#22, #134).
* `privateKeyPassword` for encrypted private keys (#111, #124).
* `expireAt`: disconnect at a given time, even with the app closed and after
  the system restarts the VPN service (#18, #112).
* `disconnectOnTaskRemoved`: stop the VPN when the app is swiped away (#59).
* `openVpnSettings()`: the system screen for always-on VPN and "Block
  connections without VPN" (#77).
* Graceful disconnect that never throws, also right after `connect()`, and it
  cancels a connection still waiting for the permission dialog.
* Stopping the VPN from the notification, the system settings or by swiping
  the app away reports `disconnected`, not `error`; a rejected login reports
  `auth_failed` with its reason.
* Fix a crash when `allowedPackages`/`bypassPackages` name an app that is not
  installed.
* The engine's activities are no longer exported to other apps; R8 rules keep
  the engine intact in minified builds.
* Builds with Android Gradle Plugin 8 and 9; minimum SDK 21.

### iOS and macOS
* macOS support (#151, thanks @kekko7072), sharing one Swift implementation with
  iOS, through CocoaPods or Swift Package Manager, with a privacy manifest.
* The stage of an already running VPN is reported after the app restarts (#12).
* Traffic counters come straight from the packet tunnel provider: status is no
  longer empty or one call behind (#35, #53, #55).
* "denied" when the user refuses the VPN configuration (#76), "reconnect"
  instead of `unknown` (#74), "error" with `lastError()` when the tunnel ends on
  its own (#72, #75, #84, #102, #129, #132).
* Calls are answered exactly once (connect before initialize used to answer
  twice), `disconnect()` answers.
* Switching servers while connected waits for the old tunnel to stop.
* New `PacketTunnelProvider.swift`: no `fatalError()`, works on iOS 12+ (#34),
  credentials from the plugin, private key password, session end, log and last
  error shared with the app (#44), status replies.
* Example: OpenVPNAdapter 0.8.0, extension deployment target matching the app
  (#123), app extensions embedded before "Thin Binary" (#126).

### Dart API
* `stageStream`, `statusStream`, `logStream`, `currentStage`, `currentStatus`,
  `getLogs()`, `lastError()`, `dispose()`.
* `connect()` returns whether the connection is starting (`false` when the
  permission is refused) and throws `PlatformException` for errors; it takes
  `allowedPackages`, `privateKeyPassword` and `expireAt`, and `certIsRequired`
  is detected from the configuration when omitted.
* `disconnect()` completes once the tunnel is down.
* New stages `add_routes`, `reconnect`, `auth_pending`, `auth_failed`,
  `no_network`, `paused`, exact stage name mapping, and
  `isConnected`/`isConnecting`/`isDisconnected`.
* `VpnStatus` reports `speedIn`/`speedOut`; `toJson()` is JSON encodable.
* `client-cert-not-required` is no longer glued to the last line of the
  configuration.
* `filteredConfig()` no longer throws with a single remote.
* No `dart:io` import: apps that also build for the web compile.
* Requires Dart 3.0 / Flutter 3.10.

## 1.3.4
* Fix notification issue for newest SDK
## 1.3.3
* Solving namespace for android build
## 1.3.2
* Fix datetime that being nulled (VPN Status)
## 1.3.1
* Upgrade library gradles
* Update native for Permission channel name ($APPNAME VPN Background & $APPNAME VPN Stats)
* Clearify notifications on readme.md
## 1.3.0
* Adept for SDK 34
* Solving #105, #29, #99
* Update examples to support flutter latest flutter (3.22.2 tested)
## 1.2.2
* Update openvpnlib
## 1.2.1
* Update openvpnlib
## 1.2.0+1
* Update docs
## 1.2.0
* Fix iOS issues (byteIn and byteOut not updated) #6
* Add lastStatus and lastStage listener while initialize
* Add packetsIn, packetsOut and connectedOn status
* Update licenses to GPL3 (Before it was MIT)
## 1.1.3
* Add permission request for android ```requestPermissionAndroid()``` #5
* Continue the connection after user grant vpn connection #8
## 1.1.2
* Fix exported errors on SDK 31
* PendingIntent errors fixes
## 1.1.1+1
* Update readme, more detail about iOS setup
## 1.1.1
* Fix iOS by Adding PacketTunnelProvider
* More detail at instructions
* Fix VPNStatus not updated after disconnected
## 1.1.0
* Add 'raw' on onVpnStageChanged
* Add details on doc
* Fix duration still going on failed to connect
## 1.0.1+2
* Solving scores
## 1.0.1+1
* iOS Support
* Android Support
