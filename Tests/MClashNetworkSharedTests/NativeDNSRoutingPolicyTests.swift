import Testing
@testable import MClashNetworkShared

@Suite("Native DNS routing policy")
struct NativeDNSRoutingPolicyTests {
    @Test("Uses longest label-boundary suffix deterministically")
    func suffixPrecedence() {
        let policy = NativeDNSRoutingPolicy(rules: [
            "domain:example.com,9.9.9.9",
            "domain-suffix:api.example.com,1.1.1.1",
            "+.example.net,system"
        ])
        #expect(policy.decision(for: "v1.api.example.com") == .nameserver("1.1.1.1"))
        #expect(policy.decision(for: "badexample.com") == .system)
        #expect(policy.decision(for: "x.example.net.") == .system)
    }

    @Test("Does not guess unsupported rule-set destinations")
    func unsupported() {
        let policy = NativeDNSRoutingPolicy(rules: ["domain:ai.example,proxy-group"])
        #expect(policy.decision(for: "ai.example") == .unsupported("proxy-group"))
        #expect(policy.decision(for: "other.example") == .system)
    }

    @Test("Bootstrap persists policy rules and prioritizes the literal upstream")
    func bootstrapPolicySelection() throws {
        let preferred = try DNSUpstreamEndpoint(address: IPAddress("9.9.9.9"), transport: .udp)
        let fallback = try DNSUpstreamEndpoint(address: IPAddress("1.1.1.1"), transport: .udp)
        let bootstrap = try DNSUpstreamBootstrap(endpoints: [fallback, preferred], policyRules: ["domain:internal.example,9.9.9.9"])
        let decoded = try DNSUpstreamBootstrap.decode(try bootstrap.encoded())
        #expect(decoded == bootstrap)
        #expect(decoded.orderedEndpoints(for: "db.internal.example").first?.address == preferred.address)
        #expect(decoded.orderedEndpoints(for: "public.example").first?.address == fallback.address)
    }
}
