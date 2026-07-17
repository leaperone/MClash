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
    func incompleteOrInconsistentIdentityFailsOpen() throws {
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
        #expect(missingToken == .failOpen(.missingSourceAppAuditToken))

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
        #expect(mismatchedSigningIdentifier == .failOpen(.signingIdentifierMismatch(
            metadata: "com.attacker.fake",
            resolved: "com.example.browser"
        )))

        let invalidPort = FlowContextBuilder().resolve(
            endpoint: FlowRemoteEndpoint(host: "example.com", port: "0"),
            metadata: metadata(),
            identityResolution: .resolved(identity),
            transportProtocol: .tcp
        )
        #expect(invalidPort == .failOpen(.invalidRemotePort("0")))
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
        ) == FlowTrafficDecision(disposition: .failOpen, reason: .captureDisabled))

        #expect(adapter.decide(
            configuration: .failOpen(.missingEncodedSnapshot),
            context: context,
            captureEnabled: true,
            mihomoAvailable: false
        ) == FlowTrafficDecision(
            disposition: .failOpen,
            reason: .configurationUnavailable(.missingEncodedSnapshot)
        ))

        #expect(adapter.decide(
            configuration: loaded,
            context: .failOpen(.missingSourceAppAuditToken),
            captureEnabled: true,
            mihomoAvailable: false
        ) == FlowTrafficDecision(
            disposition: .failOpen,
            reason: .contextUnavailable(.missingSourceAppAuditToken)
        ))
    }

    private func metadata() -> FlowApplicationMetadata {
        FlowApplicationMetadata(
            sourceAppAuditToken: auditTokenData,
            sourceAppUniqueIdentifier: Data([0x01]),
            sourceAppSigningIdentifier: "com.example.browser"
        )
    }

    private func signedIdentity() throws -> ResolvedProcessIdentity {
        ResolvedProcessIdentity(
            auditToken: try SourceAppAuditToken(auditTokenData),
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
