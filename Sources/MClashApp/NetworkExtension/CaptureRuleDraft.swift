import Foundation
import MClashNetworkShared

enum CaptureRuleDraftAction: String, CaseIterable, Identifiable, Sendable {
    case direct
    case reject
    case mihomoProfileRules
    case mihomoGlobal
    case mihomoGroup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: "Direct"
        case .reject: "Reject"
        case .mihomoProfileRules: "Mihomo profile rules"
        case .mihomoGlobal: "Mihomo GLOBAL"
        case .mihomoGroup: "Mihomo policy group"
        }
    }
}

enum CaptureRuleDraftError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidApplicationPattern(String)
    case invalidExecutablePath(String)
    case invalidUserID(String)
    case invalidIPAddress(String)
    case invalidNetwork(String)
    case invalidDomain(String)
    case noTransportProtocol
    case invalidPortRange(String)
    case noMatchCriteria
    case missingMihomoGroup
    case unsupportedExistingRule(String)
    case invalidCaptureRule(String)
}

extension CaptureRuleDraftError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            "Enter a rule identifier."
        case let .invalidApplicationPattern(value):
            "Enter an application name or bundle identifier pattern; received \(value)."
        case let .invalidExecutablePath(value):
            "Executable path must be an absolute path; received \(value.isEmpty ? "an empty value" : value)."
        case let .invalidUserID(value):
            "User ID must be a whole number from 0 through \(UInt32.max); received \(value)."
        case let .invalidIPAddress(value):
            "Enter a valid IPv4 or IPv6 address; received \(value)."
        case let .invalidNetwork(value):
            "Enter a valid IPv4 or IPv6 CIDR network; received \(value)."
        case let .invalidDomain(value):
            "Enter a valid domain name; received \(value)."
        case .noTransportProtocol:
            "Select TCP, UDP, or both."
        case let .invalidPortRange(value):
            "Port must be 1–65535 or a range such as 8000-9000; received \(value)."
        case .noMatchCriteria:
            "Add an application, domain, IP/CIDR, executable, user, protocol restriction, or port restriction."
        case .missingMihomoGroup:
            "Choose a Mihomo policy group."
        case let .unsupportedExistingRule(reason):
            "This rule uses an option that this editor cannot represent: \(reason)."
        case let .invalidCaptureRule(reason):
            "The rule is invalid: \(reason)"
        }
    }
}

/// Editable, UI-friendly representation of the targeted capture rule subset.
///
/// Empty source fields are omitted and therefore match every application.
/// Matchers within source and destination groups use OR semantics, while
/// source, destination, transport, and port groups are combined with AND
/// semantics by `CaptureRuleEngine`.
struct CaptureRuleDraft: Equatable, Sendable {
    var identifier: String
    var enabled: Bool
    var priority: Int
    var selectedApplication: ApplicationCaptureCandidate?
    var selectedProcess: RunningProcessCaptureCandidate?
    var applicationIdentifierPattern: String
    var executablePath: String
    var userID: String
    var destinations: [DestinationMatcher]
    var domainInput: String
    var networkInput: String
    var matchesTCP: Bool
    var matchesUDP: Bool
    var portRange: String
    var action: CaptureRuleDraftAction
    var mihomoGroup: String
    var unavailableFallback: UnavailableFallback

    init(
        identifier: String = "capture-\(UUID().uuidString.lowercased())",
        enabled: Bool = true,
        priority: Int = 100,
        selectedApplication: ApplicationCaptureCandidate? = nil,
        selectedProcess: RunningProcessCaptureCandidate? = nil,
        applicationIdentifierPattern: String = "",
        executablePath: String = "",
        userID: String = "",
        destinations: [DestinationMatcher] = [],
        domainInput: String = "",
        networkInput: String = "",
        matchesTCP: Bool = true,
        matchesUDP: Bool = true,
        portRange: String = "",
        action: CaptureRuleDraftAction = .mihomoProfileRules,
        mihomoGroup: String = "",
        unavailableFallback: UnavailableFallback = .direct
    ) {
        self.identifier = identifier
        self.enabled = enabled
        self.priority = priority
        self.selectedApplication = selectedApplication
        self.selectedProcess = selectedProcess
        self.applicationIdentifierPattern = applicationIdentifierPattern
        self.executablePath = executablePath
        self.userID = userID
        self.destinations = destinations
        self.domainInput = domainInput
        self.networkInput = networkInput
        self.matchesTCP = matchesTCP
        self.matchesUDP = matchesUDP
        self.portRange = portRange
        self.action = action
        self.mihomoGroup = mihomoGroup
        self.unavailableFallback = unavailableFallback
    }

