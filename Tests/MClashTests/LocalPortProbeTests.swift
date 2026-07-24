import Darwin
import Testing
@testable import MClashApp

@Suite("Local proxy listener probe")
struct LocalPortProbeTests {
    @Test("The operating system can allocate an eligible loopback port")
    func allocatesLocalPort() throws {
        let port = try LocalPortProbe().availableTCPPort()

        #expect((1...65_535).contains(port))
    }

    @Test("A route catalog receives distinct TCP and UDP eligible ports")
    func allocatesDistinctTCPAndUDPPorts() throws {
        let ports = try LocalPortProbe().availableTCPAndUDPPorts(count: 4)

        #expect(ports.count == 4)
        #expect(Set(ports).count == 4)
        #expect(ports.allSatisfy { (1 ... 65_535).contains($0) })
    }

    @Test("Invalid ports are never reported as listening")
    func rejectsInvalidPorts() {
        let probe = LocalPortProbe()

        #expect(!probe.isListening(port: 0))
        #expect(!probe.isListening(port: 65_536))
    }

    @Test("An unrelated TCP listener is not accepted as an HTTP or SOCKS5 proxy")
    func rejectsUnrelatedTCPListener() throws {
        let listener = try UnrelatedTCPListener()
        let probe = LocalPortProbe()

        #expect(probe.isListening(port: listener.port))
        #expect(!probe.supportsHTTPProxy(port: listener.port))
        #expect(!probe.supportsSOCKS5Proxy(port: listener.port))
    }

    @Test("IPv6 loopback occupancy rejects a dual-stack listener port")
    func rejectsIPv6OccupiedPort() throws {
        let listener = try IPv6LoopbackListener()
        let probe = LocalPortProbe()

        #expect(!probe.isAvailableTCPAndUDP(port: listener.port))
        #expect(probe.isListening(port: listener.port))
    }

    @Test("UDP occupancy is detected without relying on TCP bind state")
    func rejectsOccupiedUDPPort() throws {
        let listener = try UDPLoopbackListener()

        #expect(!LocalPortProbe().isAvailableUDP(port: listener.port))
    }
}

private final class UDPLoopbackListener {
    let descriptor: Int32
    let port: Int

    init() throws {
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard socketDescriptor >= 0 else {
            throw LocalPortProbeError.socketCreationFailed(errno)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bound == 0 else {
            Darwin.close(socketDescriptor)
            throw LocalPortProbeError.bindFailed(errno)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socketDescriptor, $0, &length)
            }
        }
        guard read == 0 else {
            Darwin.close(socketDescriptor)
            throw LocalPortProbeError.portLookupFailed(errno)
        }
        descriptor = socketDescriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    deinit {
        Darwin.close(descriptor)
    }
}

private final class IPv6LoopbackListener {
    let descriptor: Int32
    let port: Int

    init() throws {
        let socketDescriptor = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw LocalPortProbeError.socketCreationFailed(errno)
        }
        var ipv6Only: Int32 = 1
        guard withUnsafePointer(to: &ipv6Only, {
            Darwin.setsockopt(
                socketDescriptor,
                IPPROTO_IPV6,
                IPV6_V6ONLY,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }) == 0 else {
            Darwin.close(socketDescriptor)
            throw LocalPortProbeError.bindFailed(errno)
        }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = 0
        address.sin6_addr = in6addr_loopback
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in6>.size)
                )
            }
        }
        guard bound == 0, Darwin.listen(socketDescriptor, 8) == 0 else {
            Darwin.close(socketDescriptor)
            throw LocalPortProbeError.bindFailed(errno)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socketDescriptor, $0, &length)
            }
        }
        guard read == 0 else {
            Darwin.close(socketDescriptor)
            throw LocalPortProbeError.portLookupFailed(errno)
        }
        descriptor = socketDescriptor
        port = Int(UInt16(bigEndian: address.sin6_port))
    }

    deinit {
        Darwin.close(descriptor)
    }
}

private final class UnrelatedTCPListener {
    let descriptor: Int32
    let port: Int

    init() throws {
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw LocalPortProbeError.socketCreationFailed(errno) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(socketDescriptor, 8) == 0 else {
            Darwin.close(socketDescriptor)
            throw LocalPortProbeError.bindFailed(errno)
        }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let lookupResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socketDescriptor, $0, &addressLength)
            }
        }
        guard lookupResult == 0 else {
            Darwin.close(socketDescriptor)
            throw LocalPortProbeError.portLookupFailed(errno)
        }
        descriptor = socketDescriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    deinit {
        Darwin.close(descriptor)
    }
}
