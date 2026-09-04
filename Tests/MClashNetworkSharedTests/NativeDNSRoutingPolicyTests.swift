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
}
