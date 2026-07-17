import Foundation
import MClashNetworkShared
import Testing
@testable import MClashApp

@Suite("App Routing traffic rates")
struct AppRoutingTrafficRateTrackerTests {
    @Test("Rates are derived from delivered counter deltas without counting handoffs")
    func derivesMeasuredRates() {
        var tracker = AppRoutingTrafficRateTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        var direct = activity(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            action: .direct,
            rule: "Direct app",
            measured: true,
            upload: 100,
            download: 200
        )
        let handoff = activity(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            action: .failOpen,
            rule: "Handoff",
            measured: false,
            upload: 9_999,
            download: 9_999
        )
        #expect(tracker.ingest([direct, handoff], at: start) == .zero)

        direct.uploadBytes = 500
        direct.downloadBytes = 1_000
        let sample = tracker.ingest(
            [direct, handoff],
            at: start.addingTimeInterval(2)
        )

        #expect(sample.direct.upload == 200)
        #expect(sample.direct.download == 400)
        #expect(sample.measured == sample.direct)
        #expect(sample.byRule["Direct app"] == sample.direct)
        #expect(sample.byRule["Handoff"] == nil)
    }

    @Test("Counter resets establish a new baseline instead of creating false traffic")
    func handlesCounterReset() {
        var tracker = AppRoutingTrafficRateTracker()
        let start = Date(timeIntervalSince1970: 2_000)
        var value = activity(upload: 1_000, download: 1_000)
        _ = tracker.ingest([value], at: start)
        value.uploadBytes = 10
        value.downloadBytes = 20

        let sample = tracker.ingest([value], at: start.addingTimeInterval(1))
        #expect(sample.measured.total == 0)
    }

    private func activity(
        id: UUID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        action: FlowTrafficDisposition = .mihomo(.profileRules),
        rule: String? = "Rule",
        measured: Bool = true,
        upload: UInt64,
        download: UInt64
    ) -> AppRoutingActivity {
        AppRoutingActivity(
            flowIdentifier: id,
            configurationRevision: 1,
            startedAt: Date(timeIntervalSince1970: 1_000),
            source: AppRoutingActivitySource(
                processIdentifier: 42,
                userIdentifier: 501,
                bundleIdentifier: "com.example.app"
            ),
            destination: AppRoutingActivityDestination(port: 443),
            transportProtocol: .tcp,
            decision: FlowTrafficDecision(
                disposition: action,
                reason: .rule(.matchedRule(rule ?? "Rule"))
            ),
            configuredAction: action.captureAction,
            effectiveAction: action,
            relayState: .relaying,
            payloadBytesAreMeasured: measured,
            uploadBytes: upload,
            downloadBytes: download
        )
    }
}

private extension FlowTrafficDisposition {
    var captureAction: CaptureAction {
        switch self {
        case .direct, .failOpen: .direct
        case .reject: .reject
        case let .mihomo(route): .mihomo(route)
        }
    }
}
