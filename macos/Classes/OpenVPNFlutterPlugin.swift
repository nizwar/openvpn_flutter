//  OpenVPNFlutterPlugin.swift — macOS
//
//  The macOS half of the plugin. NetworkExtension's NETunnelProviderManager API
//  is identical on both Apple platforms, so this is the iOS implementation with
//  three differences, all of them at the embedder boundary rather than in the
//  VPN logic:
//
//    1. FlutterMacOS instead of Flutter.
//    2. `registrar.messenger` is a PROPERTY on macOS and a METHOD on iOS
//       (FlutterPluginRegistrarMacOS.h declares it @property; the iOS
//       FlutterPluginRegistrar declares it as a method). This is the one line
//       that will not compile if the file is naively shared.
//    3. No UIKit. The iOS file imports it and never uses it.
//
//  The imports below are written conditionally so this file can move to a
//  shared `darwin/` directory under `sharedDarwinSource: true` later without
//  being rewritten — only the registrar line needs the #if then.
//
//  WHAT IS DIFFERENT ABOUT macOS, AND IT IS NOT IN THIS FILE: a packet tunnel
//  provider for an app shipped with Developer ID has to be a System Extension,
//  not an app extension, and the host app has to install it with
//  OSSystemExtensionRequest and have the user approve it. That is the host
//  app's job; this plugin only ever talks to NETunnelProviderManager, which
//  does not care which of the two is behind `providerBundleIdentifier`. See the
//  macOS section of the README.

#if canImport(FlutterMacOS)
import FlutterMacOS
#else
import Flutter
#endif
import Foundation
import NetworkExtension

public class OpenVPNFlutterPlugin: NSObject, FlutterPlugin {
    private static var utils: VPNUtils! = VPNUtils()

    private static var EVENT_CHANNEL_VPN_STAGE = "id.laskarmedia.openvpn_flutter/vpnstage"
    private static var METHOD_CHANNEL_VPN_CONTROL = "id.laskarmedia.openvpn_flutter/vpncontrol"

    public static var stage: FlutterEventSink?
    private var initialized: Bool = false

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = OpenVPNFlutterPlugin()
        instance.onRegister(registrar)
    }

    public func onRegister(_ registrar: FlutterPluginRegistrar) {
        // `registrar.messenger` — a property here, `registrar.messenger()` on
        // iOS. The single source-level incompatibility between the two files.
        let messenger = registrar.messenger
        let vpnControlM = FlutterMethodChannel(
            name: OpenVPNFlutterPlugin.METHOD_CHANNEL_VPN_CONTROL,
            binaryMessenger: messenger)
        let vpnStageE = FlutterEventChannel(
            name: OpenVPNFlutterPlugin.EVENT_CHANNEL_VPN_STAGE,
            binaryMessenger: messenger)

        vpnStageE.setStreamHandler(StageHandler())
        vpnControlM.setMethodCallHandler({
            (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
            switch call.method {
            case "status":
                OpenVPNFlutterPlugin.utils.getTraffictStats()
                result(UserDefaults.init(
                    suiteName: OpenVPNFlutterPlugin.utils.groupIdentifier)?
                    .string(forKey: "connectionUpdate"))
            case "stage":
                result(OpenVPNFlutterPlugin.utils.currentStatus())
            case "initialize":
                let args = call.arguments as? [String: Any]
                let providerBundleIdentifier = args?["providerBundleIdentifier"] as? String
                let localizedDescription = args?["localizedDescription"] as? String
                let groupIdentifier = args?["groupIdentifier"] as? String
                if providerBundleIdentifier == nil {
                    result(FlutterError(code: "-2",
                                        message: "providerBundleIdentifier content empty or null",
                                        details: nil))
                    return
                }
                if localizedDescription == nil {
                    result(FlutterError(code: "-3",
                                        message: "localizedDescription content empty or null",
                                        details: nil))
                    return
                }
                if groupIdentifier == nil {
                    result(FlutterError(code: "-4",
                                        message: "groupIdentifier content empty or null",
                                        details: nil))
                    return
                }
                OpenVPNFlutterPlugin.utils.groupIdentifier = groupIdentifier
                OpenVPNFlutterPlugin.utils.localizedDescription = localizedDescription
                OpenVPNFlutterPlugin.utils.providerBundleIdentifier = providerBundleIdentifier
                OpenVPNFlutterPlugin.utils.loadProviderManager { (err: Error?) in
                    if err == nil {
                        result(OpenVPNFlutterPlugin.utils.currentStatus())
                    } else {
                        result(FlutterError(code: "-4",
                                            message: err?.localizedDescription,
                                            details: err?.localizedDescription))
                    }
                }
                self.initialized = true
            case "disconnect":
                OpenVPNFlutterPlugin.utils.stopVPN()
            case "connect":
                if !self.initialized {
                    result(FlutterError(code: "-1",
                                        message: "VPNEngine need to be initialize",
                                        details: nil))
                    return
                }
                let args = call.arguments as? [String: Any]
                let config = args?["config"] as? String
                let username = args?["username"] as? String
                let password = args?["password"] as? String
                if config == nil {
                    result(FlutterError(code: "-2",
                                        message: "Config is empty or nulled",
                                        details: "Config can't be nulled"))
                    return
                }
                OpenVPNFlutterPlugin.utils.configureVPN(
                    config: config, username: username, password: password,
                    completion: { (success: Error?) -> Void in
                        if success == nil {
                            result(nil)
                        } else {
                            result(FlutterError(code: "99",
                                                message: "permission denied",
                                                details: success?.localizedDescription))
                        }
                    })
            case "dispose":
                self.initialized = false
            default:
                break
            }
        })
    }

    class StageHandler: NSObject, FlutterStreamHandler {
        func onListen(withArguments arguments: Any?,
                      eventSink events: @escaping FlutterEventSink) -> FlutterError? {
            OpenVPNFlutterPlugin.utils.stage = events
            return nil
        }

        func onCancel(withArguments arguments: Any?) -> FlutterError? {
            OpenVPNFlutterPlugin.utils.stage = nil
            return nil
        }
    }
}

