import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("DNS upstream Fake-IP bootstrap")
struct DNSUpstreamFakeIPBootstrapTests {
    private func endpoint() throws -> DNSUpstreamEndpoint {
        try DNSUpstreamEndpoint(address: IPAddress("1.1.1.1"), transport: .udp)
    }

    @Test("Round trips Fake-IP configuration and omits it when absent")
    func roundTripAndOmission() throws {
        let base = try DNSUpstreamBootstrap(endpoints: [endpoint()])
        #expect(base.fakeIPConfiguration == nil)
        let fake = try NativeFakeIPConfiguration()
        let configured = try DNSUpstreamBootstrap(endpoints: [endpoint()], fakeIPConfiguration: fake)
        let decoded = try DNSUpstreamBootstrap.decode(try configured.encoded())
        #expect(decoded.fakeIPConfiguration == fake)
    }

    @Test("Decodes schema-one payload with Fake-IP disabled")
    func oldPayload() throws {
        let json = """
        {"schemaVersion":1,"endpoints":[{"address":"1.1.1.1","port":53,"transport":"udp","timeoutMilliseconds":2000}],"policyRules":[]}
        """
        let decoded = try DNSUpstreamBootstrap.decode(Data(json.utf8))
        #expect(decoded.fakeIPConfiguration == nil)
    }
}
