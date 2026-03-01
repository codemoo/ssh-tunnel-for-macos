import Foundation

struct ActiveSocksProxy {
    let serviceName: String
    let host: String
    let port: UInt16
}

enum SystemProxyError: LocalizedError {
    case defaultInterfaceNotFound
    case networkServiceNotFound(interface: String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .defaultInterfaceNotFound:
            return String(localized: "Could not determine default network interface.")
        case .networkServiceNotFound(let interface):
            return String(localized: "Could not find a network service for interface \(interface).")
        case .commandFailed(let message):
            return message
        }
    }
}

final class SystemProxyService {
    private let networksetupPath = "/usr/sbin/networksetup"
    private let routePath = "/sbin/route"

    func enableSocksProxy(host: String = "127.0.0.1", port: UInt16) throws -> ActiveSocksProxy {
        let service = try activeNetworkService()

        try run(networksetupPath, ["-setsocksfirewallproxy", service, host, "\(port)"])
        try run(networksetupPath, ["-setsocksfirewallproxystate", service, "on"])

        return ActiveSocksProxy(serviceName: service, host: host, port: port)
    }

    func disableSocksProxy(for serviceName: String) throws {
        try run(networksetupPath, ["-setsocksfirewallproxystate", serviceName, "off"])
    }

    private func activeNetworkService() throws -> String {
        let interface = try defaultInterface()
        let map = try hardwarePortMap()

        if let service = map[interface], !service.isEmpty {
            return service
        }

        throw SystemProxyError.networkServiceNotFound(interface: interface)
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

    private func hardwarePortMap() throws -> [String: String] {
        let output = try run(networksetupPath, ["-listallhardwareports"])
        var map: [String: String] = [:]

        var currentService: String?
        var currentDevice: String?

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("Hardware Port:") {
                currentService = line.replacingOccurrences(of: "Hardware Port:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Device:") {
                currentDevice = line.replacingOccurrences(of: "Device:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if line.isEmpty {
                if let service = currentService, let device = currentDevice {
                    map[device] = service
                }
                currentService = nil
                currentDevice = nil
            }
        }

        if let service = currentService, let device = currentDevice {
            map[device] = service
        }

        return map
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
