//
//  PacketTunnelProvider.swift
//  VPNExtension
//
//  The packet tunnel provider used with openvpn_flutter 2.x on iOS and macOS.
//  Copy it into your Network Extension target; it needs the OpenVPNAdapter
//  library (CocoaPods or Swift Package Manager, see the README).
//
//  - Reads the configuration openvpn_flutter saves (config, credentials,
//    private key password, session end).
//  - Answers the plugin's status requests with the traffic counters.
//  - Writes the OpenVPN log and the last fatal error to the App Group, so the
//    app can show why a connection failed (OpenVPN.getLogs(), lastError()).
//  - Never crashes the extension: problems end the tunnel with an error.
//

import NetworkExtension
import OpenVPNAdapter
import os.log

extension NEPacketTunnelFlow: OpenVPNAdapterPacketFlow {}

class PacketTunnelProvider: NEPacketTunnelProvider {

    lazy var vpnAdapter: OpenVPNAdapter = {
        let adapter = OpenVPNAdapter()
        adapter.delegate = self
        return adapter
    }()

    let vpnReachability = OpenVPNReachability()

    var startHandler: ((Error?) -> Void)?
    var stopHandler: (() -> Void)?

    private var groupIdentifier: String?
    private var connectedOn: Date?
    private var expireAt: Date?
    private var expiryTimer: DispatchSourceTimer?
    private let log = SharedLog()

    // MARK: - Tunnel lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard
            let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
            let providerConfiguration = tunnelProtocol.providerConfiguration,
            let configData = providerConfiguration["config"] as? Data,
            !configData.isEmpty
        else {
            completionHandler(Self.error("The VPN configuration is missing. Connect from the app again."))
            return
        }

        groupIdentifier = Self.string(providerConfiguration["groupIdentifier"])
        log.open(groupIdentifier: groupIdentifier)
        setLastError(nil)

        let configuration = OpenVPNConfiguration()
        configuration.fileContent = configData
        configuration.tunPersist = false
        if let keyPassword = Self.string(options?["privateKeyPassword"])
            ?? Self.string(providerConfiguration["privateKeyPassword"]),
            !keyPassword.isEmpty {
            configuration.privateKeyPassword = keyPassword
        }

        let evaluation: OpenVPNConfigurationEvaluation
        do {
            evaluation = try vpnAdapter.apply(configuration: configuration)
        } catch {
            fail(error, completionHandler)
            return
        }

        if !evaluation.autologin {
            let username = Self.string(options?["username"]) ?? Self.string(providerConfiguration["username"]) ?? ""
            let password = Self.string(options?["password"]) ?? Self.string(providerConfiguration["password"]) ?? ""
            if username.isEmpty {
                fail(Self.error("This configuration needs a username and password."), completionHandler)
                return
            }
            let credentials = OpenVPNCredentials()
            credentials.username = username
            credentials.password = password
            do {
                try vpnAdapter.provide(credentials: credentials)
            } catch {
                fail(error, completionHandler)
                return
            }
        }

        let expireAt = (options?["expireAt"] as? NSNumber) ?? (providerConfiguration["expireAt"] as? NSNumber)
        scheduleExpiry(millisecondsSince1970: expireAt?.doubleValue)

        vpnReachability.startTracking { [weak self] status in
            guard status == .reachableViaWiFi else { return }
            self?.vpnAdapter.reconnect(afterTimeInterval: 5)
        }

