import Foundation
import MClashNetworkShared
import Testing
@testable import MClashApp

@Suite("Flow Ledger Evidence Presentation")
struct FlowLedgerEvidencePresentationTests {
    @Test("History with unavailable counters never claims measured zero bytes")
    func unavailableHistorySummary() {
        let coverage = TrafficHistoryCoverage(exactDirectionCount: 0, notMeasuredDirectionCount: 0,
                                              notAvailableDirectionCount: 4, notApplicableDirectionCount: 0)
        let totals = TrafficHistoryTotals(recordedFlowCount: 2, exactUploadBytes: 0,
                                         exactDownloadBytes: 0, coverage: coverage)
        let summary = FlowLedgerTrafficPresentation.historySummary(totals, lastUpdatedAt: nil)
        #expect(summary == AppLocalization.format("%@ records · byte totals unavailable", "2"))
        #expect(coverage.measuredFraction == 0)
        let mixed = TrafficHistoryCoverage(exactDirectionCount: 2, notMeasuredDirectionCount: 2,
                                           notAvailableDirectionCount: 4, notApplicableDirectionCount: 10)
        #expect(mixed.measuredFraction == 0.25)
    }

    @Test("Only exact relay-port association is confirmed")
    func exactAssociationIsTheOnlyConfirmedEvidence() {
        let exact = FlowLedgerAssociation.exactRelayPort(connectionID: "exact-id")
        let probable = FlowLedgerAssociation.destinationAndStartTime(
            connectionID: "probable-id",
            difference: 0.42
        )

        #expect(FlowLedgerAssociationPresentation.isConfirmed(exact))
        #expect(!FlowLedgerAssociationPresentation.isConfirmed(probable))
        #expect(FlowLedgerAssociationPresentation.isProbable(probable))
        #expect(FlowLedgerAssociationPresentation.title(probable).contains("Probable only"))
        #expect(FlowLedgerAssociationPresentation.title(probable).contains("Δ"))
        #expect(FlowLedgerAssociationPresentation.title(probable).contains("probable-id"))
    }

    @Test("Measured Direct relay is not described as a macOS handoff")
    func measuredDirectTrafficUsesLocalRelayEvidence() throws {
        let ledger = FlowLedger(
            activeConnections: [],
            appRoutingActivities: [directActivity(measured: true, upload: 120, download: 880)]
        )
        let aggregate = try #require(ledger.routeAggregates.first)
        let detail = FlowLedgerTrafficPresentation.directRouteDetail(aggregate.traffic)

        #expect(detail == "Relayed locally; payload measured")
        #expect(!detail.localizedCaseInsensitiveContains("handed"))
        #expect(FlowLedgerTrafficPresentation.coverageHelp(aggregate.traffic).contains("App Routing relay"))
    }

    @Test("Unmeasured Direct handoff remains explicit")
    func unmeasuredDirectTrafficRemainsExplicit() throws {
        let ledger = FlowLedger(
            activeConnections: [],
            appRoutingActivities: [directActivity(measured: false)]
        )
        let aggregate = try #require(ledger.routeAggregates.first)
        let detail = FlowLedgerTrafficPresentation.directRouteDetail(aggregate.traffic)

        #expect(detail.contains("pass-through"))
        #expect(detail.contains("unmeasured"))
        #expect(FlowLedgerTrafficPresentation.coverageHelp(aggregate.traffic).contains("outside MClash"))
    }

    private func directActivity(
        measured: Bool,
        upload: UInt64 = 0,
        download: UInt64 = 0
    ) -> AppRoutingActivity {
        AppRoutingActivity(
            flowIdentifier: UUID(),
            configurationRevision: 1,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: AppRoutingActivitySource(
                processIdentifier: 42,
                userIdentifier: 501,
                executablePath: "/Applications/Example.app/Contents/MacOS/Example",
                bundleIdentifier: "com.example.app",
                signingIdentifier: "com.example.app",
                teamIdentifier: "TEAM"
            ),
            destination: AppRoutingActivityDestination(
                hostname: "example.com",
                ipAddress: "1.1.1.1",
                port: 443
            ),
            transportProtocol: .tcp,
            decision: FlowTrafficDecision(
                disposition: .direct,
                reason: .rule(.matchedRule("Direct Rule"))
            ),
            configuredAction: .direct,
            effectiveAction: .direct,
            relayState: measured ? .completed : .notApplicable,
            payloadBytesAreMeasured: measured,
            uploadBytes: upload,
            downloadBytes: download
        )
    }
}
