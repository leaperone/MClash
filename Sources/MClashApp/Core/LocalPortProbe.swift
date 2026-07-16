import Darwin
import Foundation

struct LocalPortProbe: Sendable {
    func availableTCPPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw LocalPortProbeError.socketCreationFailed(errno)
        }
        defer { Darwin.close(descriptor) }

        var address = loopbackAddress(port: 0)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            throw LocalPortProbeError.bindFailed(errno)
        }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(descriptor, socketAddress, &addressLength)
            }
        }
        guard nameResult == 0 else {
            throw LocalPortProbeError.portLookupFailed(errno)
        }

        let port = Int(UInt16(bigEndian: address.sin_port))
        guard (1...65_535).contains(port) else {
            throw LocalPortProbeError.invalidPort(port)
        }
        return port
    }

    func isListening(port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }

        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var address = loopbackAddress(port: port)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        return result == 0
    }

    func waitUntilListening(ports: Set<Int>) async throws {
        guard !ports.isEmpty else { throw LocalPortProbeError.noPorts }

        for _ in 0..<40 {
            if ports.allSatisfy(isListening(port:)) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LocalPortProbeError.listenerUnavailable(ports.sorted())
    }

    private func loopbackAddress(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return address
    }
}

enum LocalPortProbeError: LocalizedError, Equatable {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case portLookupFailed(Int32)
    case invalidPort(Int)
    case noPorts
    case listenerUnavailable([Int])

    var errorDescription: String? {
        switch self {
        case let .socketCreationFailed(code):
            "Could not create a local network socket (errno \(code))."
        case let .bindFailed(code):
            "Could not reserve a local proxy port (errno \(code))."
        case let .portLookupFailed(code):
            "Could not read the reserved local proxy port (errno \(code))."
        case let .invalidPort(port):
            "The operating system returned an invalid local proxy port (\(port))."
        case .noPorts:
            "No local proxy listener was configured."
        case let .listenerUnavailable(ports):
            "The local proxy listener did not start on \(ports.map(String.init).joined(separator: ", "))."
        }
    }
}
