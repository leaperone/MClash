import Foundation
import MClashNetworkShared
@testable import MClashApp
import Testing

@Suite("App Routing rule evidence presentation")
struct AppRoutingRuleEvidencePresentationTests {
    @Test
    func signedApplicationAndEveryDestinationConditionAreExplained() throws {
        let evidence = CaptureRuleDecisionEvidence(
            outcome: .matchedRule,
            source: .application(RuleApplicationSourceEvidence(
                signingIdentifier: "com.example.browser",
                teamIdentifier: "TEAM",
                bundleIdentifier: "com.example.browser"
            )),
            destination: .host(RuleHostDestinationEvidence(
                kind: .suffix,
                value: "example.com"
            )),
            transportProtocol: .exact(.tcp),
            destinationPort: .range(try PortRange(443))
        )
        let presentation = AppRoutingRuleEvidencePresentation.make(for: activity(
            decision: FlowTrafficDecision(
                disposition: .mihomo(.profileRules),
                reason: .rule(.matchedRule("Browser")),
                ruleEvidence: evidence
            )
        ))

        #expect(presentation.summary.contains("exact alternatives"))
        #expect(presentation.rows.map(\.title) == ["Source", "Destination", "Protocol", "Port"])
        #expect(presentation.rows[0].value.contains("Exact signed application identity"))
        #expect(presentation.rows[1].value.contains("Host suffix example.com"))
        #expect(presentation.rows[2].value.contains("TCP"))
        #expect(presentation.rows[3].value.contains("443"))
        #expect(presentation.consequence == nil)
    }

    @Test
    func patternEvidenceNeverClaimsExactSignatureIdentity() {
        let evidence = CaptureRuleDecisionEvidence(
            outcome: .matchedRule,
            source: .applicationIdentifierPattern(RuleApplicationPatternEvidence(
                pattern: "com.example.*",
                matchedField: .bundleIdentifier
            )),
            destination: .unconstrained,
            transportProtocol: .unconstrained,
            destinationPort: .unconstrained
        )
        let presentation = AppRoutingRuleEvidencePresentation.make(for: activity(
            decision: FlowTrafficDecision(
                disposition: .direct,
                reason: .rule(.matchedRule("Pattern")),
                ruleEvidence: evidence
            )
        ))

        #expect(presentation.rows[0].value.contains("name/pattern match"))
        #expect(presentation.rows[0].value.contains("not an exact signature identity"))
    }

    @Test
    func contextUnavailableStatesTheFailOpenConsequence() {
        let presentation = AppRoutingRuleEvidencePresentation.make(for: activity(
            decision: FlowTrafficDecision(
                disposition: .failOpen,
                reason: .contextUnavailable(.identityUnavailable(.processNoLongerExists)),
                ruleEvidence: CaptureRuleDecisionEvidence(
                    outcome: .contextUnavailable,
                    contextUnavailableReason: .sourceIdentityResolutionFailed
                )
            )
        ))

        #expect(presentation.summary.contains("identity"))
        #expect(presentation.consequence?.contains("rules were not evaluated") == true)
        #expect(presentation.consequence?.contains("fail-open") == true)
    }

    @Test
    func defaultAndLegacyDecisionsAreNotPresentedAsRuleMatches() {
        let defaultPresentation = AppRoutingRuleEvidencePresentation.make(for: activity(
            decision: FlowTrafficDecision(
                disposition: .direct,
                reason: .rule(.defaultDirect),
                ruleEvidence: CaptureRuleDecisionEvidence(outcome: .defaultDirect)
            )
        ))
        #expect(defaultPresentation.summary == "No enabled App Routing rule matched this flow.")
        #expect(defaultPresentation.rows.isEmpty)

        let legacy = AppRoutingRuleEvidencePresentation.make(for: activity(
            decision: FlowTrafficDecision(
                disposition: .direct,
                reason: .rule(.matchedRule("Legacy"))
            )
        ))
        #expect(legacy.summary.contains("before detailed match evidence"))
    }

    private func activity(decision: FlowTrafficDecision) -> AppRoutingActivity {
        AppRoutingActivity(
            configurationRevision: 1,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: AppRoutingActivitySource(
                processIdentifier: 42,
                userIdentifier: 501,
                executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
                bundleIdentifier: "com.example.browser"
            ),
            destination: AppRoutingActivityDestination(
                hostname: "api.example.com",
                ipAddress: "203.0.113.4",
                port: 443
            ),
            transportProtocol: .tcp,
            decision: decision,
            configuredAction: .direct,
            effectiveAction: decision.disposition,
            relayState: .notApplicable
        )
    }
}
