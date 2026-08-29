import Foundation

public enum ConfigurationDiagnosticSeverity: String, Codable, Hashable, Sendable { case warning, error }
public struct ConfigurationDiagnostic: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let severity: ConfigurationDiagnosticSeverity
    public let code: String
    public let subject: String
    public let message: String
    public init(severity: ConfigurationDiagnosticSeverity, code: String, subject: String, message: String) {
        self.severity=severity; self.code=code; self.subject=subject; self.message=message
        self.id = "\(severity.rawValue):\(code):\(subject)"
    }
}

public enum ConfigurationModelError: Error, Equatable, Sendable {
    case invalidNodeEndpoint(host: String, port: Int)
}

/// Validates references before a compiler or runtime is allowed to consume a workspace.
/// Diagnostics are sorted by stable code/subject, making output suitable for previews and tests.
public enum ConfigurationValidator {
    public static func validate(workspace: Workspace, nodes: [Node], groups: [ProxyGroup], rules: [RoutingRule], ruleSets: [RuleSet] = [], dnsPolicies: [DNSPolicy], entrances: [Entrance]) -> [ConfigurationDiagnostic] {
        var result: [ConfigurationDiagnostic] = []
        let nodeIDs = Set(nodes.map(\.id)); let groupIDs = Set(groups.map(\.id)); let ruleIDs = Set(rules.map(\.id)); let setIDs = Set(ruleSets.map(\.id)); let entranceIDs = Set(entrances.map(\.id)); let dnsIDs = Set(dnsPolicies.map(\.id))
        result += duplicateDiagnostics(nodes.map(\.id), code: "duplicate_node", message: "Node catalog contains duplicate identities.")
        result += duplicateDiagnostics(groups.map(\.id), code: "duplicate_group", message: "Configuration contains duplicate proxy group identities.")
        result += duplicateDiagnostics(rules.map(\.id), code: "duplicate_rule", message: "Configuration contains duplicate routing rule identities.")
        for id in workspace.nodeIDs where !nodeIDs.contains(id) { result.append(.init(severity: .error, code: "missing_node", subject: String(describing: id.rawValue), message: "Workspace references a node that is not in the catalog.")) }
        for node in nodes where workspace.nodeIDs.contains(node.id) && node.proto == .unknown {
            result.append(.init(severity: .error, code: "unsupported_node_protocol", subject: String(describing: node.id.rawValue), message: "Workspace references a node with an unsupported protocol."))
        }
        for node in nodes where workspace.nodeIDs.contains(node.id) {
            for (key, value) in node.parameters where key.isEmpty || key.contains(where: { $0 == "\n" || $0 == "\r" || $0 == ":" }) || value.contains(where: { $0 == "\n" || $0 == "\r" }) {
                result.append(.init(severity: .error, code: "invalid_node_parameter", subject: String(describing: node.id.rawValue), message: "Node parameters contain an unsafe YAML key or value."))
                break
            }
        }
        for id in workspace.proxyGroupIDs where !groupIDs.contains(id) { result.append(.init(severity: .error, code: "missing_group", subject: String(describing: id.rawValue), message: "Workspace references a proxy group that does not exist.")) }
        for id in workspace.ruleIDs where !ruleIDs.contains(id) { result.append(.error("missing_rule", id, "Workspace references a routing rule that does not exist.")) }
        for id in workspace.ruleSetIDs where !setIDs.contains(id) { result.append(.error("missing_ruleset", id, "Workspace references a rule set that does not exist.")) }
        for id in workspace.entranceIDs where !entranceIDs.contains(id) { result.append(.error("missing_entrance", id, "Workspace references an entrance that does not exist.")) }
        let enabledEntrances = entrances.filter { workspace.entranceIDs.contains($0.id) && $0.enabled }
        var ports: [Int: EntranceID] = [:]
        for entrance in enabledEntrances {
            if let port = entrance.port {
                if !(1...65_535).contains(port) {
                    result.append(.init(severity: .error, code: "invalid_entrance_port", subject: String(describing: entrance.id.rawValue), message: "Entrance port must be between 1 and 65535."))
                } else if ports[port] != nil {
                    result.append(.init(severity: .error, code: "duplicate_entrance_port", subject: String(port), message: "Enabled entrances cannot share a listening port."))
                } else {
                    ports[port] = entrance.id
                }
            }
            if entrance.bindAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.init(severity: .error, code: "invalid_bind_address", subject: String(describing: entrance.id.rawValue), message: "An enabled entrance requires a bind address."))
            }
        }
        let bindAddresses = Set(enabledEntrances.map { $0.bindAddress.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        if bindAddresses.count > 1 {
            result.append(.init(severity: .error, code: "inconsistent_bind_addresses", subject: "entrances", message: "Enabled HTTP and SOCKS entrances must share one Mihomo bind address."))
        }
        guard dnsIDs.contains(workspace.dnsPolicyID) else { result.append(.error("missing_dns_policy", workspace.dnsPolicyID, "Workspace references a DNS policy that does not exist.")); return sorted(result) }
        for group in groups where workspace.proxyGroupIDs.contains(group.id) {
            if group.members.isEmpty && group.type != .direct && group.type != .reject {
                result.append(.init(severity: workspace.nodeIDs.isEmpty ? .warning : .error, code: "empty_group", subject: String(describing: group.id.rawValue), message: "Proxy group has no members."))
            }
            for member in group.members {
                switch member {
                case let .node(id):
                    if !nodeIDs.contains(id) {
                        result.append(.error("missing_group_node", id, "Proxy group references a missing node."))
                    } else if !workspace.nodeIDs.contains(id) {
                        result.append(.error("group_node_outside_workspace", id, "Proxy group references a node that is not included in this workspace."))
                    }
                case let .group(id):
                    if !groupIDs.contains(id) {
                        result.append(.error("missing_nested_group", id, "Proxy group references a missing group."))
                    } else if !workspace.proxyGroupIDs.contains(id) {
                        result.append(.error("group_outside_workspace", id, "Proxy group references a group that is not included in this workspace."))
                    }
                }
            }
        }
        // Nested groups must form a DAG; cycle reporting is anchored to the lowest
        // stable UUID so the same invalid graph always produces the same diagnostic.
        let groupMap = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        for group in groups where workspace.proxyGroupIDs.contains(group.id) {
            if hasCycle(from: group.id, map: groupMap, visiting: [], visited: []) {
                result.append(.init(severity: .error, code: "group_cycle", subject: String(describing: group.id.rawValue), message: "Proxy group references itself through nested groups."))
            }
        }
        for rule in rules where workspace.ruleIDs.contains(rule.id) {
            if case let .proxyGroup(id) = rule.action, !groupIDs.contains(id) { result.append(.error("missing_rule_target", id, "Routing rule targets a missing proxy group.")) }
            if rule.matchers.isEmpty { result.append(.init(severity: .warning, code: "rule_matches_everything", subject: String(describing: rule.id.rawValue), message: "Routing rule has no matchers and may match all traffic.")) }
            for matcher in rule.matchers {
                let value: String? = switch matcher {
                case let .application(value), let .processPath(value), let .domainExact(value), let .domainSuffix(value), let .domainWildcard(value), let .ipCIDR(value), let .transport(value): value
                case let .userID(value): String(value)
                case let .port(value): String(value)
                case let .portRange(value): "\(value.lowerBound)-\(value.upperBound)"
                }
                if value?.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "," }) == true {
                    result.append(.init(severity: .error, code: "invalid_rule_matcher", subject: String(describing: rule.id.rawValue), message: "Rule matchers must not contain commas or line breaks."))
                    break
                }
            }
        }
        for ruleSet in ruleSets where workspace.ruleSetIDs.contains(ruleSet.id) {
            if ruleSet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.init(severity: .error, code: "invalid_ruleset_name", subject: String(describing: ruleSet.id.rawValue), message: "Rule set name cannot be empty."))
            }
            for rawRule in ruleSet.rules {
                let trimmed = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
                if trimmed.isEmpty || trimmed.contains(where: { $0 == "\n" || $0 == "\r" }) || (trimmed.contains(",") && parts.count < 2) {
                    result.append(.init(severity: .error, code: "invalid_ruleset_rule", subject: String(describing: ruleSet.id.rawValue), message: "Rule set contains an invalid rule entry."))
                    break
                }
            }
        }
        return sorted(result)
    }

    private static func sorted(_ values: [ConfigurationDiagnostic]) -> [ConfigurationDiagnostic] { values.sorted { $0.id < $1.id } }

    private static func duplicateDiagnostics<ID: Hashable & Sendable>(_ values: [ID], code: String, message: String) -> [ConfigurationDiagnostic] {
        var counts: [ID: Int] = [:]; values.forEach { counts[$0, default: 0] += 1 }
        return counts.filter { $0.value > 1 }.map { .init(severity: .error, code: code, subject: String(describing: $0.key), message: message) }
    }

    private static func hasCycle(from id: ProxyGroupID, map: [ProxyGroupID: ProxyGroup], visiting: [ProxyGroupID], visited: [ProxyGroupID]) -> Bool {
        if visiting.contains(id) { return true }; if visited.contains(id) { return false }
        guard let group = map[id] else { return false }
        let nextVisiting = visiting + [id]
        return group.members.contains { member in if case let .group(next) = member { return hasCycle(from: next, map: map, visiting: nextVisiting, visited: visited) }; return false }
    }
}

private extension ConfigurationDiagnostic {
    static func error<ID: RawRepresentable>(_ code: String, _ subject: ID, _ message: String) -> Self where ID.RawValue: CustomStringConvertible {
        .init(severity: .error, code: code, subject: String(describing: subject.rawValue), message: message)
    }
}
