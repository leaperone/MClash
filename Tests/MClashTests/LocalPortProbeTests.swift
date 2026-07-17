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
