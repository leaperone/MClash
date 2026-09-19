import Foundation
import MClashNetworkShared
import Testing
@testable import MClashApp

@Suite("Runtime flow projection")
struct RuntimeFlowProjectionTests {
    @Test("App Routing projection preserves observed source and flow fields")
    func appRoutingFields() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let ended = started.addingTimeInterval(2)
        let source = AppRoutingActivitySource(
            processIdentifier: 42,
            userIdentifier: 501,
            executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
            bundleIdentifier: "com.example.browser"
        )
        let destination = AppRoutingActivityDestination(hostname: "api.example.com", ipAddress: "203.0.113.4", port: 443)
        let activity = AppRoutingActivity(
            flowIdentifier: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
            configurationRevision: 7,
            startedAt: started,
            endedAt: ended,
            source: source,
            destination: destination,
            transportProtocol: .tcp,
            decision: FlowTrafficDecision(disposition: .mihomo(.profileRules), reason: .rule(.matchedRule("rule-1"))),
            configuredAction: .mihomo(.profileRules),
            effectiveAction: .mihomo(.profileRules),
            relayState: .completed,
            payloadBytesAreMeasured: true,
            uploadBytes: 12,
            downloadBytes: 34
        )
        let projection = RuntimeFlowProjection.appRouting(
            activity,
            configuredPath: ConfiguredRoutePath(entrance: "capture", mode: "rule", ruleIdentifier: "rule-1", group: "Default")
        )
        #expect(projection.id == activity.flowIdentifier)
        #expect(projection.evidence == .appRoutingObserved)
        #expect(projection.observedBackend == .mihomoCompatibility)
        #expect(projection.source == source)
        #expect(projection.destination == destination)
        #expect(projection.transportProtocol == .tcp)
        #expect(projection.startedAt == started)
        #expect(projection.endedAt == ended)
        #expect(projection.uploadBytes == 12)
        #expect(projection.downloadBytes == 34)
        #expect(projection.configuredPath.ruleIdentifier == "rule-1")
    }

    @Test("Xray aggregate projection never fabricates a per-flow route")
    func xrayAggregate() {
        let sampled = Date(timeIntervalSince1970: 1_700_000_100)
        let projection = RuntimeFlowProjection.xrayAggregate(
            uploadBytes: 100,
            downloadBytes: 250,
            sampledAt: sampled,
            configuredPath: ConfiguredRoutePath(mode: "rule", group: "Fallback")
        )
        #expect(projection.evidence == .xrayAggregateOnly)
        #expect(projection.observedBackend == .xray)
        #expect(projection.source == nil)
        #expect(projection.destination == nil)
        #expect(projection.transportProtocol == nil)
        #expect(projection.endedAt == nil)
        #expect(projection.uploadBytes == 100)
        #expect(projection.downloadBytes == 250)
        #expect(projection.configuredPath.node == nil)
    }

    @Test("Aggregate projection clamps invalid signed counters")
    func aggregateCounterSafety() {
        let projection = RuntimeFlowProjection.xrayAggregate(uploadBytes: -1, downloadBytes: -2, sampledAt: Date())
        #expect(projection.uploadBytes == 0)
        #expect(projection.downloadBytes == 0)
    }
}
