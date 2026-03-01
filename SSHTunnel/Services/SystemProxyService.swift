import Foundation

struct SocksProxyState {
    let serviceName: String
    let enabled: Bool
    let host: String
    let port: UInt16
}

enum SystemProxyError: LocalizedError {
    case defaultInterfaceNotFound
    case networkServiceNotFound(interface: String)
    case invalidProxyPort(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .defaultInterfaceNotFound:
            return String(localized: "Could not determine default network interface.")
        case .networkServiceNotFound(let interface):
            return String(localized: "Could not find a network service for interface \(interface).")
        case .invalidProxyPort(let value):
            return String(localized: "Invalid SOCKS proxy port: \(value)")
        case .commandFailed(let message):
            return message
        }
    }
}

final class SystemProxyService {
    private let networksetupPath = "/usr/sbin/networksetup"
    private let routePath = "/sbin/route"

    func activeServiceName() throws -> String {
        let interface = try defaultInterface()
        let service = try networkServiceForDevice(interface)
        return service
    }

    func currentSocksProxyState(for serviceName: String) throws -> SocksProxyState {
        let output = try run(networksetupPath, ["-getsocksfirewallproxy", serviceName])

        var enabled = false
        var host = ""
        var port: UInt16 = 0

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Enabled:") {
                enabled = line.replacingOccurrences(of: "Enabled:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .caseInsensitiveCompare("Yes") == .orderedSame
            } else if line.hasPrefix("Server:") {
                host = line.replacingOccurrences(of: "Server:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Port:") {
                let value = line.replacingOccurrences(of: "Port:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                guard let parsed = UInt16(value) else {
                    throw SystemProxyError.invalidProxyPort(value)
                }
                port = parsed
            }
        }

        return SocksProxyState(serviceName: serviceName, enabled: enabled, host: host, port: port)
    }

    func enableSocksProxy(serviceName: String, host: String = "127.0.0.1", port: UInt16) throws {
        try run(networksetupPath, ["-setsocksfirewallproxy", serviceName, host, "\(port)"])
        try run(networksetupPath, ["-setsocksfirewallproxystate", serviceName, "on"])
    }

    func restoreSocksProxyState(_ state: SocksProxyState) throws {
        let host = state.host.isEmpty ? "127.0.0.1" : state.host
        try run(networksetupPath, ["-setsocksfirewallproxy", state.serviceName, host, "\(state.port)"])
        try run(networksetupPath, ["-setsocksfirewallproxystate", state.serviceName, state.enabled ? "on" : "off"])
    }

    private func defaultInterface() throws -> String {
        let output = try run(routePath, ["-n", "get", "default"])
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("interface:") else { continue }
            return text.replacingOccurrences(of: "interface:", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        throw SystemProxyError.defaultInterfaceNotFound
    }

    private func networkServiceForDevice(_ interface: String) throws -> String {
        // More robust than -listallhardwareports because users can rename services.
        let output = try run(networksetupPath, ["-listnetworkserviceorder"])

        var pendingService: String?

        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("(") && line.contains(")") {
                // Example: (1) Wi-Fi
                if let idx = line.firstIndex(of: ")") {
                    pendingService = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if line.hasPrefix("(Device:") {
                let device = line
                    .replacingOccurrences(of: "(Device:", with: "")
                    .replacingOccurrences(of: ")", with: "")
                    .trimmingCharacters(in: .whitespaces)

                if device == interface, let service = pendingService, !service.isEmpty {
                    return service
                }
            }
        }

        throw SystemProxyError.networkServiceNotFound(interface: interface)
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw SystemProxyError.commandFailed(output.isEmpty
                                                 ? "Command failed: \(executable) \(arguments.joined(separator: " "))"
                                                 : output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return output
    }
}