        startHandler = completionHandler
        vpnAdapter.connect(using: packetFlow)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.write("info", "Stopping the tunnel (reason \(reason.rawValue))")
        expiryTimer?.cancel()
        expiryTimer = nil
        stopHandler = completionHandler
        if vpnReachability.isTracking {
            vpnReachability.stopTracking()
        }
        vpnAdapter.disconnect()
    }

    // MARK: - Messages from the app

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard String(data: messageData, encoding: .utf8) == "OPENVPN_STATS" else {
            completionHandler?(nil)
            return
        }
        let statistics = vpnAdapter.interfaceStatistics
        var status: [String: Any] = [
            "byte_in": statistics.bytesIn,
            "byte_out": statistics.bytesOut,
            "packets_in": statistics.packetsIn,
            "packets_out": statistics.packetsOut,
        ]
        if let connectedOn = connectedOn {
            status["connected_on"] = Int64(connectedOn.timeIntervalSince1970 * 1000)
        }
        completionHandler?(try? JSONSerialization.data(withJSONObject: status))
    }

    // MARK: - Helpers

    private func scheduleExpiry(millisecondsSince1970: Double?) {
        expiryTimer?.cancel()
        expiryTimer = nil
        expireAt = nil
        guard let milliseconds = millisecondsSince1970, milliseconds > 0 else { return }
        let end = Date(timeIntervalSince1970: milliseconds / 1000)
        expireAt = end
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Wall clock: keeps counting while the device sleeps.
        timer.schedule(wallDeadline: .now() + max(0, end.timeIntervalSinceNow))
        timer.setEventHandler { [weak self] in
            self?.endExpiredSession()
        }
        timer.resume()
        expiryTimer = timer
    }

    private func endExpiredSession() {
        guard let end = expireAt, end.timeIntervalSinceNow <= 0 else { return }
        expireAt = nil
        expiryTimer?.cancel()
        expiryTimer = nil
        log.write("info", "Session expired, disconnecting")
        cancelTunnelWithError(nil)
    }

    override func wake() {
        super.wake()
        // The timer may not have fired while the device slept.
        endExpiredSession()
    }

    private func fail(_ error: Error, _ completionHandler: (Error?) -> Void) {
        log.write("error", error.localizedDescription)
        setLastError(error.localizedDescription)
        completionHandler(error)
    }

    private func setLastError(_ message: String?) {
        guard let groupIdentifier = groupIdentifier else { return }
        let defaults = UserDefaults(suiteName: groupIdentifier)
        if let message = message {
            defaults?.set(message, forKey: "openvpn_flutter.lastError")
        } else {
            defaults?.removeObject(forKey: "openvpn_flutter.lastError")
        }
    }

    private static func string(_ value: Any?) -> String? {
        if let data = value as? Data { return String(data: data, encoding: .utf8) }
        return value as? String
    }

    private static func name(of event: OpenVPNAdapterEvent) -> String {
        switch event {
        case .disconnected: return "DISCONNECTED"
        case .connected: return "CONNECTED"
        case .reconnecting: return "RECONNECTING"
        case .authPending: return "AUTH_PENDING"
        case .resolve: return "RESOLVE"
        case .wait: return "WAIT"
        case .waitProxy: return "WAIT_PROXY"
        case .connecting: return "CONNECTING"
        case .getConfig: return "GET_CONFIG"
        case .assignIP: return "ASSIGN_IP"
        case .addRoutes: return "ADD_ROUTES"
        case .pause: return "PAUSE"
        case .resume: return "RESUME"
        default: return "\(event.rawValue)"
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "openvpn_flutter", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

extension PacketTunnelProvider: OpenVPNAdapterDelegate {

    func openVPNAdapter(
        _ openVPNAdapter: OpenVPNAdapter,
        configureTunnelWithNetworkSettings networkSettings: NEPacketTunnelNetworkSettings?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Send all DNS queries through the tunnel.
        networkSettings?.dnsSettings?.matchDomains = [""]
        setTunnelNetworkSettings(networkSettings, completionHandler: completionHandler)
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleEvent event: OpenVPNAdapterEvent, message: String?) {
        log.write("info", "Event \(Self.name(of: event))\(message.map { ": \($0)" } ?? "")")
        switch event {
        case .connected:
            // Date(), not Date.now: Date.now needs iOS 15 in app extensions.
            connectedOn = Date()
            if reasserting {
                reasserting = false
            }
            guard let startHandler = startHandler else { return }
            startHandler(nil)
            self.startHandler = nil
        case .disconnected:
            connectedOn = nil
            if vpnReachability.isTracking {
                vpnReachability.stopTracking()
            }
            if let stopHandler = stopHandler {
                stopHandler()
                self.stopHandler = nil
            } else if let startHandler = startHandler {
                let error = Self.error("The connection was closed before it was established.")
                setLastError(error.localizedDescription)
                startHandler(error)
                self.startHandler = nil
            } else {
                // Closed by the server: end the tunnel so the system shows it.
                cancelTunnelWithError(nil)
            }
        case .reconnecting:
            reasserting = true
        default:
            break
        }
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleError error: Error) {
        log.write("error", error.localizedDescription)
        guard let fatal = (error as NSError).userInfo[OpenVPNAdapterErrorFatalKey] as? Bool, fatal else {
            return
        }
        setLastError(error.localizedDescription)
        if vpnReachability.isTracking {
            vpnReachability.stopTracking()
        }
        if let startHandler = startHandler {
            startHandler(error)
            self.startHandler = nil
        } else {
            cancelTunnelWithError(error)
        }
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleLogMessage logMessage: String) {
        log.write("info", logMessage)
    }
}

/// Appends log lines to `<App Group>/openvpn_flutter/vpn.log`, where
/// openvpn_flutter reads them (`<milliseconds>\t<level>\t<message>`).
/// Each connection starts a new file; it never grows past `maxSize`.
private final class SharedLog {
    private let maxSize: UInt64 = 512 * 1024
    private let queue = DispatchQueue(label: "openvpn_flutter.log")
    private var url: URL?

    func open(groupIdentifier: String?) {
        queue.sync {
            guard let groupIdentifier = groupIdentifier,
                  let container = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: groupIdentifier)
            else {
                url = nil
                return
            }
            let directory = container.appendingPathComponent("openvpn_flutter", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("vpn.log")
            // A new file per connection, starting with a header line that tells
            // the app a new log began.
            let time = Int64(Date().timeIntervalSince1970 * 1000)
            FileManager.default.createFile(
                atPath: file.path, contents: Data("\(time)\tinfo\tOpenVPN session started\n".utf8))
            url = file
        }
    }

    func write(_ level: String, _ message: String) {
        #if DEBUG
        os_log("OpenVPN: %{public}@", message)
        #endif
        queue.async {
            guard let url = self.url, let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { handle.closeFile() }
            if handle.seekToEndOfFile() > self.maxSize {
                handle.truncateFile(atOffset: 0)
            }
            let time = Int64(Date().timeIntervalSince1970 * 1000)
            let line = "\(time)\t\(level)\t\(message.replacingOccurrences(of: "\n", with: " "))\n"
            handle.write(Data(line.utf8))
        }
    }
}
