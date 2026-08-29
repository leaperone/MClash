import Foundation
import MClashNetworkShared

/// Bridges strategy-owned RoutingRule values to the Network Extension's
/// capture wire format during the staged migration. It is intentionally
/// one-way: provider activity never mutates authoritative rules.
public enum ConfigurationCaptureAdapter {
    public struct Result: Equatable, Sendable {
        public let rules: [CaptureRule]
        public let diagnostics: [ConfigurationDiagnostic]

        public init(rules: [CaptureRule], diagnostics: [ConfigurationDiagnostic]) {
            self.rules = rules
            self.diagnostics = diagnostics
        }
    }

    public static func captureRules(
        from rules: [RoutingRule],
        groups: [ProxyGroup],
        workspaceID: WorkspaceID? = nil
    ) -> [CaptureRule] {
        convert(from: rules, groups: groups, workspaceID: workspaceID).rules
    }

    public static func convert(
        from rules: [RoutingRule],
        groups: [ProxyGroup],
        workspaceID: WorkspaceID? = nil
    ) -> Result {
        let groupNames = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        var converted: [CaptureRule] = []
        var diagnostics: [ConfigurationDiagnostic] = []
        for rule in rules.sorted(by: Self.stableRuleOrder) {
            var sources: [SourceMatcher] = []
            var destinations: [DestinationMatcher] = []
            var protocols = Set<TransportProtocol>()
            var ports: [PortRange] = []
            do {
                for matcher in rule.matchers {
                    switch matcher {
                    case let .application(pattern):
                        sources.append(.applicationIdentifierPattern(try ApplicationIdentifierPatternMatcher(pattern: pattern)))
                    case let .processPath(path):
                        sources.append(.executable(ExecutableSourceMatcher(canonicalPath: path)))
                    case let .userID(value):
                        sources.append(.userID(value))
                    case let .domainExact(value):
                        destinations.append(.host(try HostMatcher(kind: .exact, value: value)))
                    case let .domainSuffix(value):
                        destinations.append(.host(try HostMatcher(kind: .suffix, value: value)))
                    case let .domainWildcard(value):
                        destinations.append(.hostPattern(try HostPatternMatcher(pattern: value)))
                    case let .ipCIDR(value):
                        destinations.append(.network(try IPNetwork(value)))
                    case let .transport(value):
                        switch value.lowercased() {
                        case "tcp": protocols.insert(.tcp)
                        case "udp": protocols.insert(.udp)
                        default: throw NetworkRuleValidationError.invalidSourceMatcher(value)
                        }
                    case let .port(value):
                        guard let port = UInt16(exactly: value) else {
                            throw NetworkRuleValidationError.invalidDestinationPort(UInt16.max)
                        }
                        ports.append(try PortRange(port))
                    case let .portRange(value):
                        guard let lower = UInt16(exactly: value.lowerBound),
                              let upper = UInt16(exactly: value.upperBound) else {
                            throw NetworkRuleValidationError.invalidDestinationPort(UInt16.max)
                        }
                        ports.append(try PortRange(lowerBound: lower, upperBound: upper))
                    }
                }
            } catch {
                diagnostics.append(.init(severity: .error, code: "capture_rule_conversion_failed", subject: rule.id.rawValue.uuidString.lowercased(), message: "Rule could not be represented by the application capture provider: \(error.localizedDescription)"))
                continue
            }

            let action: CaptureAction
            switch rule.action {
            case .direct: action = .direct
            case .reject: action = .reject
            case let .proxyGroup(groupID):
                guard let name = groupNames[groupID] else {
                    diagnostics.append(.init(severity: .error, code: "capture_rule_missing_group", subject: rule.id.rawValue.uuidString.lowercased(), message: "Rule targets a proxy group that is not available."))
                    continue
                }
                action = .mihomo(.group(name))
            }
            do {
                let captureRule = try CaptureRule(
                    id: rule.id.rawValue.uuidString.lowercased(),
                    enabled: rule.enabled,
                    priority: rule.priority,
                    sources: sources,
                    destinations: destinations,
                    protocols: protocols,
                    portRanges: ports,
                    action: action,
                    unavailableFallback: rule.unavailableFallback == .direct ? .direct : .reject
                )
                converted.append(captureRule)
            } catch {
                diagnostics.append(.init(severity: .error, code: "capture_rule_invalid", subject: rule.id.rawValue.uuidString.lowercased(), message: "Rule could not be activated for application capture: \(error.localizedDescription)"))
            }
        }
        return Result(rules: converted, diagnostics: diagnostics.sorted { $0.id < $1.id })
    }

    private static func stableRuleOrder(_ lhs: RoutingRule, _ rhs: RoutingRule) -> Bool {
        if lhs.priority == rhs.priority { return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString }
        return lhs.priority < rhs.priority
    }
}
