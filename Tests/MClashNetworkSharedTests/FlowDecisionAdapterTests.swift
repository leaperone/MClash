import Foundation
@testable import MClashNetworkShared
import Testing

@Suite("Flow conversion and traffic decisions")
struct FlowDecisionAdapterTests {
    private let auditTokenData = Data((0 ..< 32).map(UInt8.init))

    @Test
    func endpointAndMetadataProduceTrustedRuleContext() throws {
        let identity = try signedIdentity()
        let metadata = FlowApplicationMetadata(
            sourceAppAuditToken: auditTokenData,
            sourceAppUniqueIdentifier: Data([0xAA, 0xBB]),
            sourceAppSigningIdentifier: "com.example.browser"
        )
        let resolution = FlowContextBuilder().resolve(
            endpoint: FlowRemoteEndpoint(host: "203.0.113.9", port: "443"),
            remoteHostname: "api.example.com",
            metadata: metadata,
            identityResolution: .resolved(identity),
            transportProtocol: .tcp
        )

        let context = try #require(resolution.context)
        #expect(resolution.processIdentity == identity)
        #expect(context.destination.ipAddress == (try IPAddress("203.0.113.9")))
        #expect(context.destination.hostname == "api.example.com")
        #expect(context.destination.port == 443)
        #expect(context.transportProtocol == .tcp)
        #expect(context.source.processIdentifier == 321)
        #expect(context.source.userID == 501)
        #expect(context.source.sourceAppUniqueIdentifier == Data([0xAA, 0xBB]))
        #expect(context.source.designatedRequirement == "REQ")
        #expect(context.source.signingIdentifier == "com.example.browser")
        #expect(context.source.teamIdentifier == "TEAM")
        #expect(context.source.bundleIdentifier == "com.example.browser")
    }

    @Test
    func hostnameAndBracketedIPv6EndpointsAreNormalized() throws {
        let identity = try signedIdentity()
        let metadata = metadata()
        let hostname = FlowContextBuilder().resolve(
            endpoint: FlowRemoteEndpoint(host: "edge.example.com", port: 53),
            metadata: metadata,
            identityResolution: .resolved(identity),
            transportProtocol: .udp
        )
        #expect(hostname.context?.destination.hostname == "edge.example.com")
        #expect(hostname.context?.destination.ipAddress == nil)

        let ipv6 = FlowContextBuilder().resolve(
            endpoint: FlowRemoteEndpoint(host: "[2001:db8::5]", port: 8443),
            metadata: metadata,
            identityResolution: .resolved(identity),
            transportProtocol: .tcp
        )
        #expect(ipv6.context?.destination.ipAddress == (try IPAddress("2001:db8::5")))
    }

