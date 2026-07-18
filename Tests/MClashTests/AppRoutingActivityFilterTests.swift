import Foundation
@testable import MClashApp
import MClashNetworkShared
import Testing

@Suite("App Routing activity filter")
struct AppRoutingActivityFilterTests {
    @Test("Focused activity hides only ordinary Direct traffic")
    func focusedVisibility() {
        #expect(!AppRoutingActivityFilter.focused.includes(activity(
            configured: .direct,
            effective: .direct
        )))
        #expect(AppRoutingActivityFilter.focused.includes(activity(
            configured: .mihomo(.profileRules),
            effective: .direct
        )))
        #expect(AppRoutingActivityFilter.focused.includes(activity(
            configured: .direct,
            effective: .direct,
            relayState: .failed
        )))
        #expect(AppRoutingActivityFilter.focused.includes(activity(
            configured: .mihomo(.profileRules),
            effective: .mihomo(.profileRules)
        )))
        #expect(AppRoutingActivityFilter.focused.includes(activity(
            configured: .reject,
            effective: .reject
        )))
        #expect(AppRoutingActivityFilter.focused.includes(activity(
            configured: .direct,
            effective: .failOpen
        )))
    }

    @Test("Explicit filters can reveal Direct traffic")
    func explicitDirectVisibility() {
        let direct = activity(configured: .direct, effective: .direct)
        #expect(AppRoutingActivityFilter.all.includes(direct))
        #expect(AppRoutingActivityFilter.direct.includes(direct))
        #expect(!AppRoutingActivityFilter.viaMihomo.includes(direct))
    }

    private func activity(
        configured: CaptureAction,
        effective: FlowTrafficDisposition,
        relayState: AppRoutingRelayState = .completed
    ) -> AppRoutingActivity {
        AppRoutingActivity(
            configurationRevision: 1,
            startedAt: Date(timeIntervalSince1970: 1),
            source: AppRoutingActivitySource(processIdentifier: 42, userIdentifier: 501),
            destination: AppRoutingActivityDestination(hostname: "example.com", port: 443),
            transportProtocol: .tcp,
            decision: FlowTrafficDecision(
                disposition: effective,
                reason: .rule(.defaultDirect)
            ),
            configuredAction: configured,
            effectiveAction: effective,
            relayState: relayState
        )
    }
}
