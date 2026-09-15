import Darwin
import Foundation

@main
struct XraySupervisorSmoke {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let binaryPath = environment["MCLASH_XRAY_BINARY"],
              let target = environment["MCLASH_XRAY_SMOKE_ORIGIN"] else {
            throw Failure.missingEnvironment
        }
        let root = URL(fileURLWithPath: "/tmp/mcx-" + UUID().uuidString.prefix(12))
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let port = try freePort()
        let socket = root.appending(path: "api.sock").path
        let config = root.appending(path: "config.json")
        let object: [String: Any] = [
            "log": ["loglevel": "warning"],
            "api": ["tag": "api", "listen": socket, "services": ["StatsService", "RoutingService"]],
            "stats": [:],
            "inbounds": [["tag": "input", "listen": "127.0.0.1", "port": port,
                          "protocol": "socks", "settings": ["auth": "noauth"]]],
            "outbounds": [["tag": "direct", "protocol": "freedom"], ["tag": "reject", "protocol": "blackhole"]],
            "routing": ["rules": [["type": "field", "inboundTag": ["input"], "outboundTag": "direct"]]],
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: config)
        let backend = CoreBackend.xray(apiSocketPath: socket, version: "smoke")
        let launch = CoreLaunchConfiguration(
            binaryURL: URL(fileURLWithPath: binaryPath), homeDirectory: root,
            configURL: config, controllerPort: 0, secret: "", backend: backend
        )
        let supervisor = CoreSupervisor()
        supervisor.setProcessLogForwardingEnabled(true)
        let events = Task {
            for await event in supervisor.events {
                FileHandle.standardError.write(Data("\(event)\n".utf8))
            }
        }
        defer { events.cancel() }
        let start = ContinuousClock.now
        do {
            try await supervisor.start(launch)
            guard case let .running(session) = await supervisor.state(), session.backend == backend else {
                throw Failure.notRunning
            }
            let elapsed = start.duration(to: .now).components
            print("xray_ready_seconds=\(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)")
            try request(port: port, target: target)
            let invalid = root.appending(path: "invalid.json")
            try Data("{\"inbounds\":[{\"protocol\":\"nonexistent\"}]}".utf8).write(to: invalid)
            do {
                try await supervisor.validateWithoutStateChanges(CoreLaunchConfiguration(
                    binaryURL: launch.binaryURL, homeDirectory: root, configURL: invalid,
                    controllerPort: 0, secret: "", backend: backend
                ))
                throw Failure.invalidAccepted
            } catch CoreSupervisorError.configurationInvalid {
                print("invalid_candidate_rejected=true")
            }
            guard case .running = await supervisor.state() else { throw Failure.oldSessionLost }
            try request(port: port, target: target)
            guard await supervisor.stop(), await supervisor.state() == .stopped else {
                throw Failure.didNotStop
            }
            print("Xray supervisor smoke passed: readiness, payload, rejected candidate, old-session payload, stop")
        } catch {
            _ = await supervisor.stop()
            throw error
        }
    }

    private static func request(port: UInt16, target: String) throws {
        let request = Process()
        request.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        request.arguments = ["--silent", "--show-error", "--fail", "--max-time", "5", "--noproxy", "",
                             "--socks5-hostname", "127.0.0.1:\(port)", target]
        let pipe = Pipe()
        request.standardOutput = pipe
        try request.run()
        let response = pipe.fileHandleForReading.readDataToEndOfFile()
        request.waitUntilExit()
        guard request.terminationStatus == 0, response == Data("mclash-xray-payload\n".utf8) else {
            throw Failure.payloadMismatch
        }
    }

    private static func freePort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.socket }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw Failure.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw Failure.socket }
        return UInt16(bigEndian: address.sin_port)
    }

    private enum Failure: Error {
        case missingEnvironment, notRunning, invalidAccepted, oldSessionLost, didNotStop, payloadMismatch, socket
    }
}
