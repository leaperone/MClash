import MClashNetworkShared
import Testing
@testable import MClashNetworkExtension

@Suite("Initial flow ownership policy")
struct InitialFlowOwnershipPolicyTests {
    @Test("Direct and fail-open stay on the original macOS path")
    func passThroughDispositions() {
        #expect(!InitialFlowOwnershipPolicy.owns(.direct))
        #expect(!InitialFlowOwnershipPolicy.owns(.failOpen))
    }

    @Test("Reject and Mihomo decisions are intercepted")
    func interceptedDispositions() {
        #expect(InitialFlowOwnershipPolicy.owns(.reject))
        #expect(InitialFlowOwnershipPolicy.owns(.mihomo(.profileRules)))
    }

    @Test("Unavailable route applies its rule-specific fallback before ownership")
    func unavailableRouteFallback() throws {
        let directRule = try CaptureRule(
            id: "direct-fallback",
            priority: 0,
            action: .mihomo(.group("Streaming")),
            unavailableFallback: .direct
        )
        let rejectRule = try CaptureRule(
            id: "reject-fallback",
            priority: 1,
            action: .mihomo(.global),
            unavailableFallback: .reject
        )
        let rules = [directRule.id: directRule, rejectRule.id: rejectRule]

        let direct = MihomoRouteAvailabilityPolicy.resolve(
            decision(rule: directRule, route: .group("Streaming")),
            availableRoutes: [.profileRules],
            rulesByIdentifier: rules
        )
        let reject = MihomoRouteAvailabilityPolicy.resolve(
            decision(rule: rejectRule, route: .global),
            availableRoutes: [.profileRules],
            rulesByIdentifier: rules
        )

        #expect(direct.disposition == .direct)
        #expect(!InitialFlowOwnershipPolicy.owns(direct.disposition))
        #expect(reject.disposition == .reject)
        #expect(InitialFlowOwnershipPolicy.owns(reject.disposition))
    }

    @Test("Available route remains owned by Mihomo")
    func availableRoute() throws {
        let rule = try CaptureRule(
            id: "available",
            priority: 0,
            action: .mihomo(.profileRules)
        )
        let original = decision(rule: rule, route: .profileRules)

        let resolved = MihomoRouteAvailabilityPolicy.resolve(
            original,
            availableRoutes: [.profileRules],
            rulesByIdentifier: [rule.id: rule]
        )

        #expect(resolved == original)
    }

    private func decision(
        rule: CaptureRule,
        route: MihomoRoute
    ) -> FlowTrafficDecision {
        FlowTrafficDecision(
            disposition: .mihomo(route),
            reason: .rule(.matchedRule(rule.id))
        )
    }
}
