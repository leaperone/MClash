import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Connector-neutral DNS upstream")
struct DNSUpstreamTests {
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
            try DNSWireMessage.validateQuery(invalid, transport: .udp)
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
