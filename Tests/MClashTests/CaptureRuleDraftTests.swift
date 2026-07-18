import Darwin
import Foundation
@testable import MClashApp
import MClashNetworkShared
import Testing

@Suite("Capture rule draft")
struct CaptureRuleDraftTests {
    @Test("Running process discovery stays off the main actor and includes non-GUI instances")
    func discoversCurrentProcess() async throws {
        let candidates = await Task.detached(priority: .userInitiated) {
            ApplicationCaptureCandidateProvider().runningProcesses(from: [])
        }.value
        let candidate = try #require(
            candidates.first(where: { $0.processIdentifier == getpid() })
        )
        #expect(candidate.executablePath.hasPrefix("/"))
        #expect(candidate.matcher.auditToken == nil)
        #expect(candidate.matcher.startTime != nil)
    }

    @Test("Application, executable, UID, destination, transport, port, action, and fallback compose")
    func composesCompleteTargetedRule() throws {
        let candidate = makeCandidate()
        var draft = CaptureRuleDraft(
            identifier: " browser-secure ",
            enabled: true,
            priority: 10,
            selectedApplication: candidate,
            userID: "501",
            networkInput: "203.0.113.8",
            matchesTCP: true,
            matchesUDP: false,
            portRange: "443",
            action: .mihomoProfileRules,
            unavailableFallback: .reject
        )
        draft.useSelectedApplicationExecutable()

        let rule = try draft.makeRule()

        #expect(rule.id == "browser-secure")
        #expect(rule.enabled)
        #expect(rule.priority == 10)
        #expect(rule.protocols == [.tcp])
        #expect(rule.portRanges == [try PortRange(443)])
        #expect(rule.action == .mihomo(.profileRules))
        #expect(rule.unavailableFallback == .reject)
        #expect(rule.destinations == [.ip(try IPAddress("203.0.113.8"))])
        #expect(rule.sources.count == 3)
        #expect(rule.sources.contains(.application(candidate.matcher)))
        #expect(rule.sources.contains(.userID(501)))

        let executable = try #require(rule.sources.compactMap { source in
            if case let .executable(value) = source { value } else { nil }
        }.first)
        #expect(executable.canonicalPath == candidate.executablePath)
        #expect(executable.designatedRequirement == candidate.matcher.designatedRequirement)
    }

    @Test("Domain groups, IPs, and CIDRs normalize and deduplicate")
    func normalizesDestinationMatchers() throws {
        let draft = CaptureRuleDraft(
            identifier: "openai",
            domainInput: "Example.COM., *.api.example.com; =login.example.com\nexample.com",
            networkInput: "192.0.2.99/24, 203.0.113.8 203.0.113.8"
        )

        let rule = try draft.makeRule()
        #expect(rule.sources.isEmpty)
        #expect(rule.destinations == [
            .host(try HostMatcher(kind: .suffix, value: "example.com")),
            .host(try HostMatcher(kind: .suffix, value: "api.example.com")),
            .host(try HostMatcher(kind: .exact, value: "login.example.com")),
            .network(try IPNetwork("192.0.2.0/24")),
            .ip(try IPAddress("203.0.113.8")),
        ])
    }

    @Test("Application identifier wildcard becomes a source matcher")
    func applicationIdentifierPattern() throws {
        let draft = CaptureRuleDraft(
            identifier: "browser-family",
            applicationIdentifierPattern: " COM.GOOGLE.* "
        )

        #expect(
            try draft.makeRule().sources
                == [.applicationIdentifierPattern(
                    ApplicationIdentifierPatternMatcher(pattern: "com.google.*")
                )]
        )
    }

    @Test("Multiple application and hostname wildcard patterns round-trip")
    func multipleImportedPatternsRoundTrip() throws {
        let rule = try CaptureRule(
            id: "imported",
            priority: 10,
            sources: [
                .applicationIdentifierPattern(
                    try ApplicationIdentifierPatternMatcher(pattern: "example app")
                ),
                .applicationIdentifierPattern(
                    try ApplicationIdentifierPatternMatcher(pattern: "com.example.*")
                ),
            ],
            destinations: [
                .hostPattern(try HostPatternMatcher(pattern: "*example.com")),
            ],
            protocols: [.tcp],
            action: .mihomo(.profileRules)
        )

        let draft = try CaptureRuleDraft(rule: rule)
        #expect(draft.applicationIdentifierPattern == "example app; com.example.*")
        #expect(try draft.makeRule() == rule)
    }

    @Test("Single ports and inclusive ranges map to PortRange")
    func parsesPortRanges() throws {
        var draft = CaptureRuleDraft(identifier: "ports", matchesTCP: true, matchesUDP: false)

        draft.portRange = "53"
        #expect(try draft.makeRule().portRanges == [PortRange(53)])

        draft.portRange = " 8000 - 9000 "
        #expect(
            try draft.makeRule().portRanges == [PortRange(lowerBound: 8_000, upperBound: 9_000)]
        )

        draft.portRange = "53; 443, 8000-9000; 53"
        #expect(try draft.makeRule().portRanges == [
            PortRange(53),
            PortRange(443),
            PortRange(lowerBound: 8_000, upperBound: 9_000),
        ])
    }

    @Test("Direct and reject actions are generated without Mihomo indirection")
    func mapsNonProxyActions() throws {
        var draft = CaptureRuleDraft(
            identifier: "tcp-direct",
            matchesTCP: true,
            matchesUDP: false,
            action: .direct,
            unavailableFallback: .reject
        )
        #expect(try draft.makeRule().action == .direct)
        #expect(try draft.makeRule().unavailableFallback == .reject)

        draft.action = .reject
        #expect(try draft.makeRule().action == .reject)
    }

    @Test("GLOBAL and named Mihomo policy groups round-trip through the editor")
    func mapsDedicatedMihomoRoutes() throws {
        var draft = CaptureRuleDraft(
            identifier: "global-route",
            matchesTCP: true,
            matchesUDP: false,
            action: .mihomoGlobal
        )
        #expect(try draft.makeRule().action == .mihomo(.global))

        draft.identifier = "group-route"
        draft.action = .mihomoGroup
        #expect(throws: CaptureRuleDraftError.missingMihomoGroup) {
            try draft.makeRule()
        }
        draft.mihomoGroup = " Auto "
        let groupRule = try draft.makeRule()
        #expect(groupRule.action == .mihomo(.group("Auto")))
        #expect(try CaptureRuleDraft(rule: groupRule).makeRule() == groupRule)
    }

    @Test("Candidate selection is stable by ID and can populate its executable")
    func selectsApplicationCandidate() {
        let first = makeCandidate(id: "/Applications/First.app", name: "First")
        let second = makeCandidate(
            id: "/Applications/Second.app",
            name: "Second",
            executablePath: "/Applications/Second.app/Contents/MacOS/Second"
        )
        var draft = CaptureRuleDraft(identifier: "candidate")

        draft.selectApplication(id: second.id, from: [first, second])
        #expect(draft.selectedApplication == second)
        draft.useSelectedApplicationExecutable()
        #expect(draft.executablePath == second.executablePath)

        draft.selectApplication(id: nil, from: [first, second])
        #expect(draft.selectedApplication == second)
        draft.removeApplication(id: second.id)
        #expect(draft.selectedApplication == nil)
        #expect(draft.executablePath == second.executablePath)
    }

    @Test("Multiple applications and running processes compose as source alternatives")
    func composesMultipleSourceAlternatives() throws {
        let first = makeCandidate(id: "/Applications/First.app", name: "First")
        let second = makeCandidate(
            id: "/Applications/Second.app",
            name: "Second",
            bundleIdentifier: "com.example.second"
        )
        let firstProcess = try makeProcessCandidate(
            processIdentifier: 42,
            executablePath: "/Applications/First.app/Contents/MacOS/First"
        )
        let secondProcess = try makeProcessCandidate(
            processIdentifier: 84,
            executablePath: "/Applications/Second.app/Contents/MacOS/Second"
        )
        var draft = CaptureRuleDraft(identifier: "source-group")

        draft.selectApplication(id: first.id, from: [first, second])
        draft.selectApplication(id: second.id, from: [first, second])
        draft.selectProcess(id: firstProcess.id, from: [firstProcess, secondProcess])
        draft.selectProcess(id: secondProcess.id, from: [firstProcess, secondProcess])
        let rule = try draft.makeRule()

        #expect(draft.selectedApplications == [first, second])
        #expect(draft.selectedProcesses == [firstProcess, secondProcess])
        #expect(rule.sources.contains(.application(first.matcher)))
        #expect(rule.sources.contains(.application(second.matcher)))
        #expect(rule.sources.contains(.processInstance(firstProcess.matcher)))
        #expect(rule.sources.contains(.processInstance(secondProcess.matcher)))

        let rebuilt = try CaptureRuleDraft(
            rule: rule,
            applicationCandidates: [first, second],
            processCandidates: [firstProcess, secondProcess]
        )
        #expect(rebuilt.selectedApplications == [first, second])
        #expect(rebuilt.selectedProcesses == [firstProcess, secondProcess])
        #expect(try rebuilt.makeRule() == rule)
    }

    @Test("Identifier paste splits, normalizes, deduplicates, and removes individual items")
    func managesApplicationIdentifierItems() throws {
        var draft = CaptureRuleDraft(
            identifier: "identifiers",
            applicationIdentifierInput: "chatgpt; codex.app, CODEX\ncom.openai.codex; codex"
        )

        try draft.commitApplicationIdentifierInput()

        #expect(draft.applicationIdentifierPatterns == [
            "chatgpt", "codex.app", "codex", "com.openai.codex",
        ])
        #expect(draft.applicationIdentifierInput.isEmpty)
        draft.removeApplicationIdentifier("codex.app")
        #expect(draft.applicationIdentifierPatterns == [
            "chatgpt", "codex", "com.openai.codex",
        ])
        #expect(try draft.makeRule().sources.count == 3)
    }

    @Test("Selecting an application covers TCP, UDP, and exact app helper identifiers")
    func selectedApplicationCoversAllTransportsAndHelpers() throws {
        let candidate = ApplicationCaptureCandidate(
            id: "/Applications/Codex.app",
            displayName: "Codex",
            bundleIdentifier: "com.openai.codex",
            executablePath: "/Applications/Codex.app/Contents/MacOS/ChatGPT",
            runningProcessIdentifiers: [42],
            matcher: ApplicationSourceMatcher(
                designatedRequirement: "identifier com.openai.codex and anchor apple generic",
                signingIdentifier: "com.openai.codex",
                teamIdentifier: "2DC432GLL2",
                bundleIdentifier: "com.openai.codex"
            ),
            fallbackIdentifierPatterns: [
                "com.openai.codex",
                "codex",
                "codex-code-mode-host",
                "codex",
            ]
        )
        var draft = CaptureRuleDraft(
            identifier: "Codex",
            matchesTCP: true,
            matchesUDP: false
        )

        draft.selectApplication(id: candidate.id, from: [candidate])
        let rule = try draft.makeRule()

        #expect(draft.matchesTCP)
        #expect(draft.matchesUDP)
        #expect(rule.protocols == [.tcp, .udp])
        #expect(rule.sources.contains(.application(candidate.matcher)))
        let patterns = rule.sources.compactMap { source -> String? in
            if case let .applicationIdentifierPattern(matcher) = source {
                return matcher.pattern
            }
            return nil
        }
        #expect(patterns == ["com.openai.codex", "codex", "codex-code-mode-host"])
        #expect(patterns.allSatisfy { !$0.contains("*") && !$0.contains("?") })
    }

    @Test("Managed application fallback identifiers round-trip without appearing as advanced input")
    func managedApplicationFallbackIdentifiersRoundTrip() throws {
        let candidate = ApplicationCaptureCandidate(
            id: "/Applications/Codex.app",
            displayName: "Codex",
            bundleIdentifier: "com.openai.codex",
            executablePath: "/Applications/Codex.app/Contents/MacOS/ChatGPT",
            runningProcessIdentifiers: [],
            matcher: ApplicationSourceMatcher(
                designatedRequirement: "identifier com.openai.codex and anchor apple generic",
                signingIdentifier: "com.openai.codex",
                teamIdentifier: "2DC432GLL2",
                bundleIdentifier: "com.openai.codex"
            ),
            fallbackIdentifierPatterns: ["com.openai.codex", "codex"]
        )
        let original = try CaptureRuleDraft(
            identifier: "Codex",
            selectedApplication: candidate
        ).makeRule()

        let rebuiltDraft = try CaptureRuleDraft(
            rule: original,
            applicationCandidates: [candidate]
        )

        #expect(rebuiltDraft.selectedApplication == candidate)
        #expect(rebuiltDraft.applicationIdentifierPattern.isEmpty)
        #expect(try rebuiltDraft.makeRule() == original)
    }

    @Test("A running process selection round-trips as one execution")
    func selectsAndRoundTripsProcessInstance() throws {
        let process = try makeProcessCandidate()
        var draft = CaptureRuleDraft(identifier: "process")

        draft.selectProcess(id: process.id, from: [process])
        #expect(draft.selectedProcess == process)
        #expect(draft.selectedApplication == nil)

        let original = try draft.makeRule()
        #expect(original.sources == [.processInstance(process.matcher)])

        let rebuiltDraft = try CaptureRuleDraft(
            rule: original,
            processCandidates: [process]
        )
        #expect(rebuiltDraft.selectedProcess == process)
        #expect(try rebuiltDraft.makeRule() == original)
    }

    @Test("An unrelated executable path does not inherit an application's signing requirement")
    func doesNotMisapplySigningRequirement() throws {
        let candidate = makeCandidate()
        let draft = CaptureRuleDraft(
            identifier: "separate-path",
            selectedApplication: candidate,
            executablePath: "/usr/bin/curl"
        )

        let rule = try draft.makeRule()
        let executable = try #require(rule.sources.compactMap { source in
            if case let .executable(value) = source { value } else { nil }
        }.first)
        #expect(executable.canonicalPath == "/usr/bin/curl")
        #expect(executable.designatedRequirement == nil)
    }

    @Test("A supported rule round-trips through the editor without losing matchers")
    func roundTripsSupportedRule() throws {
        let candidate = makeCandidate()
        let original = try CaptureRule(
            id: "round-trip",
            enabled: false,
            priority: -20,
            sources: [
                .application(candidate.matcher),
                .executable(ExecutableSourceMatcher(
                    canonicalPath: candidate.executablePath,
                    designatedRequirement: candidate.matcher.designatedRequirement
                )),
                .userID(502),
            ],
            destinations: [.network(try IPNetwork("2001:db8::/32"))],
            protocols: [.tcp, .udp],
            portRanges: [try PortRange(lowerBound: 443, upperBound: 8_443)],
            action: .mihomo(.profileRules),
            unavailableFallback: .reject
        )

        let draft = try CaptureRuleDraft(rule: original, applicationCandidates: [candidate])
        let rebuilt = try draft.makeRule()

        #expect(draft.selectedApplication == candidate)
        #expect(draft.destinations == original.destinations)
        #expect(draft.portRange == "443-8443")
        #expect(rebuilt == original)
    }

    @Test("A stored application remains editable when it is not currently running")
    func preservesNonRunningApplication() throws {
        let candidate = makeCandidate()
        let original = try CaptureRule(
            id: "not-running",
            priority: 1,
            sources: [.application(candidate.matcher)],
            destinations: [.ip(try IPAddress("198.51.100.1"))],
            action: .direct
        )

        let draft = try CaptureRuleDraft(rule: original, applicationCandidates: [])
        let rebuilt = try draft.makeRule()

        #expect(draft.selectedApplication?.matcher == candidate.matcher)
        #expect(draft.selectedApplication?.runningProcessIdentifiers == [])
        #expect(rebuilt.sources == original.sources)
        #expect(rebuilt.destinations == original.destinations)
        #expect(rebuilt.action == original.action)
        // The editor spells the shared engine's empty "any transport" set as
        // the equivalent explicit TCP + UDP selection.
        #expect(rebuilt.protocols == [.tcp, .udp])
    }

    @Test("Unsafe or incomplete fields fail before CaptureRule is returned")
    func rejectsInvalidFields() throws {
        var draft = CaptureRuleDraft(identifier: "")
        #expect(throws: CaptureRuleDraftError.invalidIdentifier) { try draft.makeRule() }

        draft.identifier = "invalid-path"
        draft.executablePath = "relative/tool"
        #expect(throws: CaptureRuleDraftError.invalidExecutablePath("relative/tool")) {
            try draft.makeRule()
        }

        draft.executablePath = ""
        draft.userID = "-1"
        #expect(throws: CaptureRuleDraftError.invalidUserID("-1")) { try draft.makeRule() }

        draft.userID = ""
        draft.networkInput = "999.0.0.1"
        #expect(throws: CaptureRuleDraftError.invalidIPAddress("999.0.0.1")) {
            try draft.makeRule()
        }

        draft.networkInput = "192.0.2.1/99"
        #expect(throws: CaptureRuleDraftError.invalidNetwork("192.0.2.1/99")) {
            try draft.makeRule()
        }

        draft.networkInput = ""
        draft.domainInput = "bad..example"
        #expect(throws: CaptureRuleDraftError.invalidDomain("bad..example")) {
            try draft.makeRule()
        }
    }

    @Test("Protocol, port, and catch-all safety validation are explicit")
    func rejectsUnsafeMatchShapes() throws {
        var draft = CaptureRuleDraft(identifier: "shape")
        #expect(throws: CaptureRuleDraftError.noMatchCriteria) { try draft.makeRule() }

        draft.matchesTCP = false
        draft.matchesUDP = false
        #expect(throws: CaptureRuleDraftError.noTransportProtocol) { try draft.makeRule() }

        draft.matchesTCP = true
        draft.portRange = "0"
        #expect(throws: CaptureRuleDraftError.invalidPortRange("0")) { try draft.makeRule() }

        draft.portRange = "9000-8000"
        #expect(throws: CaptureRuleDraftError.invalidPortRange("9000-8000")) {
            try draft.makeRule()
        }

        draft.portRange = "80-90-100"
        #expect(throws: CaptureRuleDraftError.invalidPortRange("80-90-100")) {
            try draft.makeRule()
        }
    }

    @Test("Unsupported provider process rules fail closed and multi-target rules round-trip")
    func rejectsUnsupportedExistingRules() throws {
        let processRule = try CaptureRule(
            id: "process",
            priority: 1,
            sources: [.processInstance(ProcessInstanceSourceMatcher(
                processIdentifier: 42,
                auditToken: Data(repeating: 1, count: 32)
            ))],
            action: .direct
        )
        #expect(
            throws: CaptureRuleDraftError.unsupportedExistingRule(
                "provider-observed audit-token process matcher"
            )
        ) {
            try CaptureRuleDraft(rule: processRule)
        }

        let destinations = try CaptureRule(
            id: "destinations",
            priority: 1,
            destinations: [
                .ip(try IPAddress("192.0.2.1")),
                .ip(try IPAddress("192.0.2.2")),
            ],
            action: .direct
        )
        let destinationDraft = try CaptureRuleDraft(rule: destinations)
        #expect(destinationDraft.destinations == destinations.destinations)
        let rebuiltDestinations = try destinationDraft.makeRule()
        #expect(rebuiltDestinations.sources == destinations.sources)
        #expect(rebuiltDestinations.destinations == destinations.destinations)
        #expect(rebuiltDestinations.action == destinations.action)

    }

    private func makeCandidate(
        id: String = "/Applications/Browser.app",
        name: String = "Browser",
        executablePath: String = "/Applications/Browser.app/Contents/MacOS/Browser",
        bundleIdentifier: String = "com.example.browser"
    ) -> ApplicationCaptureCandidate {
        ApplicationCaptureCandidate(
            id: id,
            displayName: name,
            bundleIdentifier: bundleIdentifier,
            executablePath: executablePath,
            runningProcessIdentifiers: [42, 84],
            matcher: ApplicationSourceMatcher(
                designatedRequirement: "identifier \(bundleIdentifier) and anchor apple generic",
                signingIdentifier: bundleIdentifier,
                teamIdentifier: "TEAMID",
                bundleIdentifier: bundleIdentifier
            ),
            fallbackIdentifierPatterns: []
        )
    }

    private func makeProcessCandidate(
        processIdentifier: Int32 = 42,
        executablePath: String = "/Applications/Browser.app/Contents/MacOS/Browser"
    ) throws -> RunningProcessCaptureCandidate {
        let startTime = try ProcessStartTime(seconds: 1_700_000_000, microseconds: 123)
        let matcher = ProcessInstanceSourceMatcher(
            processIdentifier: processIdentifier,
            startTime: startTime,
            canonicalExecutablePath: executablePath
        )
        return RunningProcessCaptureCandidate(
            id: "\(processIdentifier):\(startTime.seconds):\(startTime.microseconds)",
            displayName: "Browser · PID \(processIdentifier)",
            processIdentifier: processIdentifier,
            executablePath: matcher.canonicalExecutablePath ?? "",
            matcher: matcher
        )
    }
}
