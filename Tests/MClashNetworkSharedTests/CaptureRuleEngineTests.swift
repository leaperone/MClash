import Foundation
@testable import MClashNetworkShared
import Testing

@Suite("Capture rule engine")
struct CaptureRuleEngineTests {
    private let auditToken = Data((0 ..< 32).map(UInt8.init))

    @Test
    func testFieldsUseANDAndMatchersWithinAFieldUseOR() throws {
        let rule = try CaptureRule(
            id: "browser-https",
            priority: 100,
            sources: [
                .application(ApplicationSourceMatcher(
                    designatedRequirement: "anchor apple generic and identifier Safari",
                    signingIdentifier: "com.apple.Safari"
                )),
                .userID(501),
            ],
            destinations: [
                .network(try IPNetwork("203.0.113.0/24")),
                .host(try HostMatcher(kind: .suffix, value: "example.com")),
            ],
            protocols: [.tcp],
            portRanges: [try PortRange(443)],
            action: .mihomo(.group("HK")),
            unavailableFallback: .reject
        )
        let engine = try engine([rule])

        let matching = try context(
            userID: 501,
            hostname: "api.example.com",
            ipAddress: "203.0.113.5",
            port: 443,
            transport: .tcp
        )
        let matchingDecision = engine.evaluate(matching)
        #expect(matchingDecision.action == .mihomo(.group("HK")))
        #expect(matchingDecision.unavailableFallback == .reject)
        #expect(matchingDecision.evidence == CaptureRuleDecisionEvidence(
            outcome: .matchedRule,
            source: .userID(501),
            destination: .network(try IPNetwork("203.0.113.0/24")),
            transportProtocol: .exact(.tcp),
            destinationPort: .range(try PortRange(443))
        ))

        let wrongProtocol = try context(userID: 501, ipAddress: "203.0.113.5", port: 443, transport: .udp)
        #expect(engine.evaluate(wrongProtocol).cause == .defaultDirect)

        let wrongPort = try context(userID: 501, ipAddress: "203.0.113.5", port: 80, transport: .tcp)
        #expect(engine.evaluate(wrongPort).cause == .defaultDirect)
    }

    @Test
    func testApplicationAndDomainGroupMustBothMatch() throws {
        let application = ApplicationSourceMatcher(
            designatedRequirement: "REQ",
            signingIdentifier: "com.example.openai",
            bundleIdentifier: "com.example.openai"
        )
        let rule = try CaptureRule(
            id: "openai",
            priority: 1,
            sources: [.application(application)],
            destinations: [
                .host(try HostMatcher(kind: .suffix, value: "openai.com")),
                .host(try HostMatcher(kind: .suffix, value: "oaistatic.com")),
            ],
            action: .mihomo(.profileRules)
        )
        let engine = try engine([rule])
        let matchingApplication = source(
            designatedRequirement: "REQ",
            signingIdentifier: "com.example.openai",
            bundleIdentifier: "com.example.openai"
        )

        #expect(engine.evaluate(try context(
            source: matchingApplication,
            hostname: "api.openai.com"
        )).action == .mihomo(.profileRules))
        #expect(engine.evaluate(try context(
            source: matchingApplication,
            hostname: "cdn.oaistatic.com"
        )).action == .mihomo(.profileRules))
        #expect(engine.evaluate(try context(
            source: matchingApplication,
            hostname: "example.com"
        )).cause == .defaultDirect)
        #expect(engine.evaluate(try context(
            source: source(bundleIdentifier: "com.example.other"),
            hostname: "api.openai.com"
        )).cause == .defaultDirect)
    }

    @Test
    func testDomainOnlyRuleMatchesEveryNonBypassedApplication() throws {
        let rule = try CaptureRule(
            id: "all-apps-openai",
            priority: 1,
            destinations: [.host(try HostMatcher(kind: .suffix, value: "openai.com"))],
            action: .reject
        )
        let engine = try engine([rule])

        #expect(engine.evaluate(try context(
            source: source(bundleIdentifier: "com.example.first"),
            hostname: "api.openai.com"
        )).action == .reject)
        #expect(engine.evaluate(try context(
            source: source(bundleIdentifier: "com.example.second"),
            hostname: "chat.openai.com"
        )).action == .reject)
        #expect(engine.evaluate(try context(
            source: source(isTrustedMClashComponent: true),
            hostname: "api.openai.com"
        )).cause == .builtInBypass(.trustedMClashComponent))
    }

    @Test
    func testApplicationIdentityRequiresDesignatedRequirementAndSpecifiedFields() throws {
        let matcher = ApplicationSourceMatcher(
            designatedRequirement: "REQ",
            signingIdentifier: "com.example.browser",
            teamIdentifier: "TEAM",
            bundleIdentifier: "com.example.browser"
        )
        let rule = try CaptureRule(
            id: "signed-app",
            priority: 1,
            sources: [.application(matcher)],
            action: .reject
        )
        let engine = try engine([rule])

        let validSource = source(
            designatedRequirement: "REQ",
            signingIdentifier: "com.example.browser",
            teamIdentifier: "TEAM",
            bundleIdentifier: "com.example.browser"
        )
        #expect(engine.evaluate(try context(source: validSource)).action == .reject)

        let spoofedIdentifier = source(
            designatedRequirement: "ATTACKER_REQ",
            signingIdentifier: "com.example.browser",
            teamIdentifier: "TEAM",
            bundleIdentifier: "com.example.browser"
        )
        #expect(engine.evaluate(try context(source: spoofedIdentifier)).cause == .defaultDirect)
    }

    @Test
    func testApplicationIdentifierWildcardsMatchBundleIDSigningIDOrExecutableName() throws {
        let matcher = try ApplicationIdentifierPatternMatcher(pattern: "com.google.*")
        let rule = try CaptureRule(
            id: "google-apps",
            priority: 1,
            sources: [.applicationIdentifierPattern(matcher)],
            action: .mihomo(.profileRules)
        )
        let engine = try engine([rule])

        let matchingBundle = source(bundleIdentifier: "com.google.Chrome")
        #expect(engine.evaluate(try context(source: matchingBundle)).action == .mihomo(.profileRules))

        let unrelated = source(
            executablePath: "/Applications/Safari.app/Contents/MacOS/Safari",
            signingIdentifier: "com.apple.Safari",
            bundleIdentifier: "com.apple.Safari"
        )
        #expect(engine.evaluate(try context(source: unrelated)).cause == .defaultDirect)

        let executableMatcher = try ApplicationIdentifierPatternMatcher(pattern: "*helper?")
        #expect(executableMatcher.matches("BackgroundHelper1"))
        #expect(!executableMatcher.matches("BackgroundHelper"))
    }

    @Test
    func testExecutableAndTemporaryProcessMatchers() throws {
        let executableRule = try CaptureRule(
            id: "cli",
            priority: 1,
            sources: [.executable(ExecutableSourceMatcher(
                canonicalPath: "/opt/tools/client",
                designatedRequirement: "REQ",
                sha256: "AABB"
            ))],
            action: .mihomo(.profileRules)
        )
        let processRule = try CaptureRule(
            id: "instance",
            priority: 2,
            sources: [.processInstance(ProcessInstanceSourceMatcher(processIdentifier: 42, auditToken: auditToken))],
            action: .reject
        )
        let engine = try engine([executableRule, processRule])

        let executable = source(
            processIdentifier: 100,
            executablePath: "/opt/tools/client",
            executableSHA256: "aabb",
            designatedRequirement: "REQ"
        )
        #expect(engine.evaluate(try context(source: executable)).action == .mihomo(.profileRules))

        let process = source(processIdentifier: 42)
        #expect(engine.evaluate(try context(source: process)).action == .reject)

        let reusedPID = source(processIdentifier: 42, auditToken: Data(repeating: 9, count: 32))
        #expect(engine.evaluate(try context(source: reusedPID)).cause == .defaultDirect)
    }

    @Test
    func testHostSelectedProcessInstanceRejectsPIDReuse() throws {
        let startTime = try ProcessStartTime(seconds: 1_700_000_000, microseconds: 42)
        let matcher = ProcessInstanceSourceMatcher(
            processIdentifier: 77,
            startTime: startTime,
            canonicalExecutablePath: "/Applications/Browser.app/Contents/MacOS/Browser"
        )
        let rule = try CaptureRule(
            id: "one-execution",
            priority: 1,
            sources: [.processInstance(matcher)],
            action: .reject
        )
        let engine = try engine([rule])

        let selectedExecution = source(
            processIdentifier: 77,
            processStartTime: startTime,
            executablePath: matcher.canonicalExecutablePath
        )
        let selectedDecision = engine.evaluate(try context(source: selectedExecution))
        #expect(selectedDecision.action == .reject)
        #expect(selectedDecision.evidence?.source == .processInstance(
            RuleProcessInstanceSourceEvidence(
                processIdentifier: 77,
                canonicalExecutablePath: matcher.canonicalExecutablePath,
                assurance: .exactProcessStartTimeAndExecutablePath
            )
        ))

        let reusedStartTime = try ProcessStartTime(seconds: 1_700_000_001, microseconds: 42)
        let reusedPID = source(
            processIdentifier: 77,
            processStartTime: reusedStartTime,
            executablePath: matcher.canonicalExecutablePath
        )
        #expect(engine.evaluate(try context(source: reusedPID)).cause == .defaultDirect)
    }

    @Test
    func testLowestPriorityValueWinsAndEqualPriorityIsStable() throws {
        let later = try CaptureRule(id: "later", priority: 20, action: .reject)
        let firstSamePriority = try CaptureRule(id: "first-same", priority: 10, action: .mihomo(.global))
        let secondSamePriority = try CaptureRule(id: "second-same", priority: 10, action: .direct)
        let engine = try engine([later, firstSamePriority, secondSamePriority])

        let decision = engine.evaluate(try context())
        #expect(decision.action == .mihomo(.global))
        #expect(decision.cause == .matchedRule("first-same"))
    }

    @Test
    func testDisabledRulesAreSkipped() throws {
        let disabled = try CaptureRule(id: "disabled", enabled: false, priority: 0, action: .reject)
        let enabled = try CaptureRule(id: "enabled", priority: 1, action: .mihomo(.profileRules))
        let decision = try engine([disabled, enabled]).evaluate(context())
        #expect(decision.cause == .matchedRule("enabled"))
    }

    @Test
    func testBuiltInTrustedComponentBypassCannotBeOverridden() throws {
        let rejectAll = try CaptureRule(id: "reject-all", priority: Int.min, action: .reject)
        let trusted = source(isTrustedMClashComponent: true)
        let decision = try engine([rejectAll]).evaluate(context(source: trusted))

        #expect(decision.action == .direct)
        #expect(decision.unavailableFallback == .direct)
        #expect(decision.cause == .builtInBypass(.trustedMClashComponent))
    }

    @Test
    func testBuiltInAddressBypassesCannotBeOverridden() throws {
        let rejectAll = try CaptureRule(id: "reject-all", priority: Int.min, action: .reject)
        let engine = try engine([rejectAll])

        #expect(engine.evaluate(try context(ipAddress: "127.0.0.1")).cause == .builtInBypass(.loopback))
        #expect(engine.evaluate(try context(ipAddress: "fe80::1")).cause == .builtInBypass(.linkLocal))
        #expect(engine.evaluate(try context(ipAddress: "ff02::1")).cause == .builtInBypass(.multicast))
        #expect(engine.evaluate(try context(ipAddress: "0.0.0.0")).cause == .builtInBypass(.unspecifiedAddress))
    }

    @Test
    func testHostnameMatcherCanMatchWhenResolvedAddressIsUnavailable() throws {
        let rule = try CaptureRule(
            id: "domain",
            priority: 1,
            destinations: [.host(try HostMatcher(kind: .suffix, value: "example.com"))],
            action: .mihomo(.profileRules)
        )
        let destination = try FlowDestination(hostname: "api.example.com", port: 443)
        let flow = FlowContext(source: source(), destination: destination, transportProtocol: .tcp)
        let decision = try engine([rule]).evaluate(flow)
        #expect(decision.cause == .matchedRule("domain"))
        #expect(decision.evidence?.destination == .host(RuleHostDestinationEvidence(
            kind: .suffix,
            value: "example.com"
        )))

        let exactIPRule = try CaptureRule(
            id: "exact-ip",
            priority: 1,
            destinations: [.ip(try IPAddress("203.0.113.8"))],
            action: .direct
        )
        let exactIPDecision = try engine([exactIPRule]).evaluate(context())
        #expect(exactIPDecision.evidence?.destination == .ip(try IPAddress("203.0.113.8")))
    }

    @Test
    func testEvidenceDistinguishesSignedPatternPathProcessAndUserIdentity() throws {
        let signedRule = try CaptureRule(
            id: "signed",
            priority: 1,
            sources: [.application(ApplicationSourceMatcher(
                designatedRequirement: "SECRET REQUIREMENT",
                signingIdentifier: "com.example.browser",
                teamIdentifier: "TEAM",
                bundleIdentifier: "com.example.browser"
            ))],
            action: .direct
        )
        let signedDecision = try engine([signedRule]).evaluate(context(source: source(
            designatedRequirement: "SECRET REQUIREMENT",
            signingIdentifier: "com.example.browser",
            teamIdentifier: "TEAM",
            bundleIdentifier: "com.example.browser"
        )))
        let signedEvidence = try #require(signedDecision.evidence?.source)
        #expect(signedEvidence.identityAssurance == .verifiedCodeSignatureRequirement)
        guard case let .application(application) = signedEvidence else {
            Issue.record("Expected signed application evidence")
            return
        }
        #expect(application.bundleIdentifier == "com.example.browser")

        let patternRule = try CaptureRule(
            id: "pattern",
            priority: 1,
            sources: [.applicationIdentifierPattern(
                try ApplicationIdentifierPatternMatcher(pattern: "browser*")
            )],
            action: .direct
        )
        let patternDecision = try engine([patternRule]).evaluate(context(source: source(
            executablePath: "/Applications/BrowserHelper.app/Contents/MacOS/BrowserWorker"
        )))
        #expect(patternDecision.evidence?.source == .applicationIdentifierPattern(
            RuleApplicationPatternEvidence(
                pattern: "browser*",
                matchedField: .executableName
            )
        ))

        let pathRule = try CaptureRule(
            id: "path",
            priority: 1,
            sources: [.executable(ExecutableSourceMatcher(
                canonicalPath: "/opt/browser",
                designatedRequirement: "SECRET REQUIREMENT",
                sha256: "AABB"
            ))],
            action: .direct
        )
        let pathDecision = try engine([pathRule]).evaluate(context(source: source(
            executablePath: "/opt/browser",
            executableSHA256: "aabb",
            designatedRequirement: "SECRET REQUIREMENT"
        )))
        #expect(pathDecision.evidence?.source == .executable(RuleExecutableSourceEvidence(
            canonicalPath: "/opt/browser",
            assurance: .exactExecutablePathCodeSignatureRequirementAndSHA256
        )))

        let processRule = try CaptureRule(
            id: "process",
            priority: 1,
            sources: [.processInstance(ProcessInstanceSourceMatcher(
                processIdentifier: 42,
                auditToken: auditToken
            ))],
            action: .direct
        )
        let processDecision = try engine([processRule]).evaluate(context())
        #expect(processDecision.evidence?.source == .processInstance(
            RuleProcessInstanceSourceEvidence(
                processIdentifier: 42,
                canonicalExecutablePath: nil,
                assurance: .exactAuditToken
            )
        ))
    }

    @Test
    func testDefaultAndBuiltInBypassHaveExplicitEvidence() throws {
        let noMatch = try CaptureRule(
            id: "udp-only",
            priority: 1,
            protocols: [.udp],
            action: .reject
        )
        let defaultDecision = try engine([noMatch]).evaluate(context(transport: .tcp))
        #expect(defaultDecision.evidence == CaptureRuleDecisionEvidence(outcome: .defaultDirect))

        let bypassDecision = try engine([
            try CaptureRule(id: "reject", priority: 1, action: .reject)
        ]).evaluate(context(ipAddress: "127.0.0.1"))
        #expect(bypassDecision.evidence == CaptureRuleDecisionEvidence(
            outcome: .builtInBypass,
            builtInBypassReason: .loopback
        ))
    }

    @Test
    func testEvidenceBoundsStringsAndOmitsSecretIdentityMaterial() throws {
        let longIdentifier = String(repeating: "a", count: 2_000)
        let rule = try CaptureRule(
            id: "bounded",
            priority: 1,
            sources: [.application(ApplicationSourceMatcher(
                designatedRequirement: "not-a-telemetry-secret",
                signingIdentifier: longIdentifier
            ))],
            action: .direct
        )
        let decision = try engine([rule]).evaluate(context(source: source(
            designatedRequirement: "not-a-telemetry-secret",
            signingIdentifier: longIdentifier
        )))
        guard case let .application(application) = decision.evidence?.source else {
            Issue.record("Expected application evidence")
            return
        }
        #expect(application.signingIdentifier?.count == 255)
        let json = String(decoding: try JSONEncoder().encode(decision.evidence), as: UTF8.self)
        #expect(!json.contains("not-a-telemetry-secret"))
        #expect(!json.contains("auditToken"))
        #expect(!json.contains("sha256"))
    }

    private func engine(_ rules: [CaptureRule]) throws -> CaptureRuleEngine {
        CaptureRuleEngine(snapshot: try CaptureConfigurationSnapshot(revision: 1, rules: rules))
    }

    private func source(
        processIdentifier: Int32 = 42,
        auditToken: Data? = nil,
        processStartTime: ProcessStartTime? = nil,
        userID: UInt32 = 501,
        executablePath: String? = nil,
        executableSHA256: String? = nil,
        designatedRequirement: String? = nil,
        signingIdentifier: String? = nil,
        teamIdentifier: String? = nil,
        bundleIdentifier: String? = nil,
        isTrustedMClashComponent: Bool = false
    ) -> FlowSource {
        FlowSource(
            processIdentifier: processIdentifier,
            auditToken: auditToken ?? self.auditToken,
            processStartTime: processStartTime,
            userID: userID,
            executablePath: executablePath,
            executableSHA256: executableSHA256,
            designatedRequirement: designatedRequirement,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            bundleIdentifier: bundleIdentifier,
            isTrustedMClashComponent: isTrustedMClashComponent
        )
    }

    private func context(
        source: FlowSource? = nil,
        userID: UInt32 = 501,
        hostname: String? = nil,
        ipAddress: String? = "203.0.113.8",
        port: UInt16 = 443,
        transport: TransportProtocol = .tcp
    ) throws -> FlowContext {
        FlowContext(
            source: source ?? self.source(userID: userID),
            destination: try FlowDestination(
                hostname: hostname,
                ipAddress: try ipAddress.map(IPAddress.init),
                port: port
            ),
            transportProtocol: transport
        )
    }
}