    /// Builds an editable draft for the subset represented by this editor.
    /// Unsupported matchers are rejected rather than silently discarded.
    init(
        rule: CaptureRule,
        applicationCandidates: [ApplicationCaptureCandidate] = [],
        processCandidates: [RunningProcessCaptureCandidate] = []
    ) throws {
        self.init(
            identifier: rule.id,
            enabled: rule.enabled,
            priority: rule.priority,
            matchesTCP: rule.protocols.isEmpty || rule.protocols.contains(.tcp),
            matchesUDP: rule.protocols.isEmpty || rule.protocols.contains(.udp),
            action: try Self.draftAction(rule.action),
            unavailableFallback: rule.unavailableFallback
        )
        if case let .mihomo(.group(group)) = rule.action {
            mihomoGroup = group
        }

        var applicationMatchers: [ApplicationSourceMatcher] = []
        var applicationPatternMatchers: [ApplicationIdentifierPatternMatcher] = []
        var executableMatchers: [ExecutableSourceMatcher] = []
        var processMatchers: [ProcessInstanceSourceMatcher] = []
        var userIDs: [UInt32] = []
        for source in rule.sources {
            switch source {
            case let .application(matcher): applicationMatchers.append(matcher)
            case let .applicationIdentifierPattern(matcher):
                applicationPatternMatchers.append(matcher)
            case let .executable(matcher): executableMatchers.append(matcher)
            case let .userID(value): userIDs.append(value)
            case let .processInstance(matcher): processMatchers.append(matcher)
            }
        }
        guard applicationMatchers.count <= 1,
              executableMatchers.count <= 1,
              processMatchers.count <= 1,
              userIDs.count <= 1 else {
            throw CaptureRuleDraftError.unsupportedExistingRule(
                "multiple matchers of the same source type"
            )
        }

        if let matcher = applicationMatchers.first {
            selectedApplication = applicationCandidates.first(where: { $0.matcher == matcher })
                ?? Self.placeholderCandidate(
                    matcher: matcher,
                    executablePath: executableMatchers.first?.canonicalPath ?? ""
                )
        }
        if let matcher = processMatchers.first {
            guard matcher.auditToken == nil,
                  matcher.startTime != nil,
                  matcher.canonicalExecutablePath != nil else {
                throw CaptureRuleDraftError.unsupportedExistingRule(
                    "provider-observed audit-token process matcher"
                )
            }
            selectedProcess = processCandidates.first(where: { $0.matcher == matcher })
                ?? Self.placeholderProcessCandidate(matcher: matcher)
        }
        applicationIdentifierPattern = applicationPatternMatchers
            .map(\.pattern)
            .joined(separator: "; ")
        executablePath = executableMatchers.first?.canonicalPath ?? ""
        userID = userIDs.first.map(String.init) ?? ""

        destinations = rule.destinations

        portRange = rule.portRanges.map { range in
            range.lowerBound == range.upperBound
                ? String(range.lowerBound)
                : "\(range.lowerBound)-\(range.upperBound)"
        }.joined(separator: "; ")
    }

    var selectedApplicationID: String? {
        selectedApplication?.id
    }

    var selectedProcessID: String? {
        selectedProcess?.id
    }

    mutating func selectApplication(
        id: String?,
        from candidates: [ApplicationCaptureCandidate]
    ) {
        guard let id else {
            selectedApplication = nil
            return
        }
        selectedApplication = candidates.first(where: { $0.id == id })
        if selectedApplication != nil {
            selectedProcess = nil
        }
    }

    mutating func selectProcess(
        id: String?,
        from candidates: [RunningProcessCaptureCandidate]
    ) {
        guard let id else {
            selectedProcess = nil
            return
        }
        selectedProcess = candidates.first(where: { $0.id == id })
        if selectedProcess != nil {
            selectedApplication = nil
        }
    }

    mutating func useSelectedApplicationExecutable() {
        guard let selectedApplication, !selectedApplication.executablePath.isEmpty else { return }
        executablePath = selectedApplication.executablePath
    }

    var domainDestinations: [DestinationMatcher] {
        destinations.filter {
            switch $0 {
            case .host, .hostPattern: return true
            case .ip, .network: return false
            }
        }
    }

    var networkDestinations: [DestinationMatcher] {
        destinations.filter {
            switch $0 {
            case .ip, .network: return true
            case .host, .hostPattern: return false
            }
        }
    }

    var destinationPreviewLabels: [String] {
        let matchers = (try? destinationMatchers()) ?? destinations
        return matchers.map(Self.destinationLabel)
    }

    mutating func commitDomainInput() throws {
        appendUnique(try Self.domainMatchers(from: domainInput))
        domainInput = ""
    }