    @Test
    func incompleteOrInconsistentIdentityRetainsOnlyKernelMetadata() throws {
        let identity = try signedIdentity()
        let missingToken = FlowContextBuilder().resolve(
            endpoint: FlowRemoteEndpoint(host: "example.com", port: 443),
            metadata: FlowApplicationMetadata(
                sourceAppAuditToken: nil,
                sourceAppUniqueIdentifier: Data(),
                sourceAppSigningIdentifier: "com.example.browser"
            ),
            identityResolution: .resolved(identity),
            transportProtocol: .tcp
        )
        guard case let .kernelMetadataOnly(context, failure) = missingToken else {
            Issue.record("Missing audit token should retain bounded NE metadata")
            return
        }
        #expect(failure == .missingSourceAppAuditToken)
        #expect(context.source.signingIdentifier == "com.example.browser")
        #expect(context.source.designatedRequirement == nil)
        #expect(context.source.executablePath == nil)
        #expect(context.destination.hostname == "example.com")

        let mismatchedSigningIdentifier = FlowContextBuilder().resolve(
            endpoint: FlowRemoteEndpoint(host: "example.com", port: 443),
            metadata: FlowApplicationMetadata(
                sourceAppAuditToken: auditTokenData,
                sourceAppUniqueIdentifier: Data(),
                sourceAppSigningIdentifier: "com.attacker.fake"
            ),
            identityResolution: .resolved(identity),
            transportProtocol: .tcp
        )
        guard case let .kernelMetadataOnly(mismatchContext, mismatchFailure) = mismatchedSigningIdentifier else {
            Issue.record("Signing identity disagreement must not discard the destination context")
            return
        }
        #expect(mismatchFailure == .signingIdentifierMismatch(
            metadata: "com.attacker.fake",
            resolved: "com.example.browser"
        ))
        #expect(mismatchContext.source.signingIdentifier == "com.attacker.fake")
        #expect(mismatchContext.source.designatedRequirement == nil)

        let mismatchedAuditToken = FlowContextBuilder().resolve(
            endpoint: FlowRemoteEndpoint(host: "example.com", port: 443),
            metadata: metadata(),
            identityResolution: .resolved(try signedIdentity(
                auditTokenData: Data(repeating: 0xFF, count: SourceAppAuditToken.byteCount)
            )),
            transportProtocol: .tcp
        )
        guard case let .kernelMetadataOnly(auditContext, auditFailure) = mismatchedAuditToken else {
            Issue.record("Audit-token disagreement must not discard the destination context")
            return
        }
        #expect(auditFailure == .identityAuditTokenMismatch)
        #expect(auditContext.source.auditToken == auditTokenData)
        #expect(auditContext.source.processIdentifier == 0)

        let invalidPort = FlowContextBuilder().resolve(
            endpoint: FlowRemoteEndpoint(host: "example.com", port: "0"),
            metadata: metadata(),
            identityResolution: .resolved(identity),
            transportProtocol: .tcp
        )
        #expect(invalidPort == .failOpen(.invalidRemotePort("0")))
    }

    @Test("Identity EPERM still evaluates identifier and destination-only rules without trusting strict source fields")
    func unavailableIdentityUsesBoundedRuleEvaluation() throws {
        let failure = ProcessIdentityResolutionFailure.executablePathPermissionDenied(errno: 1)
        let context = FlowContextBuilder().resolve(
            endpoint: FlowRemoteEndpoint(host: "162.125.6.1", port: 443),
            remoteHostname: "chatgpt.com",
            metadata: FlowApplicationMetadata(
                sourceAppAuditToken: auditTokenData,
                sourceAppUniqueIdentifier: Data([0xCA, 0xFE]),
                sourceAppSigningIdentifier: "codex"
            ),
            identityResolution: .unavailable(failure),
            transportProtocol: .tcp
        )

        guard case let .kernelMetadataOnly(metadataContext, sourceFailure) = context else {
            Issue.record("An identity lookup failure should retain the usable flow context")
            return
        }
        #expect(sourceFailure == .identityUnavailable(failure))
        #expect(metadataContext.source.signingIdentifier == "codex")
        #expect(metadataContext.source.processIdentifier == 0)
        #expect(metadataContext.source.userID == 0)
        #expect(metadataContext.source.executablePath == nil)
        #expect(metadataContext.source.designatedRequirement == nil)

        let strictRule = try CaptureRule(
            id: "strict-source-must-not-match",
            priority: 1,
            sources: [.executable(ExecutableSourceMatcher(
                canonicalPath: "/Applications/Codex.app/Contents/Resources/codex"
            ))],
            destinations: [.host(try HostMatcher(kind: .exact, value: "chatgpt.com"))],
            action: .reject
        )
        let identifierRule = try CaptureRule(
            id: "kernel-app-identifier",
            priority: 2,
            sources: [.applicationIdentifierPattern(
                try ApplicationIdentifierPatternMatcher(pattern: "codex")
            )],
            destinations: [.host(try HostMatcher(kind: .exact, value: "chatgpt.com"))],
            protocols: [.tcp],
            portRanges: [try PortRange(lowerBound: 443, upperBound: 443)],
            action: .mihomo(.profileRules)
        )
        let configuration = CaptureConfigurationLoadResult.loaded(
            try CaptureConfigurationSnapshot(revision: 1, rules: [strictRule, identifierRule])
        )
        let decision = FlowTrafficDecisionAdapter().decide(
            configuration: configuration,
            context: context,
            captureEnabled: true,
            mihomoAvailable: true
        )

        #expect(decision.disposition == .mihomo(.profileRules))
        #expect(decision.reason == .rule(.matchedRule("kernel-app-identifier")))
        #expect(decision.ruleEvidence?.source == .applicationIdentifierPattern(
            RuleApplicationPatternEvidence(pattern: "codex", matchedField: .signingIdentifier)
        ))
    }

    @Test("Unavailable source identity skips constrained rules and continues to a destination-only rule")
    func unavailableIdentityDoesNotInvalidateDestinationOnlyRules() throws {
        let context = FlowContextBuilder().resolve(
            endpoint: FlowRemoteEndpoint(host: "203.0.113.40", port: 443),
            remoteHostname: "chatgpt.com",
            metadata: metadata(),
            identityResolution: .unavailable(.codeObjectLookupFailed(status: -1)),
            transportProtocol: .tcp
        )
        let unavailableSourceRule = try CaptureRule(
            id: "requires-verified-source",
            priority: 1,
            sources: [.executable(ExecutableSourceMatcher(
                canonicalPath: "/Applications/Browser.app/Contents/MacOS/Browser"
            ))],
            action: .reject
        )
        let destinationRule = try CaptureRule(
            id: "domain-only",
            priority: 2,
            destinations: [.host(try HostMatcher(kind: .suffix, value: "chatgpt.com"))],
            protocols: [.tcp],
            portRanges: [try PortRange(lowerBound: 443, upperBound: 443)],
            action: .mihomo(.profileRules)
        )
        let decision = FlowTrafficDecisionAdapter().decide(
            configuration: .loaded(try CaptureConfigurationSnapshot(
                revision: 1,
                rules: [unavailableSourceRule, destinationRule]
            )),
            context: context,
            captureEnabled: true,
            mihomoAvailable: true
        )

        #expect(decision.disposition == .mihomo(.profileRules))
        #expect(decision.reason == .rule(.matchedRule("domain-only")))
        #expect(decision.ruleEvidence?.source == .unconstrained)
        #expect(decision.ruleEvidence?.destination == .host(
            RuleHostDestinationEvidence(kind: .suffix, value: "chatgpt.com")
        ))
    }

    @Test("An existing exact application rule can fall back to its configured signing identifier")
    func unavailableIdentityMatchesConfiguredApplicationIdentifier() throws {
        let context = FlowContextBuilder().resolve(
            endpoint: FlowRemoteEndpoint(host: "162.125.6.1", port: 443),
            remoteHostname: "chatgpt.com",
            metadata: FlowApplicationMetadata(
                sourceAppAuditToken: auditTokenData,
                sourceAppUniqueIdentifier: Data([0xCA, 0xFE]),
                sourceAppSigningIdentifier: "codex"
            ),
            identityResolution: .unavailable(.codeObjectLookupFailed(status: -1)),
            transportProtocol: .tcp
        )
        let applicationRule = try CaptureRule(
            id: "existing-codex-application",
            priority: 1,
            sources: [.application(ApplicationSourceMatcher(
                designatedRequirement: "stored requirement unavailable at runtime",
                signingIdentifier: "codex"
            ))],
            destinations: [.host(try HostMatcher(kind: .suffix, value: "chatgpt.com"))],
            action: .mihomo(.profileRules)
        )

        let decision = FlowTrafficDecisionAdapter().decide(
            configuration: .loaded(try CaptureConfigurationSnapshot(
                revision: 1,
                rules: [applicationRule]
            )),
            context: context,
            captureEnabled: true,
            mihomoAvailable: true
        )

        #expect(decision.disposition == .mihomo(.profileRules))
        #expect(decision.reason == .rule(.matchedRule("existing-codex-application")))
        #expect(decision.ruleEvidence?.source == .applicationIdentifierPattern(
            RuleApplicationPatternEvidence(pattern: "codex", matchedField: .signingIdentifier)
        ))
    }

    @Test
    func snapshotLoaderAcceptsValidatedDefaultAndISO8601Data() throws {
        let snapshot = try CaptureConfigurationSnapshot(
            revision: 8,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            rules: [try CaptureRule(id: "all", priority: 1, action: .direct)]
        )
        let defaultData = try JSONEncoder().encode(snapshot)
        #expect(CaptureConfigurationSnapshotLoader().load(defaultData).snapshot == snapshot)

        let isoEncoder = JSONEncoder()
        isoEncoder.dateEncodingStrategy = .iso8601
        let isoData = try isoEncoder.encode(snapshot)
        #expect(CaptureConfigurationSnapshotLoader().load(isoData).snapshot == snapshot)
        #expect(CaptureConfigurationSnapshotLoader().load(nil) == .failOpen(.missingEncodedSnapshot))

        var object = try #require(JSONSerialization.jsonObject(with: defaultData) as? [String: Any])
        object["schemaVersion"] = 99
        let invalidData = try JSONSerialization.data(withJSONObject: object)
        guard case .failOpen(.invalidEncodedSnapshot) = CaptureConfigurationSnapshotLoader().load(invalidData) else {
            Issue.record("An invalid schema must fail open")
            return
        }
    }

    @Test
    func rulesMapToDirectRejectMihomoAndExplicitFallback() throws {
        let context = try resolvedContext()
        let adapter = FlowTrafficDecisionAdapter()

        let direct = adapter.decide(
            configuration: try loaded(action: .direct),
            context: context,
            captureEnabled: true,
            mihomoAvailable: true
        )
        #expect(direct.disposition == .direct)
        #expect(direct.reason == .rule(.matchedRule("rule")))

        let reject = adapter.decide(
            configuration: try loaded(action: .reject),
            context: context,
            captureEnabled: true,
            mihomoAvailable: true
        )
        #expect(reject.disposition == .reject)

        let mihomo = adapter.decide(
            configuration: try loaded(action: .mihomo(.group("HK"))),
            context: context,
            captureEnabled: true,
            mihomoAvailable: true
        )
        #expect(mihomo.disposition == .mihomo(.group("HK")))

        let unavailable = adapter.decide(
            configuration: try loaded(
                action: .mihomo(.profileRules),
                unavailableFallback: .reject
            ),
            context: context,
            captureEnabled: true,
            mihomoAvailable: false
        )
        #expect(unavailable.disposition == .reject)
        #expect(unavailable.reason == .mihomoUnavailable(
            rule: .matchedRule("rule"),
            fallback: .reject
        ))
        #expect(unavailable.ruleEvidence?.outcome == .matchedRule)
        #expect(unavailable.ruleEvidence?.source == .unconstrained)
        #expect(unavailable.ruleEvidence?.destination == .unconstrained)
    }

    @Test("A prepared configuration reuses its compiled engine across flow decisions")
    func preparedConfigurationIsReusable() throws {
        let prepared = PreparedCaptureConfiguration(
            try loaded(action: .mihomo(.profileRules), unavailableFallback: .reject)
        )
        #expect(prepared.containsCompiledRuleEngine)

        let adapter = FlowTrafficDecisionAdapter()
        let context = try resolvedContext()
        for _ in 0 ..< 32 {
            let decision = adapter.decide(
                preparedConfiguration: prepared,
                context: context,
                captureEnabled: true,
                mihomoAvailable: false
            )
            #expect(decision.disposition == .reject)
        }
    }

    @Test
    func disabledInvalidConfigurationAndContextAreDistinctFailOpenReasons() throws {
        let adapter = FlowTrafficDecisionAdapter()
        let context = try resolvedContext()
        let loaded = try loaded(action: .direct)

        #expect(adapter.decide(
            configuration: loaded,
            context: context,
            captureEnabled: false,
            mihomoAvailable: false
        ) == FlowTrafficDecision(
            disposition: .failOpen,
            reason: .captureDisabled,
            ruleEvidence: CaptureRuleDecisionEvidence(outcome: .captureDisabled)
        ))

        #expect(adapter.decide(
            configuration: .failOpen(.missingEncodedSnapshot),
            context: context,
            captureEnabled: true,
            mihomoAvailable: false
        ) == FlowTrafficDecision(
            disposition: .failOpen,
            reason: .configurationUnavailable(.missingEncodedSnapshot),
            ruleEvidence: CaptureRuleDecisionEvidence(outcome: .configurationUnavailable)
        ))

        #expect(adapter.decide(
            configuration: loaded,
            context: .failOpen(.missingSourceAppAuditToken),
            captureEnabled: true,
            mihomoAvailable: false
        ) == FlowTrafficDecision(
            disposition: .failOpen,
            reason: .contextUnavailable(.missingSourceAppAuditToken),
            ruleEvidence: CaptureRuleDecisionEvidence(
                outcome: .contextUnavailable,
                contextUnavailableReason: .missingSourceApplicationAuditToken
            )
        ))
    }

    @Test
    func contextFailuresAreClassifiedWithoutCopyingSensitiveValuesIntoEvidence() throws {
        let adapter = FlowTrafficDecisionAdapter()
        let decision = adapter.decide(
            configuration: try loaded(action: .direct),
            context: .failOpen(.signingIdentifierMismatch(
                metadata: "potentially-long-untrusted-value",
                resolved: "verified-value"
            )),
            captureEnabled: true,
            mihomoAvailable: true
        )

        #expect(decision.ruleEvidence == CaptureRuleDecisionEvidence(
            outcome: .contextUnavailable,
            contextUnavailableReason: .sourceSigningIdentifierMismatch
        ))
        let evidenceJSON = String(
            decoding: try JSONEncoder().encode(decision.ruleEvidence),
            as: UTF8.self
        )
        #expect(!evidenceJSON.contains("potentially-long-untrusted-value"))
        #expect(!evidenceJSON.contains("verified-value"))
    }

    private func metadata() -> FlowApplicationMetadata {
        FlowApplicationMetadata(
            sourceAppAuditToken: auditTokenData,
            sourceAppUniqueIdentifier: Data([0x01]),
            sourceAppSigningIdentifier: "com.example.browser"
        )
    }

    private func signedIdentity(auditTokenData: Data? = nil) throws -> ResolvedProcessIdentity {
        ResolvedProcessIdentity(
            auditToken: try SourceAppAuditToken(auditTokenData ?? self.auditTokenData),
            processIdentifier: 321,
            processVersion: 4,
            effectiveUserID: 501,
            auditUserID: 501,
            executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
            codeSigning: .signed(SignedCodeIdentity(
                signingIdentifier: "com.example.browser",
                teamIdentifier: "TEAM",
                designatedRequirement: "REQ",
                codeDirectoryHash: Data([0x01]),
                securedBundleIdentifier: "com.example.browser",
                mainExecutablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
                isApplePlatformCode: false
            ))
        )
    }

    private func resolvedContext() throws -> FlowContextResolution {
        FlowContextBuilder().resolve(
            endpoint: FlowRemoteEndpoint(host: "203.0.113.10", port: 443),
            metadata: metadata(),
            identityResolution: .resolved(try signedIdentity()),
            transportProtocol: .tcp
        )
    }

    private func loaded(
        action: CaptureAction,
        unavailableFallback: UnavailableFallback = .direct
    ) throws -> CaptureConfigurationLoadResult {
        .loaded(try CaptureConfigurationSnapshot(
            revision: 1,
            rules: [try CaptureRule(
                id: "rule",
                priority: 1,
                action: action,
                unavailableFallback: unavailableFallback
            )]
        ))
    }
}
