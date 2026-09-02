import Testing
@testable import MClashNetworkShared

@Suite("Outbound node target")
struct OutboundNodeTargetTests {
    @Test("Normalizes protocol names without changing endpoint material")
    func normalizesProtocol() throws {
        let target = try OutboundNodeTarget(
            protocolName: "  VLESS ",
            host: "us.example.com",
            port: 443,
            parameters: ["uuid": "secret"]
        )
        #expect(target.protocolName == "vless")
        #expect(target.host == "us.example.com")
        #expect(target.port == 443)
        #expect(target.parameters["uuid"] == "secret")
    }

    @Test("Rejects empty or oversized connector material")
    func rejectsInvalidMaterial() {
        #expect(throws: OutboundNodeTargetError.invalidEndpoint) {
            try OutboundNodeTarget(protocolName: "vless", host: "", port: 443)
        }
        #expect(throws: OutboundNodeTargetError.invalidEndpoint) {
            try OutboundNodeTarget(protocolName: "vless", host: "example.com", port: 0)
        }
    }
}
