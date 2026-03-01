import Foundation
import AppKit
import Network

@Observable
final class SSHProcessManager {
    private var processes: [UUID: Process] = [:]
    private var pipes: [UUID: Pipe] = [:]
    private var connectTimers: [UUID: DispatchWorkItem] = [:]
    var status: TunnelStatus
    var logs: [UUID: String] = [:]

    // Auto-reconnect state
    private var manualDisconnects = Set<UUID>()
    private var pendingReconnect = Set<UUID>()
    private var reconnectConfigs: [UUID: SSHTunnelConfig] = [:]
    private var reconnectTimers: [UUID: DispatchWorkItem] = [:]
    private var retryCounts: [UUID: Int] = [:]
    private let networkMonitor = NWPathMonitor()
    private var isNetworkAvailable = true
    private let systemProxyService = SystemProxyService()

    private struct ActiveSocksProxySession {
        var serviceName: String
        var host: String
        var port: UInt16
        var previousState: SocksProxyState
        var owners: Set<UUID>
    }
    private var activeSocksProxySession: ActiveSocksProxySession?

    init(status: TunnelStatus) {
        self.status = status
        networkMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let wasAvailable = self.isNetworkAvailable
                self.isNetworkAvailable = path.status == .satisfied
                if !wasAvailable && path.status == .satisfied {
                    self.reconnectPending()
                }
            }
        }
        networkMonitor.start(queue: DispatchQueue.global(qos: .utility))
        cleanupStaleAskPassScripts()
    }

    /// Returns local ports that are already in use
    func checkPortConflicts(_ config: SSHTunnelConfig) -> [UInt16] {
        config.tunnels.compactMap { entry in
            guard entry.type != .remote else { return nil }
            let port = entry.localPort
            guard port > 0 else { return nil }
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else { return nil }
            defer { close(sock) }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")

            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            return result != 0 ? port : nil
        }
    }

    func connect(_ config: SSHTunnelConfig) {
        let id = config.id
        guard !status.state(for: id).isActive else { return }

        reconnectConfigs[id] = config
        pendingReconnect.remove(id)
        reconnectTimers[id]?.cancel()
        reconnectTimers.removeValue(forKey: id)
        manualDisconnects.remove(id)

        status.states[id] = .connecting

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = buildArguments(for: config)

        var usesAskPass = false

        // If using password auth, use SSH_ASKPASS to provide it
        if config.authMethod == .password,
           let password = KeychainService.getPassword(for: config.id) {
            let askpassScript = createAskPassScript(password: password, configId: config.id)
            var env = ProcessInfo.processInfo.environment
            env["SSH_ASKPASS"] = askpassScript
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = ":0"
            process.environment = env
            usesAskPass = true
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipes[id] = pipe

        // Collect log output from ssh stderr/stdout
        logs[id] = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.logs[id, default: ""].append(output)
            }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cleanupAskPassScript(configId: id)
                self.connectTimers[id]?.cancel()
                self.connectTimers.removeValue(forKey: id)
                self.processes.removeValue(forKey: id)
                self.pipes[id]?.fileHandleForReading.readabilityHandler = nil
                self.pipes.removeValue(forKey: id)

                self.disableSystemProxyIfNeeded(configId: id)

                let wasConnecting = self.status.state(for: id) == .connecting

                if proc.terminationStatus == 0 {
                    self.status.states[id] = .disconnected
                } else {
                    self.status.states[id] = .disconnected

                    if wasConnecting {
                        self.status.states[id] = .error(String(localized: "Connection failed (exit \(proc.terminationStatus))"))
                    }

                    // Auto-reconnect on unexpected disconnect / connect failure
                    if !self.manualDisconnects.contains(id),
                       let config = self.reconnectConfigs[id],
                       config.autoReconnect {
                        self.pendingReconnect.insert(id)
                        if self.isNetworkAvailable {
                            self.scheduleReconnect(id)
                        }
                    }
                }
                self.manualDisconnects.remove(id)
            }
        }

        do {
            try process.run()
            processes[id] = process

            // Timer-based connection detection:
            // If process is still alive after 3 seconds, consider it connected
            let timer = DispatchWorkItem { [weak self] in
                guard let self, let proc = self.processes[id], proc.isRunning else { return }
                self.status.states[id] = .connected
                self.retryCounts[id] = 0
                self.enableSystemProxyIfNeeded(config)
            }
            connectTimers[id] = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timer)
        } catch {
            if usesAskPass {
                cleanupAskPassScript(configId: id)
            }
            status.states[id] = .error(error.localizedDescription)
        }
    }

    func disconnect(_ configId: UUID) {
        manualDisconnects.insert(configId)
        pendingReconnect.remove(configId)
        reconnectTimers[configId]?.cancel()
        reconnectTimers.removeValue(forKey: configId)
        retryCounts.removeValue(forKey: configId)

        connectTimers[configId]?.cancel()
        connectTimers.removeValue(forKey: configId)

        guard let process = processes[configId], process.isRunning else {
            disableSystemProxyIfNeeded(configId: configId)
            status.states[configId] = .disconnected
            return
        }
        process.terminate()
    }

    func toggle(_ config: SSHTunnelConfig) {
        if status.state(for: config.id).isActive {
            disconnect(config.id)
        } else {
            connect(config)
        }
    }

    func disconnectAll() {
        let ids = Set(processes.keys).union(pendingReconnect)
        for id in ids {
            disconnect(id)
        }
    }

    func disconnectOnQuit(configs: [SSHTunnelConfig]) {
        for config in configs where config.disconnectOnQuit {
            disconnect(config.id)
        }
    }

    private func buildArguments(for config: SSHTunnelConfig) -> [String] {
        var args: [String] = [
            "-N",
            "-v",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-p", "\(config.port)",
        ]

        switch config.authMethod {
        case .identityFile:
            if !config.identityFile.isEmpty {
                args += ["-i", config.identityFile]
            }
            args += ["-o", "PasswordAuthentication=no"]
        case .password:
            args += ["-o", "PreferredAuthentications=password,keyboard-interactive"]
        }

        for entry in config.tunnels {
            args += [entry.type.flag, entry.sshArgument]
        }

        if !config.additionalArgs.isEmpty {
            let extra = config.additionalArgs
                .split(separator: " ")
                .map(String.init)
            args += extra
        }

        args.append("\(config.username)@\(config.host)")
        return args
    }

    // MARK: - Auto-reconnect

    private func scheduleReconnect(_ id: UUID) {
        reconnectTimers[id]?.cancel()
        let count = retryCounts[id, default: 0]
        let delays = [3.0, 5.0, 10.0, 30.0, 60.0]
        let delay = delays[min(count, delays.count - 1)]
        let timer = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingReconnect.contains(id),
                  let config = self.reconnectConfigs[id] else { return }
            self.retryCounts[id] = count + 1
            self.connect(config)
        }
        reconnectTimers[id] = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timer)
    }

    private func reconnectPending() {
        for id in pendingReconnect {
            scheduleReconnect(id)
        }
    }

    func cancelReconnect(_ configId: UUID) {
        pendingReconnect.remove(configId)
        reconnectTimers[configId]?.cancel()
        reconnectTimers.removeValue(forKey: configId)
        retryCounts.removeValue(forKey: configId)
        reconnectConfigs.removeValue(forKey: configId)
    }

    // MARK: - System SOCKS proxy

    private func enableSystemProxyIfNeeded(_ config: SSHTunnelConfig) {
        guard config.autoEnableSystemSocksProxy else { return }
        guard let dynamicTunnel = config.tunnels.first(where: { $0.type == .dynamic && $0.localPort > 0 }) else { return }

        do {
            let serviceName = try systemProxyService.activeServiceName()
            let targetHost = "127.0.0.1"
            let targetPort = dynamicTunnel.localPort

            if var session = activeSocksProxySession {
                guard session.serviceName == serviceName else {
                    logs[config.id, default: ""].append("\n[System] Skipped SOCKS enable: active proxy session uses a different network service (\(session.serviceName)).\n")
                    return
                }

                guard session.host == targetHost, session.port == targetPort else {
                    logs[config.id, default: ""].append("\n[System] Skipped SOCKS enable: another active tunnel already owns SOCKS at \(session.host):\(session.port).\n")
                    return
                }

                session.owners.insert(config.id)
                activeSocksProxySession = session
                logs[config.id, default: ""].append("\n[System] Reused SOCKS proxy owner set on \(serviceName): \(targetHost):\(targetPort)\n")
                return
            }

            let previous = try systemProxyService.currentSocksProxyState(for: serviceName)
            try systemProxyService.enableSocksProxy(serviceName: serviceName, host: targetHost, port: targetPort)

            activeSocksProxySession = ActiveSocksProxySession(
                serviceName: serviceName,
                host: targetHost,
                port: targetPort,
                previousState: previous,
                owners: [config.id]
            )
            logs[config.id, default: ""].append("\n[System] Enabled SOCKS proxy on \(serviceName): \(targetHost):\(targetPort)\n")
        } catch {
            logs[config.id, default: ""].append("\n[System] Failed to enable SOCKS proxy: \(error.localizedDescription)\n")
        }
    }

    private func disableSystemProxyIfNeeded(configId: UUID) {
        guard var session = activeSocksProxySession else { return }
        guard session.owners.contains(configId) else { return }

        session.owners.remove(configId)
        if !session.owners.isEmpty {
            activeSocksProxySession = session
            logs[configId, default: ""].append("\n[System] SOCKS proxy still in use by \(session.owners.count) tunnel(s), keeping current state.\n")
            return
        }

        do {
            try systemProxyService.restoreSocksProxyState(session.previousState)
            logs[configId, default: ""].append("\n[System] Restored SOCKS proxy on \(session.previousState.serviceName) (enabled=\(session.previousState.enabled ? "Yes" : "No"))\n")
        } catch {
            logs[configId, default: ""].append("\n[System] Failed to restore SOCKS proxy: \(error.localizedDescription)\n")
        }

        activeSocksProxySession = nil
    }

    // MARK: - SSH_ASKPASS helper

    private func cleanupStaleAskPassScripts() {
        let tmpDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil) else { return }

        for file in files where file.lastPathComponent.hasPrefix("sshtunnel-askpass-") && file.pathExtension == "sh" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func createAskPassScript(password: String, configId: UUID) -> String {
        let tmpDir = FileManager.default.temporaryDirectory
        let scriptPath = tmpDir.appendingPathComponent("sshtunnel-askpass-\(configId.uuidString).sh").path
        let escaped = password.replacingOccurrences(of: "'", with: "'\\''")
        let content = "#!/bin/sh\necho '\(escaped)'\n"
        FileManager.default.createFile(atPath: scriptPath, contents: content.data(using: .utf8), attributes: [.posixPermissions: 0o700])
        return scriptPath
    }

    private func cleanupAskPassScript(configId: UUID) {
        let tmpDir = FileManager.default.temporaryDirectory
        let scriptPath = tmpDir.appendingPathComponent("sshtunnel-askpass-\(configId.uuidString).sh").path
        try? FileManager.default.removeItem(atPath: scriptPath)
    }
}
