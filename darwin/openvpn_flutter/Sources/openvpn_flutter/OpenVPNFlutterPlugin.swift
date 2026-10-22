//  OpenVPNFlutterPlugin.swift — iOS and macOS
//
//  Both platforms talk to the app's packet tunnel provider through the same
//  NETunnelProviderManager API; only the Flutter embedder differs (FlutterMacOS,
//  and `registrar.messenger` being a property on macOS). The OpenVPN engine
//  itself runs in the provider, see example/ios/VPNExtension/PacketTunnelProvider.swift.

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif
import Foundation
import NetworkExtension

public class OpenVPNFlutterPlugin: NSObject, FlutterPlugin {
    private static let methodChannelName = "id.laskarmedia.openvpn_flutter/vpncontrol"
    private static let stageChannelName = "id.laskarmedia.openvpn_flutter/vpnstage"
    private static let logChannelName = "id.laskarmedia.openvpn_flutter/vpnlog"

    private let vpn: VPNController
    private let stageHandler: StageStreamHandler
    private let logHandler: LogStreamHandler

    override init() {
        let vpn = VPNController()
        self.vpn = vpn
        stageHandler = StageStreamHandler(vpn: vpn)
        logHandler = LogStreamHandler(vpn: vpn)
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        #if os(iOS)
        let messenger = registrar.messenger()
        #else
        let messenger = registrar.messenger
        #endif
        let instance = OpenVPNFlutterPlugin()
        let methodChannel = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        FlutterEventChannel(name: stageChannelName, binaryMessenger: messenger)
            .setStreamHandler(instance.stageHandler)
        FlutterEventChannel(name: logChannelName, binaryMessenger: messenger)
            .setStreamHandler(instance.logHandler)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "initialize":
            vpn.initialize(
                providerBundleIdentifier: arguments["providerBundleIdentifier"] as? String,
                groupIdentifier: arguments["groupIdentifier"] as? String,
                localizedDescription: arguments["localizedDescription"] as? String,
                completion: result)
        case "connect":
            guard let config = arguments["config"] as? String,
                  !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                result(FlutterError(code: "invalid_config",
                                    message: "The OpenVPN configuration is empty",
                                    details: nil))
                return
            }
            vpn.connect(
                config: config,
                name: arguments["name"] as? String,
                username: arguments["username"] as? String,
                password: arguments["password"] as? String,
                privateKeyPassword: arguments["private_key_password"] as? String,
                expireAt: (arguments["expire_at"] as? NSNumber)?.doubleValue,
                completion: result)
        case "disconnect":
            vpn.disconnect()
            result(nil)
        case "stage":
            result(vpn.stage)
        case "status":
            vpn.status(completion: result)
        case "logs":
            result(vpn.logs())
        case "last_error":
            vpn.lastError(completion: result)
        case "request_permission":
            // The system asks when the VPN configuration is first saved.
            result(true)
        case "open_vpn_settings":
            result(false)
        case "dispose":
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

// MARK: - Event channels

private final class StageStreamHandler: NSObject, FlutterStreamHandler {
    private let vpn: VPNController

    init(vpn: VPNController) {
        self.vpn = vpn
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        vpn.onStage = { stage in events(stage) }
        events(vpn.stage)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        vpn.onStage = nil
        return nil
    }
}

private final class LogStreamHandler: NSObject, FlutterStreamHandler {
    private let vpn: VPNController

    init(vpn: VPNController) {
        self.vpn = vpn
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        vpn.startFollowingLogs { log in events(log) }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        vpn.stopFollowingLogs()
        return nil
    }
}

// MARK: - VPN controller

/// Owns the app's NETunnelProviderManager. Everything runs on the main queue.
final class VPNController {
    /// Keys shared with the packet tunnel provider through the App Group.
    enum Shared {
        /// Last fatal error of the provider (written by the provider).
        static let lastErrorKey = "openvpn_flutter.lastError"
        /// Traffic counters written by 1.x providers.
        static let legacyStatusKey = "connectionUpdate"
        /// The provider's log file, relative to the App Group container.
        static let logPath = "openvpn_flutter/vpn.log"
    }

    var onStage: ((String) -> Void)?
    private(set) var stage = "disconnected"

    private var manager: NETunnelProviderManager?
    private var providerBundleIdentifier: String?
    private var groupIdentifier: String?
    private var localizedDescription: String?
    private var statusObserver: NSObjectProtocol?

