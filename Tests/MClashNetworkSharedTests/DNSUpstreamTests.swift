import Foundation
@preconcurrency import Dispatch
import Darwin
import Testing
@testable import MClashNetworkShared

@Suite("Connector-neutral DNS upstream")
struct DNSUpstreamTests {
    @Test("Native DNS bootstrap is connector-neutral and round-trips independently")
    func nativeBootstrapDoesNotNeedMihomoEndpoint() throws {
        let udp = try DNSUpstreamEndpoint(
            address: IPAddress("223.5.5.5"),
            transport: .udp
        )
        let tcp = try DNSUpstreamEndpoint(
            address: IPAddress("1.1.1.1"),
            port: 853,
            transport: .tcp,
            timeoutMilliseconds: 3_000
        )
        let bootstrap = try DNSUpstreamBootstrap(endpoints: [udp, tcp])
        let decoded = try DNSUpstreamBootstrap.decode(bootstrap.encoded())
        #expect(decoded == bootstrap)
        #expect(decoded.primary == udp)
        #expect(decoded.endpoints.allSatisfy { $0.transport == .udp || $0.transport == .tcp })
    }

    @Test("Native DNS bootstrap rejects duplicate upstreams")
    func nativeBootstrapRejectsDuplicates() throws {
        let endpoint = try DNSUpstreamEndpoint(
            address: IPAddress("223.5.5.5"),
            transport: .udp
        )
        #expect(throws: DNSUpstreamBootstrapError.duplicateEndpoint) {
            _ = try DNSUpstreamBootstrap(endpoints: [endpoint, endpoint])
        }
    }

    @Test("Native DNS endpoint selection is ordered and reports fallback")
    func nativeBootstrapSelectionIsDeterministic() throws {
        let bootstrap = try DNSUpstreamBootstrap(endpoints: [
            try DNSUpstreamEndpoint(address: IPAddress("9.9.9.9"), transport: .udp),
            try DNSUpstreamEndpoint(address: IPAddress("1.1.1.1"), transport: .tcp),
            try DNSUpstreamEndpoint(address: IPAddress("8.8.8.8"), transport: .udp),
        ])
        let exact = bootstrap.select(
            interceptedAddress: try IPAddress("8.8.8.8"), transport: .udp
        )
        let exactAddress = try IPAddress("8.8.8.8")
        #expect(exact.endpoint?.address == exactAddress)
        #expect(exact.reason == .exactAddress)
        let fallback = bootstrap.select(
            interceptedAddress: try IPAddress("192.0.2.53"), transport: .udp
        )
        let fallbackAddress = try IPAddress("9.9.9.9")
        #expect(fallback.endpoint?.address == fallbackAddress)
        #expect(fallback.reason == .firstMatchingTransport)
        let unavailable = bootstrap.select(
            interceptedAddress: nil, transport: .tcp
        )
        let unavailableAddress = try IPAddress("1.1.1.1")
        #expect(unavailable.endpoint?.address == unavailableAddress)
    }

    @Test("Native DNS bootstrap does not require a Mihomo route endpoint")
    func nativeBootstrapIsMihomoIndependent() throws {
        let upstream = try DNSUpstreamEndpoint(
            address: IPAddress("223.5.5.5"),
            transport: .udp
        )
        let bootstrap = try DNSProxyBootstrapConfiguration(
            revision: 1,
            activationIdentifier: UUID(),
            nativeUpstreamBootstrap: DNSUpstreamBootstrap(endpoints: [upstream])
        )
        #expect(bootstrap.profileRulesProxy == nil)
        let decoded = try DNSProxyBootstrapConfiguration.decode(bootstrap.encoded())
        #expect(decoded.profileRulesProxy == nil)
        #expect(decoded.dnsUpstreamMode == .native)
    }

    private let query = Data([
        0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x07, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x03, 0x63, 0x6f, 0x6d,
        0x00, 0x00, 0x01, 0x00, 0x01
    ])

    @Test("Validates query and response transaction ID")
    func validatesMessages() throws {
        let id = try DNSWireMessage.validateQuery(query, transport: .udp)
        #expect(id == 0x1234)
        var response = query
        response[2] = 0x81
        response[3] = 0x80
        try DNSWireMessage.validateResponse(response, matching: id, transport: .udp)
    }

    @Test("Socket DNS upstream exchanges with a loopback UDP server")
    func socketUDPExchangeUsesLoopbackFixture() async throws {
        let queryData = query
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }

        var serverAddress = sockaddr_in()
        serverAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        serverAddress.sin_family = sa_family_t(AF_INET)
        serverAddress.sin_port = 0
        serverAddress.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &serverAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindResult == 0)
        guard bindResult == 0 else { return }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let lookupResult = withUnsafeMutablePointer(to: &serverAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &addressLength)
            }
        }
        #expect(lookupResult == 0)
        guard lookupResult == 0 else { return }

        // Keep the fixture bounded even if the upstream never receives a query.
        var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
        let timeoutResult = withUnsafePointer(to: &receiveTimeout) {
            Darwin.setsockopt(
                descriptor, SOL_SOCKET, SO_RCVTIMEO, $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        #expect(timeoutResult == 0)
        guard timeoutResult == 0 else { return }

        let expectedID = try DNSWireMessage.transactionID(of: query)
        let port = UInt16(bigEndian: serverAddress.sin_port)
        let server = DispatchQueue.global(qos: .userInitiated)
        server.async {
            var packet = [UInt8](repeating: 0, count: DNSUpstreamLimits.maximumUDPMessageBytes)
            var clientAddress = sockaddr_storage()
            var clientLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let received = withUnsafeMutablePointer(to: &clientAddress) { clientPointer in
                withUnsafeMutablePointer(to: &clientLength) { lengthPointer in
                    packet.withUnsafeMutableBytes { buffer in
                        Darwin.recvfrom(
                            descriptor,
                            buffer.baseAddress,
                            buffer.count,
                            0,
                            clientPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 },
                            lengthPointer
                        )
                    }
                }
            }
            guard received == queryData.count else { return }
            let receivedQuery = Data(packet.prefix(received))
            guard (try? DNSWireMessage.validateQuery(receivedQuery, transport: .udp)) == expectedID else {
                return
            }
            var response = receivedQuery
            response[2] = 0x81
            response[3] = 0x80
            response.withUnsafeBytes { bytes in
                _ = Darwin.sendto(
                    descriptor,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    withUnsafePointer(to: &clientAddress) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
                    },
                    clientLength
                )
            }
        }

        let endpoint = try DNSUpstreamEndpoint(
            address: IPAddress("127.0.0.1"), port: port, transport: .udp,
            timeoutMilliseconds: 1_000
        )
        let response = try await SocketDNSUpstream(endpoint: endpoint).exchange(query: query)
        #expect(try DNSWireMessage.transactionID(of: response) == expectedID)
        try DNSWireMessage.validateResponse(response, matching: expectedID, transport: .udp)
    }

    @Test("Rejects malformed or mismatched messages")
    func rejectsUnsafeMessages() throws {
        #expect(throws: DNSUpstreamError.self) {
            try DNSWireMessage.validateQuery(Data(repeating: 0, count: 11), transport: .udp)
        }
        var response = query
        response[0] = 0x99
        response[2] = 0x80
        #expect(throws: DNSUpstreamError.mismatchedTransactionID) {
            try DNSWireMessage.validateResponse(response, matching: 0x1234, transport: .udp)
        }
        #expect(throws: DNSUpstreamError.invalidMessage("query has response flag")) {
            var invalid = query
            invalid[2] = 0x80
            _ = try DNSWireMessage.validateQuery(invalid, transport: .udp)
        }
    }

    @Test("Uses bounded two-byte TCP framing")
    func tcpFraming() throws {
        let frame = try DNSWireMessage.tcpFrame(for: query)
        #expect(frame.count == query.count + 2)
        #expect(try DNSWireMessage.message(fromTCPFrame: frame) == query)
        #expect(throws: DNSUpstreamError.self) {
            try DNSWireMessage.message(fromTCPFrame: Data([0xff, 0xff]))
        }
        #expect(throws: DNSUpstreamError.self) {
            try DNSWireMessage.message(fromTCPFrame: Data([0, 3, 1]))
        }
    }

    @Test("Constrains upstream endpoint values")
    func validatesEndpoint() throws {
        let address = try IPAddress("192.0.2.53")
        let endpoint = try DNSUpstreamEndpoint(address: address, transport: .udp)
        #expect(endpoint.port == 53)
        #expect(endpoint.transport == .udp)
        #expect(throws: DNSUpstreamError.invalidEndpoint) {
            try DNSUpstreamEndpoint(address: address, port: 0, transport: .tcp)
        }
    }
}