    mutating func commitNetworkInput() throws {
        appendUnique(try Self.networkMatchers(from: networkInput))
        networkInput = ""
    }

    mutating func removeDestination(_ matcher: DestinationMatcher) {
        destinations.removeAll { $0 == matcher }
    }

    var validationMessage: String? {
        do {
            _ = try makeRule()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    var canSubmit: Bool { validationMessage == nil }

    func makeRule() throws -> CaptureRule {
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedIdentifier.isEmpty,
              !normalizedIdentifier.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" })
        else {
            throw CaptureRuleDraftError.invalidIdentifier
        }

        let sources = try sourceMatchers()
        let destinations = try destinationMatchers()
        let protocols = try transportProtocols()
        let portRanges = try portMatchers()
        let hasProtocolRestriction = protocols.count == 1
        guard !sources.isEmpty
                || !destinations.isEmpty
                || !portRanges.isEmpty
                || hasProtocolRestriction else {
            throw CaptureRuleDraftError.noMatchCriteria
        }

        do {
            let rule = try CaptureRule(
                id: normalizedIdentifier,
                enabled: enabled,
                priority: priority,
                sources: sources,
                destinations: destinations,
                protocols: protocols,
                portRanges: portRanges,
                action: try captureAction(),
                unavailableFallback: unavailableFallback
            )
            try rule.validate()
            return rule
        } catch let error as CaptureRuleDraftError {
            throw error
        } catch {
            throw CaptureRuleDraftError.invalidCaptureRule(String(describing: error))
        }
    }

    private func captureAction() throws -> CaptureAction {
        switch action {
        case .direct: return .direct
        case .reject: return .reject
        case .mihomoProfileRules: return .mihomo(.profileRules)
        case .mihomoGlobal: return .mihomo(.global)
        case .mihomoGroup:
            let group = mihomoGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !group.isEmpty else { throw CaptureRuleDraftError.missingMihomoGroup }
            return .mihomo(.group(group))
        }
    }

    private func sourceMatchers() throws -> [SourceMatcher] {
        var sources: [SourceMatcher] = []
        if let selectedApplication {
            sources.append(.application(selectedApplication.matcher))
        }
        if let selectedProcess {
            sources.append(.processInstance(selectedProcess.matcher))
        }

        for applicationPattern in Self.splitPatternEntries(applicationIdentifierPattern) {
            do {
                let matcher = try ApplicationIdentifierPatternMatcher(pattern: applicationPattern)
                let source = SourceMatcher.applicationIdentifierPattern(matcher)
                if !sources.contains(source) { sources.append(source) }
            } catch {
                throw CaptureRuleDraftError.invalidApplicationPattern(applicationPattern)
            }
        }

        let path = executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty {
            guard path.hasPrefix("/"), path.count > 1,
                  !path.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" })
            else {
                throw CaptureRuleDraftError.invalidExecutablePath(path)
            }
            let canonicalPath = URL(fileURLWithPath: path)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            let selectedCanonicalPath = selectedApplication.map {
                URL(fileURLWithPath: $0.executablePath)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL.path
            }
            let requirement = selectedCanonicalPath == canonicalPath
                ? selectedApplication?.matcher.designatedRequirement
                : nil
            sources.append(.executable(ExecutableSourceMatcher(
                canonicalPath: canonicalPath,
                designatedRequirement: requirement
            )))
        }

        let userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userID.isEmpty {
            guard let value = UInt32(userID) else {
                throw CaptureRuleDraftError.invalidUserID(userID)
            }
            sources.append(.userID(value))
        }
        return sources
    }

    private func destinationMatchers() throws -> [DestinationMatcher] {
        var result = destinations
        Self.appendUnique(try Self.domainMatchers(from: domainInput), to: &result)
        Self.appendUnique(try Self.networkMatchers(from: networkInput), to: &result)
        return result
    }

    private mutating func appendUnique(_ matchers: [DestinationMatcher]) {
        Self.appendUnique(matchers, to: &destinations)
    }

    private static func appendUnique(
        _ matchers: [DestinationMatcher],
        to result: inout [DestinationMatcher]
    ) {
        for matcher in matchers where !result.contains(matcher) {
            result.append(matcher)
        }
    }

    private static func domainMatchers(from input: String) throws -> [DestinationMatcher] {
        var result: [DestinationMatcher] = []
        for originalEntry in splitEntries(input) {
            var entry = originalEntry
            let kind: HostMatcher.Kind
            if entry.hasPrefix("=") {
                kind = .exact
                entry.removeFirst()
            } else {
                kind = .suffix
                if entry.hasPrefix("*.") {
                    entry.removeFirst(2)
                } else if entry.hasPrefix(".") {
                    entry.removeFirst()
                }
            }

            if entry.contains("://"),
               let host = URL(string: entry)?.host {
                entry = host
            }

            do {
                if entry.contains("*") || entry.contains("?") {
                    appendUnique(
                        [.hostPattern(try HostPatternMatcher(pattern: entry))],
                        to: &result
                    )
                } else {
                    appendUnique([.host(try HostMatcher(kind: kind, value: entry))], to: &result)
                }
            } catch {
                throw CaptureRuleDraftError.invalidDomain(originalEntry)
            }
        }
        return result
    }

    private static func networkMatchers(from input: String) throws -> [DestinationMatcher] {
        var result: [DestinationMatcher] = []
        for entry in splitEntries(input) {
            if entry.contains("/") {
                do {
                    appendUnique([.network(try IPNetwork(entry))], to: &result)
                } catch {
                    throw CaptureRuleDraftError.invalidNetwork(entry)
                }
            } else {
                do {
                    appendUnique([.ip(try IPAddress(entry))], to: &result)
                } catch {
                    throw CaptureRuleDraftError.invalidIPAddress(entry)
                }
            }
        }
        return result
    }

    private static func splitEntries(_ input: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",;"))
        return input.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func splitPatternEntries(_ input: String) -> [String] {
        input.components(separatedBy: CharacterSet(charactersIn: ",;\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func destinationLabel(_ matcher: DestinationMatcher) -> String {
        switch matcher {
        case let .host(host):
            switch host.kind {
            case .exact: "=\(host.value)"
            case .suffix: "*.\(host.value)"
            }
        case let .hostPattern(pattern):
            pattern.pattern
        case let .ip(address):
            address.presentation
        case let .network(network):
            network.presentation
        }
    }

    private func transportProtocols() throws -> Set<TransportProtocol> {
        var protocols: Set<TransportProtocol> = []
        if matchesTCP { protocols.insert(.tcp) }
        if matchesUDP { protocols.insert(.udp) }
        guard !protocols.isEmpty else {
            throw CaptureRuleDraftError.noTransportProtocol
        }
        return protocols
    }

    private func portMatchers() throws -> [PortRange] {
        let value = portRange.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        var result: [PortRange] = []
        for entry in Self.splitPatternEntries(value) {
            let components = entry.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard (1 ... 2).contains(components.count),
                  let lowerInteger = Int(components[0]),
                  (1 ... Int(UInt16.max)).contains(lowerInteger) else {
                throw CaptureRuleDraftError.invalidPortRange(entry)
            }
            let upperInteger: Int
            if components.count == 2 {
                guard let parsedUpper = Int(components[1]),
                      (1 ... Int(UInt16.max)).contains(parsedUpper),
                      parsedUpper >= lowerInteger else {
                    throw CaptureRuleDraftError.invalidPortRange(entry)
                }
                upperInteger = parsedUpper
            } else {
                upperInteger = lowerInteger
            }
            do {
                let range = try PortRange(
                    lowerBound: UInt16(lowerInteger),
                    upperBound: UInt16(upperInteger)
                )
                if !result.contains(range) { result.append(range) }
            } catch {
                throw CaptureRuleDraftError.invalidPortRange(entry)
            }
        }
        return result
    }

    private static func draftAction(_ action: CaptureAction) throws -> CaptureRuleDraftAction {
        switch action {
        case .direct: .direct
        case .reject: .reject
        case .mihomo(.profileRules): .mihomoProfileRules
        case .mihomo(.global): .mihomoGlobal
        case .mihomo(.group): .mihomoGroup
        }
    }

    private static func placeholderCandidate(
        matcher: ApplicationSourceMatcher,
        executablePath: String
    ) -> ApplicationCaptureCandidate {
        let label = matcher.bundleIdentifier
            ?? matcher.signingIdentifier
            ?? "Previously selected application"
        return ApplicationCaptureCandidate(
            id: "stored:\(matcher.designatedRequirement)",
            displayName: label,
            bundleIdentifier: matcher.bundleIdentifier,
            executablePath: executablePath,
            runningProcessIdentifiers: [],
            matcher: matcher
        )
    }

    private static func placeholderProcessCandidate(
        matcher: ProcessInstanceSourceMatcher
    ) -> RunningProcessCaptureCandidate {
        let path = matcher.canonicalExecutablePath ?? ""
        let name = URL(fileURLWithPath: path).lastPathComponent
        return RunningProcessCaptureCandidate(
            id: "stored-process:\(matcher.processIdentifier)",
            displayName: "\(name.isEmpty ? "Process" : name) · PID \(matcher.processIdentifier) (not running)",
            processIdentifier: matcher.processIdentifier,
            executablePath: path,
            matcher: matcher
        )
    }
}