    private var connectionRequested = false
    private var stopRequested = false
    private var reachedConnected = false
    private var lastErrorMessage: String?
    private var expiryTimer: Timer?
    /// Incremented by connect() and disconnect(): work that finishes later
    /// (saving the configuration, fetching the last error) checks it is current.
    private var generation = 0
    /// The provider's last answer to OPENVPN_STATS, used when it answers late.
    private var lastStatusReply: [String: Any]?

    private var logTimer: Timer?
    private var logOffset: UInt64 = 0
    private var logHeader: Data?

    deinit {
        if let statusObserver = statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        expiryTimer?.invalidate()
        logTimer?.invalidate()
    }

    // MARK: Initialize

    func initialize(providerBundleIdentifier: String?, groupIdentifier: String?,
                    localizedDescription: String?, completion: @escaping FlutterResult) {
        guard let providerBundleIdentifier = providerBundleIdentifier, !providerBundleIdentifier.isEmpty,
              let groupIdentifier = groupIdentifier, !groupIdentifier.isEmpty,
              let localizedDescription = localizedDescription, !localizedDescription.isEmpty
        else {
            completion(FlutterError(
                code: "invalid_argument",
                message: "providerBundleIdentifier, groupIdentifier and localizedDescription are required",
                details: nil))
            return
        }
        self.providerBundleIdentifier = providerBundleIdentifier
        self.groupIdentifier = groupIdentifier
        self.localizedDescription = localizedDescription
        observeStatus()
        loadManager { error in
            if let error = error {
                completion(Self.flutterError("load_failed", error))
                return
            }
            completion(self.stage)
        }
    }

