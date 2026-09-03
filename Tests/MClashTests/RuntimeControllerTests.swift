import Testing
@testable import MClashApp

@Suite("Connector-neutral runtime controller")
struct RuntimeControllerTests {
    @Test("Status keeps backend identity out of presentation state")
    func statusIsStableAndSendable() {
        let status = RuntimeControllerStatus(
            state: .running,
            routingMode: "rule",
            backend: "native"
        )
        #expect(status.isRunning)
        #expect(status.routingMode == "rule")
        #expect(status.backend == "native")
    }

    @Test("Rule summaries preserve matcher and hit count")
    func ruleSummaryHasStableIdentity() {
        let summary = RuntimeRuleSummary(
            id: "0:DOMAIN-SUFFIX:example.com",
            kind: "DOMAIN-SUFFIX",
            matcher: "example.com",
            outbound: "DIRECT",
            hitCount: 4
        )
        #expect(summary.id == "0:DOMAIN-SUFFIX:example.com")
        #expect(summary.matcher == "example.com")
        #expect(summary.outbound == "DIRECT")
        #expect(summary.hitCount == 4)
    }
}