@available(macOS 10.15, *)
class VPNUtils {
    var providerManager: NETunnelProviderManager!
    var providerBundleIdentifier: String?
    var localizedDescription: String?
    var groupIdentifier: String?
    var stage: FlutterEventSink!
    var vpnStageObserver: NSObjectProtocol?

    func loadProviderManager(completion: @escaping (_ error: Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { (managers, error) in
            if error == nil {
                self.providerManager = managers?.first ?? NETunnelProviderManager()
                completion(nil)
            } else {
                completion(error)
            }
        }
    }

    func onVpnStatusChanged(notification: NEVPNStatus) {
        stage?(onVpnStatusChangedString(notification: notification) ?? "null")
    }

    func onVpnStatusChangedString(notification: NEVPNStatus?) -> String? {
        guard let notification else { return "disconnected" }
        switch notification {
        case NEVPNStatus.connected: return "connected"
        case NEVPNStatus.connecting: return "connecting"
        case NEVPNStatus.disconnected: return "disconnected"
        case NEVPNStatus.disconnecting: return "disconnecting"
        case NEVPNStatus.invalid: return "invalid"
        case NEVPNStatus.reasserting: return "reasserting"
        default: return ""
        }
    }

    func currentStatus() -> String? {
        if self.providerManager != nil {
            return onVpnStatusChangedString(
                notification: self.providerManager.connection.status)
        }
        return "disconnected"
    }

    func configureVPN(config: String?, username: String?, password: String?,
                      completion: @escaping (_ error: Error?) -> Void) {
        let configData = config
        self.providerManager?.loadFromPreferences { error in
            if error != nil {
                completion(error)
                return
            }
            let tunnelProtocol = NETunnelProviderProtocol()
            tunnelProtocol.serverAddress = ""
            tunnelProtocol.providerBundleIdentifier = self.providerBundleIdentifier
            let nullData = "".data(using: .utf8)
            tunnelProtocol.providerConfiguration = [
                "config": configData?.data(using: .utf8) ?? nullData!,
                "groupIdentifier": self.groupIdentifier?.data(using: .utf8) ?? nullData!,
                "username": username?.data(using: .utf8) ?? nullData!,
                "password": password?.data(using: .utf8) ?? nullData!,
            ]
            tunnelProtocol.disconnectOnSleep = false
            self.providerManager.protocolConfiguration = tunnelProtocol
            self.providerManager.localizedDescription = self.localizedDescription
            self.providerManager.isEnabled = true
            self.providerManager.saveToPreferences(completionHandler: { (error) in
                if error != nil {
                    completion(error)
                    return
                }
                self.providerManager.loadFromPreferences(completionHandler: { (error) in
                    if error != nil {
                        completion(error)
                        return
                    }
                    do {
                        if self.vpnStageObserver != nil {
                            NotificationCenter.default.removeObserver(
                                self.vpnStageObserver!,
                                name: NSNotification.Name.NEVPNStatusDidChange,
                                object: nil)
                        }
                        self.vpnStageObserver = NotificationCenter.default.addObserver(
                            forName: NSNotification.Name.NEVPNStatusDidChange,
                            object: nil, queue: nil) { [weak self] notification in
                                guard let nevpnconn = notification.object as? NEVPNConnection
                                else { return }
                                self?.onVpnStatusChanged(notification: nevpnconn.status)
                            }

                        if username != nil && password != nil {
                            let options: [String: NSObject] = [
                                "username": username! as NSString,
                                "password": password! as NSString,
                            ]
                            try self.providerManager.connection.startVPNTunnel(options: options)
                        } else {
                            try self.providerManager.connection.startVPNTunnel()
                        }
                        completion(nil)
                    } catch let error {
                        self.stopVPN()
                        completion(error)
                    }
                })
            })
        }
    }

    func stopVPN() {
        self.providerManager?.connection.stopVPNTunnel()
    }

    func getTraffictStats() {
        if let session = self.providerManager?.connection as? NETunnelProviderSession {
            try? session.sendProviderMessage("OPENVPN_STATS".data(using: .utf8)!) { _ in }
        }
    }
}
