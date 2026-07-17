import Foundation
import MClashNetworkShared

enum CaptureRuleDestinationKind: String, CaseIterable, Identifiable, Sendable {
    case any
    case ipAddress
    case network
    case domain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "Any destination"
        case .ipAddress: "Single IP"
        case .network: "IP network (CIDR)"
        case .domain: "Domain"
        }
    }
}

enum CaptureRuleDraftAction: String, CaseIterable, Identifiable, Sendable {
    case direct
    case reject
    case mihomoProfileRules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: "Direct"
        case .reject: "Reject"
        case .mihomoProfileRules: "Mihomo profile rules"
        }
    }

    var captureAction: CaptureAction {
        switch self {
        case .direct: .direct
        case .reject: .reject
        case .mihomoProfileRules: .mihomo(.profileRules)
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
            "Add an application, executable, user, destination, protocol restriction, or port restriction."
        case let .unsupportedExistingRule(reason):
            "This rule uses an option that this editor cannot represent: \(reason)."
        case let .invalidCaptureRule(reason):
            "The rule is invalid: \(reason)"
        }
    }
}

/// Editable, UI-friendly representation of the targeted capture rule subset.
///
/// Empty source fields are omitted. Sources selected together retain the
/// shared rule engine's OR semantics, while source, destination, transport,
/// and port fields are combined with AND semantics by `CaptureRuleEngine`.
struct CaptureRuleDraft: Equatable, Sendable {
    var identifier: String
    var enabled: Bool
    var priority: Int
    var selectedApplication: ApplicationCaptureCandidate?
    var selectedProcess: RunningProcessCaptureCandidate?
    var applicationIdentifierPattern: String
    var executablePath: String
    var userID: String
    var destinationKind: CaptureRuleDestinationKind
    var destinationValue: String
    var domainKind: HostMatcher.Kind
    var matchesTCP: Bool
    var matchesUDP: Bool
    var portRange: String
    var action: CaptureRuleDraftAction
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
        destinationKind: CaptureRuleDestinationKind = .any,
        destinationValue: String = "",
        domainKind: HostMatcher.Kind = .exact,
        matchesTCP: Bool = true,
        matchesUDP: Bool = true,
        portRange: String = "",
        action: CaptureRuleDraftAction = .mihomoProfileRules,
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
        self.destinationKind = destinationKind
        self.destinationValue = destinationValue
        self.domainKind = domainKind
        self.matchesTCP = matchesTCP
        self.matchesUDP = matchesUDP
        self.portRange = portRange
        self.action = action
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
              applicationPatternMatchers.count <= 1,
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
        applicationIdentifierPattern = applicationPatternMatchers.first?.pattern ?? ""
        executablePath = executableMatchers.first?.canonicalPath ?? ""
        userID = userIDs.first.map(String.init) ?? ""

        guard rule.destinations.count <= 1 else {
            throw CaptureRuleDraftError.unsupportedExistingRule("multiple destination matchers")
        }
        if let destination = rule.destinations.first {
            switch destination {
            case let .ip(address):
                destinationKind = .ipAddress
                destinationValue = address.presentation
            case let .network(network):
                destinationKind = .network
                destinationValue = network.presentation
            case let .host(host):
                destinationKind = .domain
                destinationValue = host.value
                domainKind = host.kind
            }
        }

        guard rule.portRanges.count <= 1 else {
            throw CaptureRuleDraftError.unsupportedExistingRule("multiple port ranges")
        }
        if let range = rule.portRanges.first {
            portRange = range.lowerBound == range.upperBound
                ? String(range.lowerBound)
                : "\(range.lowerBound)-\(range.upperBound)"
        }
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
                action: action.captureAction,
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

    private func sourceMatchers() throws -> [SourceMatcher] {
        var sources: [SourceMatcher] = []
        if let selectedApplication {
            sources.append(.application(selectedApplication.matcher))
        }
        if let selectedProcess {
            sources.append(.processInstance(selectedProcess.matcher))
        }

        let applicationPattern = applicationIdentifierPattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !applicationPattern.isEmpty {
            do {
                sources.append(.applicationIdentifierPattern(
                    try ApplicationIdentifierPatternMatcher(pattern: applicationPattern)
                ))
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
        let value = destinationValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch destinationKind {
        case .any:
            return []
        case .ipAddress:
            do {
                return [.ip(try IPAddress(value))]
            } catch {
                throw CaptureRuleDraftError.invalidIPAddress(value)
            }
        case .network:
            do {
                return [.network(try IPNetwork(value))]
            } catch {
                throw CaptureRuleDraftError.invalidNetwork(value)
            }
        case .domain:
            do {
                let usesWildcard = value.hasPrefix("*.")
                let normalizedValue = usesWildcard ? String(value.dropFirst(2)) : value
                let kind: HostMatcher.Kind = usesWildcard ? .suffix : domainKind
                return [.host(try HostMatcher(kind: kind, value: normalizedValue))]
            } catch {
                throw CaptureRuleDraftError.invalidDomain(value)
            }
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
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (1 ... 2).contains(components.count),
              let lowerInteger = Int(components[0]),
              (1 ... Int(UInt16.max)).contains(lowerInteger) else {
            throw CaptureRuleDraftError.invalidPortRange(value)
        }
        let upperInteger: Int
        if components.count == 2 {
            guard let parsedUpper = Int(components[1]),
                  (1 ... Int(UInt16.max)).contains(parsedUpper),
                  parsedUpper >= lowerInteger else {
                throw CaptureRuleDraftError.invalidPortRange(value)
            }
            upperInteger = parsedUpper
        } else {
            upperInteger = lowerInteger
        }
        do {
            return [try PortRange(
                lowerBound: UInt16(lowerInteger),
                upperBound: UInt16(upperInteger)
            )]
        } catch {
            throw CaptureRuleDraftError.invalidPortRange(value)
        }
    }

    private static func draftAction(_ action: CaptureAction) throws -> CaptureRuleDraftAction {
        switch action {
        case .direct: .direct
        case .reject: .reject
        case .mihomo(.profileRules): .mihomoProfileRules
        case .mihomo(.global):
            throw CaptureRuleDraftError.unsupportedExistingRule("Mihomo global action")
        case let .mihomo(.group(group)):
            throw CaptureRuleDraftError.unsupportedExistingRule("Mihomo group action \(group)")
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
