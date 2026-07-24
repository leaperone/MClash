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

    func isAvailableTCPAndUDP(port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }

        let tcp = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard tcp >= 0 else { return false }
        defer { Darwin.close(tcp) }
        var tcpAddress = loopbackAddress(port: port)
        let tcpBind = withUnsafePointer(to: &tcpAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(tcp, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard tcpBind == 0 else { return false }

        let udp = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard udp >= 0 else { return false }
        defer { Darwin.close(udp) }
        var udpAddress = loopbackAddress(port: port)
        let udpBind = withUnsafePointer(to: &udpAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(udp, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard udpBind == 0 else { return false }

        let tcp6 = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard tcp6 >= 0 else { return false }
        defer { Darwin.close(tcp6) }
        guard configureIPv6Only(tcp6),
              bindIPv6(tcp6, port: port) else { return false }

        let udp6 = Darwin.socket(AF_INET6, SOCK_DGRAM, 0)
        guard udp6 >= 0 else { return false }
        defer { Darwin.close(udp6) }
        return configureIPv6Only(udp6) && bindIPv6(udp6, port: port)
    }

    /// UDP has no TIME_WAIT state. This narrower probe distinguishes a
    /// recently stopped TCP listener from a port another process still owns.
    func isAvailableUDP(port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }

        let udp = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard udp >= 0 else { return false }
        defer { Darwin.close(udp) }
        var udpAddress = loopbackAddress(port: port)
        let udpBind = withUnsafePointer(to: &udpAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    udp,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard udpBind == 0 else { return false }

        let udp6 = Darwin.socket(AF_INET6, SOCK_DGRAM, 0)
        guard udp6 >= 0 else { return false }
        defer { Darwin.close(udp6) }
        return configureIPv6Only(udp6) && bindIPv6(udp6, port: port)
    }

    /// Reserves distinct loopback ports for listeners that must bind both TCP
    /// and UDP. All descriptors stay open until the complete set is selected,
    /// preventing duplicate ephemeral-port results within one allocation.
    func availableTCPAndUDPPorts(
        count: Int,
        excluding excludedPorts: Set<Int> = []
    ) throws -> [Int] {
        guard count > 0 else { throw LocalPortProbeError.noPorts }

        var descriptors: [Int32] = []
        defer { descriptors.forEach { Darwin.close($0) } }
        var ports: [Int] = []
        var attempts = 0

        while ports.count < count, attempts < max(64, count * 8) {
            attempts += 1
            let tcp = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard tcp >= 0 else {
                throw LocalPortProbeError.socketCreationFailed(errno)
            }

            var address = loopbackAddress(port: 0)
            let tcpBind = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        tcp,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard tcpBind == 0 else {
                let code = errno
                Darwin.close(tcp)
                throw LocalPortProbeError.bindFailed(code)
            }

            var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(tcp, $0, &addressLength)
                }
            }
            guard nameResult == 0 else {
                let code = errno
                Darwin.close(tcp)
                throw LocalPortProbeError.portLookupFailed(code)
            }
            let port = Int(UInt16(bigEndian: address.sin_port))
            guard (1 ... 65_535).contains(port) else {
                Darwin.close(tcp)
                throw LocalPortProbeError.invalidPort(port)
            }
            if excludedPorts.contains(port) {
                Darwin.close(tcp)
                continue
            }

            let udp = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
            guard udp >= 0 else {
                let code = errno
                Darwin.close(tcp)
                throw LocalPortProbeError.socketCreationFailed(code)
            }
            var udpAddress = loopbackAddress(port: port)
            let udpBind = withUnsafePointer(to: &udpAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        udp,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard udpBind == 0 else {
                Darwin.close(tcp)
                Darwin.close(udp)
                continue
            }

            let tcp6 = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
            guard tcp6 >= 0 else {
                Darwin.close(tcp)
                Darwin.close(udp)
                throw LocalPortProbeError.socketCreationFailed(errno)
            }
            guard configureIPv6Only(tcp6),
                  bindIPv6(tcp6, port: port) else {
                Darwin.close(tcp)
                Darwin.close(udp)
                Darwin.close(tcp6)
                continue
            }

            let udp6 = Darwin.socket(AF_INET6, SOCK_DGRAM, 0)
            guard udp6 >= 0 else {
                Darwin.close(tcp)
                Darwin.close(udp)
                Darwin.close(tcp6)
                throw LocalPortProbeError.socketCreationFailed(errno)
            }
            guard configureIPv6Only(udp6),
                  bindIPv6(udp6, port: port) else {
                Darwin.close(tcp)
                Darwin.close(udp)
                Darwin.close(tcp6)
                Darwin.close(udp6)
                continue
            }

            descriptors.append(tcp)
            descriptors.append(udp)
            descriptors.append(tcp6)
            descriptors.append(udp6)
            ports.append(port)
        }

        guard ports.count == count else {
            throw LocalPortProbeError.portSetUnavailable(requested: count)
        }
        return ports
    }

    func isListening(port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }

        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var address = loopbackAddress(port: port)
        let ipv4Result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        if ipv4Result == 0 { return true }

        let descriptor6 = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor6 >= 0 else { return false }
        defer { Darwin.close(descriptor6) }
        guard configureIPv6Only(descriptor6) else { return false }
        var address6 = sockaddr_in6()
        address6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address6.sin6_family = sa_family_t(AF_INET6)
        address6.sin6_port = in_port_t(port).bigEndian
        address6.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &address6) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor6,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in6>.size)
                )
            }
        } == 0
    }

    func waitUntilListening(ports: Set<Int>) async throws {
        guard !ports.isEmpty else { throw LocalPortProbeError.noPorts }

        for _ in 0..<40 {
            if ports.allSatisfy(isListening(port:)) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LocalPortProbeError.listenerUnavailable(ports.sorted())
    }

    /// Verifies the protocols MClash will actually expose, rather than merely
    /// accepting any process that happens to own the requested TCP port.
    func waitUntilProxyProtocols(httpPort: Int, socksPort: Int) async throws {
        try await waitUntilProxyProtocols(
            httpPorts: [httpPort],
            socksPorts: [socksPort]
        )
    }

    func waitUntilProxyProtocols(
        httpPorts: Set<Int>,
        socksPorts: Set<Int>
    ) async throws {
        let ports = httpPorts.union(socksPorts)
        guard !httpPorts.isEmpty, !socksPorts.isEmpty else {
            throw LocalPortProbeError.noPorts
        }
        guard ports.allSatisfy({ (1...65_535).contains($0) }) else {
            throw LocalPortProbeError.listenerUnavailable(ports.sorted())
        }

        for _ in 0..<40 {
            try Task.checkCancellation()
            let ready = await Task.detached(priority: .utility) {
                httpPorts.allSatisfy(supportsHTTPProxy(port:))
                    && socksPorts.allSatisfy(supportsSOCKS5Proxy(port:))
            }.value
            if ready { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw LocalPortProbeError.listenerUnavailable(ports.sorted())
    }

    func supportsHTTPProxy(port: Int) -> Bool {
        guard let descriptor = connectedSocket(port: port) else { return false }
        defer { Darwin.close(descriptor) }

        let request = Data(
            "CONNECT 127.0.0.1:1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\nConnection: close\r\n\r\n".utf8
        )
        guard send(request, to: descriptor) else { return false }
        var response = [UInt8](repeating: 0, count: 8)
        let count = response.withUnsafeMutableBytes { buffer in
            Darwin.recv(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard count >= 5 else { return false }
        return response.prefix(5).elementsEqual(Array("HTTP/".utf8))
    }

    func supportsSOCKS5Proxy(port: Int) -> Bool {
        guard let descriptor = connectedSocket(port: port) else { return false }
        defer { Darwin.close(descriptor) }

        guard send(Data([0x05, 0x01, 0x00]), to: descriptor) else { return false }
        var response = [UInt8](repeating: 0, count: 2)
        let count = response.withUnsafeMutableBytes { buffer in
            Darwin.recv(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        return count == 2 && response[0] == 0x05
    }

    private func connectedSocket(port: Int) -> Int32? {
        guard (1...65_535).contains(port) else { return nil }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }

        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

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
        guard result == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return descriptor
    }

    private func send(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            return Darwin.send(descriptor, baseAddress, buffer.count, 0) == buffer.count
        }
    }

    private func loopbackAddress(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return address
    }

    private func configureIPv6Only(_ descriptor: Int32) -> Bool {
        var enabled: Int32 = 1
        return withUnsafePointer(to: &enabled) {
            Darwin.setsockopt(
                descriptor,
                IPPROTO_IPV6,
                IPV6_V6ONLY,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        } == 0
    }

    private func bindIPv6(_ descriptor: Int32, port: Int) -> Bool {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(port).bigEndian
        address.sin6_addr = in6addr_loopback
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in6>.size)
                )
            }
        } == 0
    }
}

enum LocalPortProbeError: LocalizedError, Equatable {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case portLookupFailed(Int32)
    case invalidPort(Int)
    case noPorts
    case portSetUnavailable(requested: Int)
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
        case let .portSetUnavailable(requested):
            "Could not reserve \(requested) distinct local TCP/UDP proxy ports."
        case let .listenerUnavailable(ports):
            "The local proxy listener did not start on \(ports.map(String.init).joined(separator: ", "))."
        }
    }
}
