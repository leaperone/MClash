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

extension ConfigurationModelError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidNodeEndpoint(host, port):
            AppLocalization.format(
                "The node endpoint %@:%d is invalid.",
                host,
                port
            )
        }
    }
}

/// Validates references before a compiler or runtime is allowed to consume a workspace.
/// Diagnostics are sorted by stable code/subject, making output suitable for previews and tests.
public enum ConfigurationValidator {
    public static func validate(workspace: Workspace, nodes: [Node], groups: [ProxyGroup], rules: [RoutingRule], ruleSets: [RuleSet] = [], dnsPolicies: [DNSPolicy], entrances: [Entrance]) -> [ConfigurationDiagnostic] {
        var result: [ConfigurationDiagnostic] = []
        let nodeIDs = Set(nodes.map(\.id)); let groupIDs = Set(groups.map(\.id)); let ruleIDs = Set(rules.map(\.id)); let setIDs = Set(ruleSets.map(\.id)); let entranceIDs = Set(entrances.map(\.id)); let dnsIDs = Set(dnsPolicies.map(\.id))
        let workspaceNodes = nodes.filter { workspace.nodeIDs.contains($0.id) && $0.enabled }
        let workspaceGroups = groups.filter { workspace.proxyGroupIDs.contains($0.id) && $0.enabled }
        let workspaceRuleSets = ruleSets.filter { workspace.ruleSetIDs.contains($0.id) }
        let enabledNodeIDs = Set(workspaceNodes.map(\.id))
        let enabledGroupIDs = Set(workspaceGroups.map(\.id))
        result += duplicateDiagnostics(nodes.map(\.id), code: "duplicate_node", message: AppLocalization.string("Node catalog contains duplicate identities."))
        result += duplicateDiagnostics(groups.map(\.id), code: "duplicate_group", message: AppLocalization.string("Configuration contains duplicate proxy group identities."))
        result += duplicateDiagnostics(rules.map(\.id), code: "duplicate_rule", message: AppLocalization.string("Configuration contains duplicate routing rule identities."))
        result += duplicateDiagnostics(workspace.nodeIDs, code: "duplicate_workspace_node", message: AppLocalization.string("A workspace cannot reference the same node more than once."))
        result += duplicateDiagnostics(workspace.proxyGroupIDs, code: "duplicate_workspace_group", message: AppLocalization.string("A workspace cannot reference the same proxy group more than once."))
        result += duplicateDiagnostics(workspace.ruleIDs, code: "duplicate_workspace_rule", message: AppLocalization.string("A workspace cannot reference the same routing rule more than once."))
        result += duplicateDiagnostics(workspace.ruleSetIDs, code: "duplicate_workspace_ruleset", message: AppLocalization.string("A workspace cannot reference the same rule set more than once."))
        result += duplicateDiagnostics(workspace.entranceIDs, code: "duplicate_workspace_entrance", message: AppLocalization.string("A workspace cannot reference the same entrance more than once."))
        var runtimeNames: [Data: [String]] = [:]
        for node in workspaceNodes {
            let name = node.userAlias ?? node.displayName
            let subject = node.id.rawValue.uuidString.lowercased()
            if invalidNodeName(name) {
                result.append(.init(severity: .error, code: "invalid_node_name", subject: subject, message: AppLocalization.string("Node names cannot be empty or contain line breaks.")))
            }
            if !(1...65_535).contains(node.port) {
                result.append(.init(severity: .error, code: "invalid_node_port", subject: subject, message: AppLocalization.string("Node ports must be between 1 and 65535.")))
            }
            let runtimeName = Data(name.utf8)
            if reservedRuntimeNames.contains(runtimeName) {
                result.append(.init(severity: .error, code: "reserved_runtime_name", subject: subject, message: AppLocalization.string("Nodes and proxy groups cannot use reserved Mihomo runtime names.")))
            }
            runtimeNames[runtimeName, default: []].append(subject)
        }
        for group in workspaceGroups {
            let subject = group.id.rawValue.uuidString.lowercased()
            if invalidGroupName(group.name) {
                result.append(.init(severity: .error, code: "invalid_group_name", subject: subject, message: AppLocalization.string("Proxy group names cannot be empty or contain commas or line breaks.")))
            }
            let runtimeName = Data(group.name.utf8)
            if reservedRuntimeNames.contains(runtimeName) {
                result.append(.init(severity: .error, code: "reserved_runtime_name", subject: subject, message: AppLocalization.string("Nodes and proxy groups cannot use reserved Mihomo runtime names.")))
            }
            runtimeNames[runtimeName, default: []].append(subject)
        }
        for subjects in runtimeNames.values where subjects.count > 1 {
            for subject in subjects {
                result.append(.init(severity: .error, code: "duplicate_runtime_name", subject: subject, message: AppLocalization.string("Nodes and proxy groups in a workspace must have unique runtime names.")))
            }
        }
        var ruleSetRuntimeNames: [Data: [String]] = [:]
        for ruleSet in workspaceRuleSets {
            let subject = ruleSet.id.rawValue.uuidString.lowercased()
            if ruleSet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.init(severity: .error, code: "invalid_ruleset_name", subject: subject, message: AppLocalization.string("Rule set name cannot be empty.")))
            }
            if ruleSet.sourceURL != nil {
                let runtimeName = ConfigurationCompiler.ruleSetRuntimeName(ruleSet.name)
                ruleSetRuntimeNames[Data(runtimeName.utf8), default: []].append(subject)
            }
        }
        for subjects in ruleSetRuntimeNames.values where subjects.count > 1 {
            for subject in subjects {
                result.append(.init(severity: .error, code: "duplicate_ruleset_runtime_name", subject: subject, message: AppLocalization.string("Rule sets in a workspace must have unique runtime names.")))
            }
        }
        for id in workspace.nodeIDs where !nodeIDs.contains(id) { result.append(.init(severity: .error, code: "missing_node", subject: String(describing: id.rawValue), message: AppLocalization.string("Workspace references a node that is not in the catalog."))) }
        for node in nodes where workspace.nodeIDs.contains(node.id) && node.proto == .unknown {
            result.append(.init(severity: .error, code: "unsupported_node_protocol", subject: String(describing: node.id.rawValue), message: AppLocalization.string("Workspace references a node with an unsupported protocol.")))
        }
        for node in nodes where workspace.nodeIDs.contains(node.id) {
            for (key, value) in node.parameters where key.isEmpty || key.contains(where: { $0 == "\n" || $0 == "\r" || $0 == ":" }) || value.contains(where: { $0 == "\n" || $0 == "\r" }) {
                result.append(.init(severity: .error, code: "invalid_node_parameter", subject: String(describing: node.id.rawValue), message: AppLocalization.string("Node parameters contain an unsafe YAML key or value.")))
                break
            }
        }
        for id in workspace.proxyGroupIDs where !groupIDs.contains(id) { result.append(.init(severity: .error, code: "missing_group", subject: String(describing: id.rawValue), message: AppLocalization.string("Workspace references a proxy group that does not exist."))) }
        for id in workspace.ruleIDs where !ruleIDs.contains(id) { result.append(.error("missing_rule", id, AppLocalization.string("Workspace references a routing rule that does not exist."))) }
        for id in workspace.ruleSetIDs where !setIDs.contains(id) { result.append(.error("missing_ruleset", id, AppLocalization.string("Workspace references a rule set that does not exist."))) }
        for id in workspace.entranceIDs where !entranceIDs.contains(id) { result.append(.error("missing_entrance", id, AppLocalization.string("Workspace references an entrance that does not exist."))) }
        let enabledEntrances = entrances.filter { workspace.entranceIDs.contains($0.id) && $0.enabled }
        for entrance in enabledEntrances {
            validate(
                action: entrance.defaultAction,
                availableGroupIDs: enabledGroupIDs,
                code: "unavailable_entrance_target",
                subject: entrance.id.rawValue,
                message: AppLocalization.string("Routing rule targets a missing proxy group."),
                into: &result
            )
        }
        let enabledPortEntrances = enabledEntrances.filter {
            $0.kind == .http || $0.kind == .socks5
        }
        var ports: [Int: EntranceID] = [:]
        for entrance in enabledPortEntrances {
            guard let port = entrance.port, (1...65_535).contains(port) else {
                result.append(.init(severity: .error, code: "invalid_entrance_port", subject: String(describing: entrance.id.rawValue), message: AppLocalization.string("Entrance port must be between 1 and 65535.")))
                continue
            }
            if ports[port] != nil {
                result.append(.init(severity: .error, code: "duplicate_entrance_port", subject: String(port), message: AppLocalization.string("Enabled entrances cannot share a listening port.")))
            } else {
                ports[port] = entrance.id
            }
            if entrance.bindAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.init(severity: .error, code: "invalid_bind_address", subject: String(describing: entrance.id.rawValue), message: AppLocalization.string("An enabled entrance requires a bind address.")))
            }
        }
        let bindAddresses = Set(enabledPortEntrances.map { $0.bindAddress.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        if bindAddresses.count > 1 {
            result.append(.init(severity: .error, code: "inconsistent_bind_addresses", subject: "entrances", message: AppLocalization.string("Enabled HTTP and SOCKS entrances must share one Mihomo bind address.")))
        }
        guard dnsIDs.contains(workspace.dnsPolicyID) else { result.append(.error("missing_dns_policy", workspace.dnsPolicyID, AppLocalization.string("Workspace references a DNS policy that does not exist."))); return sorted(result) }
        for group in groups where enabledGroupIDs.contains(group.id) {
            if group.members.isEmpty && group.type != .direct && group.type != .reject {
                result.append(.init(severity: .error, code: "empty_group", subject: String(describing: group.id.rawValue), message: AppLocalization.string("Proxy group has no members.")))
            }
            guard group.type != .direct && group.type != .reject else { continue }
            for member in group.members {
                switch member {
                case let .node(id):
                    if !nodeIDs.contains(id) {
                        result.append(.error("missing_group_node", id, AppLocalization.string("Proxy group references a missing node.")))
                    } else if !enabledNodeIDs.contains(id) {
                        result.append(.error("group_node_outside_workspace", id, AppLocalization.string("Proxy group references a node that is not included in this workspace.")))
                    }
                case let .group(id):
                    if !groupIDs.contains(id) {
                        result.append(.error("missing_nested_group", id, AppLocalization.string("Proxy group references a missing group.")))
                    } else if !enabledGroupIDs.contains(id) {
                        result.append(.error("group_outside_workspace", id, AppLocalization.string("Proxy group references a group that is not included in this workspace.")))
                    }
                }
            }
        }
        // Nested groups must form a DAG; cycle reporting is anchored to the lowest
        // stable UUID so the same invalid graph always produces the same diagnostic.
        let groupMap = Dictionary(
            groups.filter { enabledGroupIDs.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for group in groups where enabledGroupIDs.contains(group.id) {
            if hasCycle(from: group.id, map: groupMap, visiting: [], visited: []) {
                result.append(.init(severity: .error, code: "group_cycle", subject: String(describing: group.id.rawValue), message: AppLocalization.string("Proxy group references itself through nested groups.")))
            }
        }
        for rule in rules where workspace.ruleIDs.contains(rule.id) && rule.enabled {
            if let scope = rule.workspaceScope, scope != workspace.id {
                result.append(.init(severity: .error, code: "rule_outside_workspace", subject: String(describing: rule.id.rawValue), message: AppLocalization.string("Workspace references a routing rule that does not exist.")))
            }
            validate(
                action: rule.action,
                availableGroupIDs: enabledGroupIDs,
                code: "missing_rule_target",
                subject: rule.id.rawValue,
                message: AppLocalization.string("Routing rule targets a missing proxy group."),
                into: &result
            )
            if rule.matchers.isEmpty { result.append(.init(severity: .warning, code: "rule_matches_everything", subject: String(describing: rule.id.rawValue), message: AppLocalization.string("Routing rule has no matchers and may match all traffic."))) }
            for matcher in rule.matchers {
                switch matcher {
                case let .port(value) where !(1...65_535).contains(value):
                    result.append(.init(severity: .error, code: "invalid_rule_port", subject: String(describing: rule.id.rawValue), message: AppLocalization.string("Rule ports must be between 1 and 65535.")))
                case let .portRange(value) where !(1...65_535).contains(value.lowerBound) || !(1...65_535).contains(value.upperBound):
                    result.append(.init(severity: .error, code: "invalid_rule_port", subject: String(describing: rule.id.rawValue), message: AppLocalization.string("Rule ports must be between 1 and 65535.")))
                default:
                    break
                }
                let value: String? = switch matcher {
                case let .application(value), let .processPath(value), let .domainExact(value), let .domainSuffix(value), let .domainWildcard(value), let .ipCIDR(value), let .transport(value): value
                case let .userID(value): String(value)
                case let .port(value): String(value)
                case let .portRange(value): "\(value.lowerBound)-\(value.upperBound)"
                }
                if value?.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "," }) == true {
                    result.append(.init(severity: .error, code: "invalid_rule_matcher", subject: String(describing: rule.id.rawValue), message: AppLocalization.string("Rule matchers must not contain commas or line breaks.")))
                    break
                }
            }
        }
        for ruleSet in workspaceRuleSets {
            validate(
                action: ruleSet.defaultAction,
                availableGroupIDs: enabledGroupIDs,
                code: "missing_ruleset_target",
                subject: ruleSet.id.rawValue,
                message: AppLocalization.string("Routing rule targets a missing proxy group."),
                into: &result
            )
            for rawRule in ruleSet.rules {
                let trimmed = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
                if trimmed.isEmpty || trimmed.contains(where: { $0 == "\n" || $0 == "\r" }) || (trimmed.contains(",") && parts.count < 2) {
                    result.append(.init(severity: .error, code: "invalid_ruleset_rule", subject: String(describing: ruleSet.id.rawValue), message: AppLocalization.string("Rule set contains an invalid rule entry.")))
                    break
                }
            }
        }
        return sorted(result)
    }

    private static func sorted(_ values: [ConfigurationDiagnostic]) -> [ConfigurationDiagnostic] { values.sorted { $0.id < $1.id } }

    private static let reservedRuntimeNames: Set<Data> = [
        Data("DIRECT".utf8),
        Data("REJECT".utf8),
        Data("REJECT-DROP".utf8),
        Data("COMPATIBLE".utf8),
        Data("PASS".utf8),
        Data("PASS-RULE".utf8),
        Data("GLOBAL".utf8),
    ]

    private static func invalidNodeName(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || value.contains(where: { $0 == "\n" || $0 == "\r" })
    }

    private static func invalidGroupName(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || value.contains(where: { $0 == "," || $0 == "\n" || $0 == "\r" })
    }

    private static func validate(
        action: RoutingAction,
        availableGroupIDs: Set<ProxyGroupID>,
        code: String,
        subject: UUID,
        message: String,
        into result: inout [ConfigurationDiagnostic]
    ) {
        guard case let .proxyGroup(id) = action, !availableGroupIDs.contains(id) else { return }
        result.append(.init(
            severity: .error,
            code: code,
            subject: subject.uuidString.lowercased(),
            message: message
        ))
    }

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
