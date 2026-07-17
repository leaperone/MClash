import Foundation

public enum BuiltInBypassReason: String, Codable, Hashable, Sendable {
    case trustedMClashComponent
    case loopback
    case linkLocal
    case multicast
    case unspecifiedAddress
}

public enum RuleDecisionCause: Codable, Hashable, Sendable {
    case builtInBypass(BuiltInBypassReason)
    case matchedRule(String)
    case defaultDirect
}

public struct RuleDecision: Codable, Hashable, Sendable {
    public let action: CaptureAction
    public let unavailableFallback: UnavailableFallback
    public let cause: RuleDecisionCause

    public init(action: CaptureAction, unavailableFallback: UnavailableFallback, cause: RuleDecisionCause) {
        self.action = action
        self.unavailableFallback = unavailableFallback
        self.cause = cause
    }
}

/// Security-critical bypasses are compiled into the engine and are deliberately
/// absent from user configuration snapshots.
public struct BuiltInBypassPolicy: Sendable {
    public init() {}

    public func reason(for context: FlowContext) -> BuiltInBypassReason? {
        if context.source.isTrustedMClashComponent {
            return .trustedMClashComponent
        }
        guard let address = context.destination.ipAddress else { return nil }
        if address.isLoopback { return .loopback }
        if address.isLinkLocal { return .linkLocal }
        if address.isMulticast { return .multicast }
        if address.isUnspecified { return .unspecifiedAddress }
        return nil
    }
}

public struct CaptureRuleEngine: Sendable {
    private struct OrderedRule: Sendable {
        let rule: CaptureRule
        let insertionIndex: Int
    }

    private let orderedRules: [OrderedRule]
    private let builtInBypass = BuiltInBypassPolicy()

    public init(snapshot: CaptureConfigurationSnapshot) {
        orderedRules = snapshot.rules.enumerated()
            .map { OrderedRule(rule: $0.element, insertionIndex: $0.offset) }
            .sorted { lhs, rhs in
                if lhs.rule.priority != rhs.rule.priority {
                    return lhs.rule.priority < rhs.rule.priority
                }
                return lhs.insertionIndex < rhs.insertionIndex
            }
    }

    public func evaluate(_ context: FlowContext) -> RuleDecision {
        if let reason = builtInBypass.reason(for: context) {
            return RuleDecision(action: .direct, unavailableFallback: .direct, cause: .builtInBypass(reason))
        }

        for orderedRule in orderedRules where orderedRule.rule.enabled {
            let rule = orderedRule.rule
            if Self.matches(rule, context: context) {
                return RuleDecision(
                    action: rule.action,
                    unavailableFallback: rule.unavailableFallback,
                    cause: .matchedRule(rule.id)
                )
            }
        }
        return RuleDecision(action: .direct, unavailableFallback: .direct, cause: .defaultDirect)
    }

    private static func matches(_ rule: CaptureRule, context: FlowContext) -> Bool {
        let sourceMatches = rule.sources.isEmpty || rule.sources.contains { matcher in
            matches(matcher, source: context.source)
        }
        guard sourceMatches else { return false }

        let destinationMatches = rule.destinations.isEmpty || rule.destinations.contains { matcher in
            matches(matcher, destination: context.destination)
        }
        guard destinationMatches else { return false }

        guard rule.protocols.isEmpty || rule.protocols.contains(context.transportProtocol) else {
            return false
        }
        return rule.portRanges.isEmpty || rule.portRanges.contains { $0.contains(context.destination.port) }
    }

    private static func matches(_ matcher: SourceMatcher, source: FlowSource) -> Bool {
        switch matcher {
        case let .application(application):
            guard source.designatedRequirement == application.designatedRequirement else { return false }
            if let expected = application.signingIdentifier, source.signingIdentifier != expected { return false }
            if let expected = application.teamIdentifier, source.teamIdentifier != expected { return false }
            if let expected = application.bundleIdentifier, source.bundleIdentifier != expected { return false }
            return true
        case let .applicationIdentifierPattern(application):
            let candidates = [
                source.bundleIdentifier,
                source.signingIdentifier,
                source.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ].compactMap { $0 }
            return candidates.contains(where: application.matches)
        case let .executable(executable):
            guard source.executablePath == executable.canonicalPath else { return false }
            if let expected = executable.designatedRequirement, source.designatedRequirement != expected { return false }
            if let expected = executable.sha256?.lowercased(), source.executableSHA256?.lowercased() != expected {
                return false
            }
            return true
        case let .processInstance(process):
            guard source.processIdentifier == process.processIdentifier else { return false }
            if let auditToken = process.auditToken {
                return source.auditToken == auditToken
            }
            guard source.processStartTime == process.startTime else { return false }
            if let path = process.canonicalExecutablePath {
                return source.executablePath == path
            }
            return false
        case let .userID(userID):
            return source.userID == userID
        }
    }

    private static func matches(_ matcher: DestinationMatcher, destination: FlowDestination) -> Bool {
        switch matcher {
        case let .ip(address):
            return destination.ipAddress == address
        case let .network(network):
            guard let address = destination.ipAddress else { return false }
            return network.contains(address)
        case let .host(host):
            guard let hostname = destination.hostname else { return false }
            return host.matches(hostname)
        }
    }
}