    private func loadManager(completion: @escaping (Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(error)
                    return
                }
                let own = managers?.first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                        == self.providerBundleIdentifier
                }
                self.manager = own ?? managers?.first ?? NETunnelProviderManager()
                self.statusChanged()
                completion(nil)
            }
        }
    }

    /// Follows the connection from initialize on, so a VPN that is already
    /// running (the app was relaunched) reports its stage.
    private func observeStatus() {
        guard statusObserver == nil else { return }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.statusChanged()
        }
    }

    // MARK: Connect / disconnect

    func connect(config: String, name: String?, username: String?, password: String?,
                 privateKeyPassword: String?, expireAt: Double?, completion: @escaping FlutterResult) {
        guard let manager = manager else {
            completion(FlutterError(code: "not_initialized",
                                    message: "Call initialize() before connect()",
                                    details: nil))
            return
        }
        generation += 1
        let attempt = generation
        let start = {
            self.save(manager: manager, attempt: attempt, config: config, name: name, username: username,
                      password: password, privateKeyPassword: privateKeyPassword, expireAt: expireAt,
                      completion: completion)
        }
        if Self.isActive(manager.connection.status) {
            // Switching servers: the configuration cannot change under a running tunnel.
            stopRequested = true
            manager.connection.stopVPNTunnel()
            waitUntilDisconnected(timeout: 10, then: start)
        } else {
            start()
        }
    }

    private func save(manager: NETunnelProviderManager, attempt: Int, config: String, name: String?,
                      username: String?, password: String?, privateKeyPassword: String?, expireAt: Double?,
                      completion: @escaping FlutterResult) {
        let tunnel = NETunnelProviderProtocol()
        tunnel.providerBundleIdentifier = providerBundleIdentifier
        tunnel.serverAddress = Self.remoteHost(in: config) ?? localizedDescription ?? ""
        // Data values: 1.x providers read these keys as Data.
        var providerConfiguration: [String: Any] = [
            "config": Data(config.utf8),
            "groupIdentifier": Data((groupIdentifier ?? "").utf8),
            "username": Data((username ?? "").utf8),
            "password": Data((password ?? "").utf8),
        ]
        if let privateKeyPassword = privateKeyPassword {
            providerConfiguration["privateKeyPassword"] = Data(privateKeyPassword.utf8)
        }
        if let name = name {
            providerConfiguration["name"] = name
        }
        if let expireAt = expireAt {
            providerConfiguration["expireAt"] = NSNumber(value: expireAt)
        }
        tunnel.providerConfiguration = providerConfiguration
        tunnel.disconnectOnSleep = false

        manager.protocolConfiguration = tunnel
        manager.localizedDescription = localizedDescription
        manager.isEnabled = true
        manager.saveToPreferences { error in
            DispatchQueue.main.async {
                if let error = error {
                    if Self.isPermissionDenied(error) {
                        self.emit("denied")
                        self.emit("disconnected")
                        completion(false)
                    } else {
                        completion(Self.flutterError("save_failed", error))
                    }
                    return
                }
                // A configuration that was just saved has to be loaded again
                // before it can start (NEVPNErrorDomain code 1 otherwise).
                manager.loadFromPreferences { error in
                    DispatchQueue.main.async {
                        if let error = error {
                            completion(Self.flutterError("load_failed", error))
                            return
                        }
                        guard attempt == self.generation else {
                            // disconnect() was called while the configuration was saved.
                            completion(false)
                            return
                        }
                        self.start(manager: manager, username: username, password: password,
                                   privateKeyPassword: privateKeyPassword, expireAt: expireAt,
                                   completion: completion)
                    }
                }
            }
        }
    }

    private func start(manager: NETunnelProviderManager, username: String?, password: String?,
                       privateKeyPassword: String?, expireAt: Double?, completion: @escaping FlutterResult) {
        var options: [String: NSObject] = [:]
        if let username = username { options["username"] = username as NSString }
        if let password = password { options["password"] = password as NSString }
        if let privateKeyPassword = privateKeyPassword {
            options["privateKeyPassword"] = privateKeyPassword as NSString
        }
        if let expireAt = expireAt { options["expireAt"] = NSNumber(value: expireAt) }

        connectionRequested = true
        stopRequested = false
        reachedConnected = false
        lastErrorMessage = nil
        lastStatusReply = nil
        if let group = groupIdentifier {
            UserDefaults(suiteName: group)?.removeObject(forKey: Shared.lastErrorKey)
        }
        do {
            try manager.connection.startVPNTunnel(options: options.isEmpty ? nil : options)
        } catch {
            connectionRequested = false
            completion(Self.flutterError("start_failed", error))
            return
        }
        scheduleExpiry(expireAt)
        completion(true)
    }

    func disconnect() {
        generation += 1
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let manager = manager, Self.isActive(manager.connection.status) else {
            connectionRequested = false
            return
        }
        stopRequested = true
        manager.connection.stopVPNTunnel()
    }

    private func waitUntilDisconnected(timeout: TimeInterval, then action: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if let manager = manager, Self.isActive(manager.connection.status), Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: check)
            } else {
                action()
            }
        }
        check()
    }

    /// The provider enforces the session end even while the app is not running
    /// (see PacketTunnelProvider.swift); this covers providers that do not.
    private func scheduleExpiry(_ expireAt: Double?) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let expireAt = expireAt else { return }
        let delay = max(0, expireAt / 1000 - Date().timeIntervalSince1970)
        expiryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.disconnect()
        }
    }

    // MARK: Stage

    private func statusChanged() {
        guard let status = manager?.connection.status else { return }
        let newStage = Self.stageName(status)
        if newStage == stage { return }
        switch newStage {
        case "connected":
            reachedConnected = true
            emit(newStage)
        case "disconnected":
            finishConnection()
        default:
            emit(newStage)
        }
    }

    /// Reports "error" before "disconnected" when the tunnel ended without
    /// anyone stopping it.
    private func finishConnection() {
        let requested = connectionRequested
        let stopped = stopRequested
        let connected = reachedConnected
        connectionRequested = false
        stopRequested = false
        reachedConnected = false
        expiryTimer?.invalidate()
        expiryTimer = nil

        guard requested, !stopped else {
            emit("disconnected")
            return
        }
        if #available(iOS 16.0, macOS 13.0, *), let connection = manager?.connection {
            let current = generation
            connection.fetchLastDisconnectError { error in
                DispatchQueue.main.async {
                    // A new connection started meanwhile: its stages win.
                    guard current == self.generation else { return }
                    if let error = error {
                        self.lastErrorMessage = self.providerError() ?? error.localizedDescription
                        self.emit("error")
                    }
                    self.emit("disconnected")
                }
            }
        } else {
            if !connected {
                lastErrorMessage = providerError()
                emit("error")
            }
            emit("disconnected")
        }
    }

    private func emit(_ newStage: String) {
        guard newStage != stage else { return }
        stage = newStage
        onStage?(newStage)
    }

    // MARK: Status

    func status(completion: @escaping FlutterResult) {
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected
        else {
            completion(nil)
            return
        }
        var answered = false
        let answer: (Any?) -> Void = { value in
            DispatchQueue.main.async {
                guard !answered else { return }
                answered = true
                completion(value)
            }
        }
        do {
            try session.sendProviderMessage(Data("OPENVPN_STATS".utf8)) { response in
                if let response = response,
                   let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any] {
                    DispatchQueue.main.async { self.lastStatusReply = json }
                    answer(json)
                } else {
                    answer(self.legacyStatus())
                }
            }
        } catch {
            answer(lastStatusReply ?? legacyStatus())
            return
        }
        // 1.x providers write the counters to the App Group and never answer;
        // a busy provider gets the previous answer reused instead of a blank status.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            answer(self.lastStatusReply ?? self.legacyStatus())
        }
    }

    private func legacyStatus() -> String? {
        guard let group = groupIdentifier else { return nil }
        return UserDefaults(suiteName: group)?.string(forKey: Shared.legacyStatusKey)
    }

    // MARK: Errors

    func lastError(completion: @escaping FlutterResult) {
        if let message = providerError() ?? lastErrorMessage {
            completion(message)
            return
        }
        if #available(iOS 16.0, macOS 13.0, *), let connection = manager?.connection {
            connection.fetchLastDisconnectError { error in
                DispatchQueue.main.async { completion(error?.localizedDescription) }
            }
        } else {
            completion(nil)
        }
    }

    private func providerError() -> String? {
        guard let group = groupIdentifier else { return nil }
        return UserDefaults(suiteName: group)?.string(forKey: Shared.lastErrorKey)
    }

    // MARK: Logs

    private var logFile: URL? {
        guard let group = groupIdentifier else { return nil }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent(Shared.logPath)
    }

    func logs() -> [[String: Any]] {
        guard let file = logFile, let text = try? String(contentsOf: file, encoding: .utf8) else {
            return []
        }
        return Self.parseLogs(text)
    }

    func startFollowingLogs(_ onLog: @escaping ([String: Any]) -> Void) {
        stopFollowingLogs()
        logOffset = currentLogSize()
        logHeader = currentLogHeader()
        logTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            for log in self.readNewLogs() { onLog(log) }
        }
    }

    func stopFollowingLogs() {
        logTimer?.invalidate()
        logTimer = nil
    }

    private func currentLogSize() -> UInt64 {
        guard let file = logFile, let handle = try? FileHandle(forReadingFrom: file) else { return 0 }
        defer { handle.closeFile() }
        return handle.seekToEndOfFile()
    }

    /// The first line of the log file. The provider starts every connection
    /// with a new file and a header line holding its start time.
    private func currentLogHeader() -> Data? {
        guard let file = logFile, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { handle.closeFile() }
        let start = handle.readData(ofLength: 128)
        guard let newline = start.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        return start.prefix(upTo: newline)
    }

    private func readNewLogs() -> [[String: Any]] {
        let header = currentLogHeader()
        if header != logHeader {
            // A new connection started a new log.
            logHeader = header
            logOffset = 0
        }
        guard let file = logFile, let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { handle.closeFile() }
        let size = handle.seekToEndOfFile()
        if size < logOffset {
            logOffset = 0
        }
        guard size > logOffset else { return [] }
        handle.seek(toFileOffset: logOffset)
        let data = handle.readDataToEndOfFile()
        // Only complete lines; the rest is read next time.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        let complete = data.prefix(through: lastNewline)
        logOffset += UInt64(complete.count)
        return Self.parseLogs(String(decoding: complete, as: UTF8.self))
    }

    /// Lines are `<milliseconds>\t<level>\t<message>`.
    static func parseLogs(_ text: String) -> [[String: Any]] {
        text.split(separator: "\n").map { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count == 3, let time = Int64(parts[0]) {
                return ["time": time, "level": String(parts[1]), "message": String(parts[2])]
            }
            return ["time": Int64(Date().timeIntervalSince1970 * 1000), "level": "info", "message": String(line)]
        }
    }

    // MARK: Helpers

    static func stageName(_ status: NEVPNStatus) -> String {
        switch status {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnecting: return "disconnecting"
        case .reasserting: return "reconnect"
        case .disconnected, .invalid: return "disconnected"
        @unknown default: return "disconnected"
        }
    }

    static func isActive(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting, .disconnecting: return true
        default: return false
        }
    }

    /// The host of the first `remote`, shown as "Server" in the system settings.
    static func remoteHost(in config: String) -> String? {
        for line in config.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "remote" {
                return String(parts[1])
            }
        }
        return nil
    }

    /// The user tapped "Don't Allow" on the "Add VPN Configurations" prompt
    /// ("permission denied", whatever the language of the message).
    static func isPermissionDenied(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NEVPNErrorDomain
            && error.code == NEVPNError.Code.configurationReadWriteFailed.rawValue
    }

    static func flutterError(_ code: String, _ error: Error) -> FlutterError {
        let nsError = error as NSError
        var message = nsError.localizedDescription
        if nsError.domain == "NEConfigurationErrorDomain" && nsError.code == 10 {
            message += ". The app needs the Network Extensions capability (Packet Tunnel) and an App Group,"
                + " on a real device (the simulator cannot run VPN extensions)."
        }
        return FlutterError(code: code, message: message, details: "\(nsError.domain) \(nsError.code)")
    }
}
