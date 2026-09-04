import Foundation
import MClashNetworkShared
import Testing
@testable import MClashApp

@Suite("Traffic inspector evidence")
struct FlowLedgerTrafficInspectorTests {
    @Test("Proxy explanation preserves rule, chain, entrance and DNS path")
    func proxyExplanationIsStructured() throws {
        let observation = FlowRelayObservation(
            id: "native-1",
            network: "tcp",
            destinationHost: "api.example.com",
            destinationIP: "203.0.113.8",
            destinationPort: 443,
            process: "Example",
            processPath: "/Applications/Example.app/Contents/MacOS/Example",
            inboundName: "HTTP",
            rule: "AI",
            rulePayload: "api.example.com",
            routeChain: ["GLOBAL", "CUNOE-Proxy", "US-01"],
            connector: "native-vless",
            route: .relay
        )
        let ledger = FlowLedger(
            activeConnections: [],
            flowRelayObservations: [observation]
        )
        let entry = try #require(ledger.entries.first)
        let inspector = FlowLedgerTrafficInspector(
            entry: entry,
            dnsPath: .remoteResolver("native-dns")
        )

        #expect(inspector.route == .proxy)
        #expect(inspector.entrance == "listener:HTTP")
        #expect(inspector.matchedRule == "AI")
        #expect(inspector.selectedNode == "US-01")
        #expect(inspector.dnsPath.identifier == "remote:native-dns")
        #expect(inspector.evidence.contains("rule-payload=api.example.com"))
        #expect(inspector.quickRuleDrafts.map(\.kind) == [
            .exactDomain,
            .domainSuffix,
            .ipAddress,
            .application,
            .processPath
        ])
        #expect(
            Set(inspector.quickRuleDrafts.map(\.id)).count
                == inspector.quickRuleDrafts.count
        )
    }

    @Test("Direct and rejected decisions explain themselves and remain actionable")
    func terminalRoutesRemainExplicit() throws {
        let observations = [
            FlowRelayObservation(id: "direct", destinationHost: "local.example", rule: "DIRECT", route: .direct),
            FlowRelayObservation(id: "reject", destinationHost: "blocked.example", rule: "REJECT", route: .rejected)
        ]
        let ledger = FlowLedger(
            activeConnections: [],
            flowRelayObservations: observations
        )
        let direct = try #require(ledger.entries.first(where: { $0.id == .native("direct") }))
        let rejected = try #require(ledger.entries.first(where: { $0.id == .native("reject") }))

        #expect(FlowLedgerTrafficInspector(entry: direct).route == .direct)
        #expect(FlowLedgerTrafficInspector(entry: direct).why == "Matched a direct route")
        #expect(FlowLedgerTrafficInspector(entry: rejected).route == .rejected)
        #expect(FlowLedgerTrafficInspector(entry: rejected).why == "Matched a blocking route")
        #expect(FlowLedgerTrafficInspector(entry: rejected).quickRuleDrafts.count == 2)
    }
}
