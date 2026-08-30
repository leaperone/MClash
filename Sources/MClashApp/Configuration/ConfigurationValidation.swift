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
        let resourceDiagnostics = workspaceResourceDiagnostics(
            workspace: workspace,
            groups: groups,
            rules: rules,
            ruleSets: ruleSets,
            dnsPolicies: dnsPolicies,
            entrances: entrances
        )
        guard resourceDiagnostics.isEmpty else { return sorted(resourceDiagnostics) }
        let nodeIDs = Set(nodes.map(\.id)); let groupIDs = Set(groups.map(\.id)); let ruleIDs = Set(rules.map(\.id)); let setIDs = Set(ruleSets.map(\.id)); let entranceIDs = Set(entrances.map(\.id)); let dnsIDs = Set(dnsPolicies.map(\.id))
        let workspaceNodeIDs = Set(workspace.nodeIDs)
        let workspaceGroupIDs = Set(workspace.proxyGroupIDs)
        let workspaceRuleIDs = Set(workspace.ruleIDs)
        let workspaceRuleSetIDs = Set(workspace.ruleSetIDs)
        let workspaceEntranceIDs = Set(workspace.entranceIDs)
        let workspaceNodes = nodes.filter { workspaceNodeIDs.contains($0.id) && $0.enabled }
        let workspaceGroups = groups.filter { workspaceGroupIDs.contains($0.id) && $0.enabled }
        let workspaceRuleSets = ruleSets.filter { workspaceRuleSetIDs.contains($0.id) }
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
        for node in nodes where workspaceNodeIDs.contains(node.id) && node.proto == .unknown {
            result.append(.init(severity: .error, code: "unsupported_node_protocol", subject: String(describing: node.id.rawValue), message: AppLocalization.string("Workspace references a node with an unsupported protocol.")))
        }
        for node in nodes where workspaceNodeIDs.contains(node.id) {
            for (key, value) in node.parameters where key.isEmpty || key.contains(where: { $0 == "\n" || $0 == "\r" || $0 == ":" }) || value.contains(where: { $0 == "\n" || $0 == "\r" }) {
                result.append(.init(severity: .error, code: "invalid_node_parameter", subject: String(describing: node.id.rawValue), message: AppLocalization.string("Node parameters contain an unsafe YAML key or value.")))
                break
            }
            if node.parameters.keys.contains(where: {
                ["name", "type", "server", "port"].contains(
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                )
            }) {
                result.append(.init(severity: .error, code: "reserved_node_parameter", subject: String(describing: node.id.rawValue), message: AppLocalization.string("Node parameters cannot override name, type, server, or port.")))
            }
        }
        for id in workspace.proxyGroupIDs where !groupIDs.contains(id) { result.append(.init(severity: .error, code: "missing_group", subject: String(describing: id.rawValue), message: AppLocalization.string("Workspace references a proxy group that does not exist."))) }
        for id in workspace.ruleIDs where !ruleIDs.contains(id) { result.append(.error("missing_rule", id, AppLocalization.string("Workspace references a routing rule that does not exist."))) }
        for id in workspace.ruleSetIDs where !setIDs.contains(id) { result.append(.error("missing_ruleset", id, AppLocalization.string("Workspace references a rule set that does not exist."))) }
        for id in workspace.entranceIDs where !entranceIDs.contains(id) { result.append(.error("missing_entrance", id, AppLocalization.string("Workspace references an entrance that does not exist."))) }
        let workspaceEntrances = entrances.filter { workspaceEntranceIDs.contains($0.id) }
        let enabledEntrances = workspaceEntrances.filter(\.enabled)
        for entrance in workspaceEntrances where entrance.workspaceOverride != nil {
            result.append(.init(severity: .error, code: "unsupported_entrance_workspace_override", subject: String(describing: entrance.id.rawValue), message: AppLocalization.string("Entrance workspace overrides are not supported.")))
        }
        for entrance in enabledEntrances where entrance.kind == .tun {
            result.append(.init(severity: .error, code: "unsupported_tun_entrance", subject: String(describing: entrance.id.rawValue), message: AppLocalization.string("TUN entrances are not supported.")))
        }
        for kind in EntranceKind.allCases
            where enabledEntrances.filter({ $0.kind == kind }).count > 1 {
            result.append(.init(severity: .error, code: "duplicate_entrance_kind", subject: kind.rawValue, message: AppLocalization.string("Only one enabled entrance of each kind is supported per workspace.")))
        }
        if Set(enabledEntrances.map(\.defaultAction)).count > 1 {
            result.append(.init(severity: .error, code: "inconsistent_entrance_default_action", subject: "entrances", message: AppLocalization.string("Enabled entrances must use the same default action.")))
        }
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
            if group.type == .relay {
                result.append(.init(severity: .error, code: "unsupported_relay_group", subject: String(describing: group.id.rawValue), message: AppLocalization.string("Relay proxy groups are not supported by the bundled Mihomo core.")))
            }
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
        var groupStates: [ProxyGroupID: GroupVisitState] = [:]
        var groupMemo: [ProxyGroupID: GroupTraversalResult] = [:]
        for group in groups where enabledGroupIDs.contains(group.id) {
            let traversal = traverseGroup(
                from: group.id,
                map: groupMap,
                depth: 1,
                states: &groupStates,
                memo: &groupMemo
            )
            if traversal.hasCycle {
                result.append(.init(severity: .error, code: "group_cycle", subject: String(describing: group.id.rawValue), message: AppLocalization.string("Proxy group references itself through nested groups.")))
            }
            if traversal.depthExceeded {
                result.append(.init(severity: .error, code: "group_nesting_too_deep", subject: String(describing: group.id.rawValue), message: AppLocalization.string("Proxy group nesting cannot exceed 64 levels.")))
            }
        }
        var workspaceExpansion = 0
        var workspaceExpansionExceeded = false
        for rule in rules where workspaceRuleIDs.contains(rule.id) && rule.enabled {
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
            let categoryCounts = matcherCategoryCounts(rule)
            if [categoryCounts.destinations, categoryCounts.ports, categoryCounts.transports]
                .filter({ $0 > 0 }).count > 1 {
                result.append(.init(severity: .error, code: "unsupported_rule_matcher_combination", subject: String(describing: rule.id.rawValue), message: AppLocalization.string("A routing rule cannot combine destination, port, and transport matchers.")))
            }
            if let expansion = matcherExpansionCount(rule),
               expansion <= ConfigurationAutomationLimits.matcherExpansionPerRule {
                let (updated, overflow) = workspaceExpansion.addingReportingOverflow(expansion)
                if overflow || updated > ConfigurationAutomationLimits.matcherExpansionPerWorkspace {
                    workspaceExpansionExceeded = true
                } else {
                    workspaceExpansion = updated
                }
            } else {
                result.append(.init(severity: .error, code: "rule_expansion_limit", subject: String(describing: rule.id.rawValue), message: AppLocalization.string("Routing rules expand beyond the supported limit.")))
            }
            for matcher in rule.matchers {
                switch matcher {
                case let .port(value) where !(1...65_535).contains(value):
                    result.append(.init(severity: .error, code: "invalid_rule_port", subject: String(describing: rule.id.rawValue), message: AppLocalization.string("Rule ports must be between 1 and 65535.")))
                case let .portRange(value) where !(1...65_535).contains(value.lowerBound) || !(1...65_535).contains(value.upperBound):
                    result.append(.init(severity: .error, code: "invalid_rule_port", subject: String(describing: rule.id.rawValue), message: AppLocalization.string("Rule ports must be between 1 and 65535.")))
                case let .transport(value) where !["tcp", "udp"].contains(value.lowercased()):
                    result.append(.init(severity: .error, code: "invalid_rule_transport", subject: String(describing: rule.id.rawValue), message: AppLocalization.string("Routing rule transport must be TCP or UDP.")))
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
        if workspaceExpansionExceeded {
            result.append(.init(severity: .error, code: "workspace_rule_expansion_limit", subject: String(describing: workspace.id.rawValue), message: AppLocalization.string("Routing rules expand beyond the supported limit.")))
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
                let allowedTypes = ["DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "IP-CIDR", "IP-CIDR6"]
                let validTypedRule = parts.count == 2
                    && allowedTypes.contains(String(parts[0]))
                    && !String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if trimmed.isEmpty
                    || trimmed.contains(where: { $0 == "\n" || $0 == "\r" })
                    || (trimmed.contains(",") && !validTypedRule) {
                    result.append(.init(severity: .error, code: "invalid_ruleset_rule", subject: String(describing: ruleSet.id.rawValue), message: AppLocalization.string("Rule set contains an invalid rule entry.")))
                    break
                }
            }
        }
        if let dns = dnsPolicies.first(where: { $0.id == workspace.dnsPolicyID }),
           dnsExpansionCount(dns).map({
               $0 > ConfigurationAutomationLimits.dnsExpansionPerWorkspace
           }) != false {
            result.append(.init(severity: .error, code: "dns_expansion_limit", subject: String(describing: dns.id.rawValue), message: AppLocalization.string("DNS rules expand beyond the supported limit.")))
        }
        return sorted(result)
    }

    private static func sorted(_ values: [ConfigurationDiagnostic]) -> [ConfigurationDiagnostic] { values.sorted { $0.id < $1.id } }

    static func automationPlanDiagnostics(
        document: ConfigurationDocument
    ) -> [ConfigurationDiagnostic] {
        var result: [ConfigurationDiagnostic] = []
        func appendLimit(_ exceeded: Bool, _ subject: String) {
            guard exceeded else { return }
            result.append(resourceLimitDiagnostic(subject: subject))
        }
        appendLimit(document.proxyGroups.count > ConfigurationAutomationLimits.proxyGroups, "proxyGroups")
        appendLimit(document.rules.count > ConfigurationAutomationLimits.rules, "rules")
        appendLimit(document.ruleSets.count > ConfigurationAutomationLimits.ruleSets, "ruleSets")
        appendLimit(document.dnsPolicies.count > ConfigurationAutomationLimits.dnsPolicies, "dnsPolicies")
        appendLimit(document.entrances.count > ConfigurationAutomationLimits.entrances, "entrances")
        appendLimit(document.workspaces.count > ConfigurationAutomationLimits.workspaces, "workspaces")
        for group in document.proxyGroups {
            appendLimit(
                group.members.count > ConfigurationAutomationLimits.groupMembers,
                "proxyGroups.\(group.id.rawValue.uuidString.lowercased()).members"
            )
        }
        for rule in document.rules {
            appendLimit(
                rule.matchers.count > ConfigurationAutomationLimits.ruleMatchers,
                "rules.\(rule.id.rawValue.uuidString.lowercased()).matchers"
            )
        }
        for ruleSet in document.ruleSets {
            appendLimit(
                ruleSet.rules.count > ConfigurationAutomationLimits.ruleSetRules,
                "ruleSets.\(ruleSet.id.rawValue.uuidString.lowercased()).rules"
            )
        }
        for dns in document.dnsPolicies {
            let subject = "dnsPolicies.\(dns.id.rawValue.uuidString.lowercased())"
            appendLimit(
                dns.nameservers.count > ConfigurationAutomationLimits.dnsNameservers,
                "\(subject).nameservers"
            )
            appendLimit(
                dns.fallbackNameservers.count > ConfigurationAutomationLimits.dnsNameservers,
                "\(subject).fallbackNameservers"
            )
            appendLimit(
                dns.rules.count > ConfigurationAutomationLimits.dnsRules,
                "\(subject).rules"
            )
        }
        for workspace in document.workspaces {
            appendLimit(
                workspace.nodeIDs.count > ConfigurationAutomationLimits.workspaceNodeIDs,
                "workspaces.\(workspace.id.rawValue.uuidString.lowercased()).nodeIDs"
            )
        }
        guard result.isEmpty else { return sorted(result) }

        let rulesByID = Dictionary(
            document.rules.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let dnsByID = Dictionary(
            document.dnsPolicies.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var matcherTotal = 0
        var dnsTotal = 0
        var matcherExceeded = false
        var dnsExceeded = false
        for workspace in document.workspaces {
            for id in Set(workspace.ruleIDs) {
                guard let rule = rulesByID[id], rule.enabled else { continue }
                guard let count = matcherExpansionCount(rule) else {
                    matcherExceeded = true
                    continue
                }
                let (updated, overflow) = matcherTotal.addingReportingOverflow(count)
                if overflow || updated > ConfigurationAutomationLimits.matcherExpansionPerPlan {
                    matcherExceeded = true
                } else {
                    matcherTotal = updated
                }
            }
            if let dns = dnsByID[workspace.dnsPolicyID] {
                guard let count = dnsExpansionCount(dns) else {
                    dnsExceeded = true
                    continue
                }
                let (updated, overflow) = dnsTotal.addingReportingOverflow(count)
                if overflow || updated > ConfigurationAutomationLimits.dnsExpansionPerPlan {
                    dnsExceeded = true
                } else {
                    dnsTotal = updated
                }
            }
        }
        if matcherExceeded {
            result.append(.init(severity: .error, code: "configuration_rule_expansion_limit", subject: "rules", message: AppLocalization.string("Routing rules expand beyond the supported limit.")))
        }
        if dnsExceeded {
            result.append(.init(severity: .error, code: "configuration_dns_expansion_limit", subject: "dnsPolicies", message: AppLocalization.string("DNS rules expand beyond the supported limit.")))
        }
        return sorted(result)
    }

    private static func workspaceResourceDiagnostics(
        workspace: Workspace,
        groups: [ProxyGroup],
        rules: [RoutingRule],
        ruleSets: [RuleSet],
        dnsPolicies: [DNSPolicy],
        entrances: [Entrance]
    ) -> [ConfigurationDiagnostic] {
        var result: [ConfigurationDiagnostic] = []
        func appendLimit(_ exceeded: Bool, _ subject: String) {
            guard exceeded else { return }
            result.append(resourceLimitDiagnostic(subject: subject))
        }
        appendLimit(groups.count > ConfigurationAutomationLimits.proxyGroups, "proxyGroups")
        appendLimit(rules.count > ConfigurationAutomationLimits.rules, "rules")
        appendLimit(ruleSets.count > ConfigurationAutomationLimits.ruleSets, "ruleSets")
        appendLimit(dnsPolicies.count > ConfigurationAutomationLimits.dnsPolicies, "dnsPolicies")
        appendLimit(entrances.count > ConfigurationAutomationLimits.entrances, "entrances")
        appendLimit(workspace.nodeIDs.count > ConfigurationAutomationLimits.workspaceNodeIDs, "workspace.nodeIDs")
        for group in groups {
            appendLimit(group.members.count > ConfigurationAutomationLimits.groupMembers, String(describing: group.id.rawValue))
        }
        for rule in rules {
            appendLimit(rule.matchers.count > ConfigurationAutomationLimits.ruleMatchers, String(describing: rule.id.rawValue))
        }
        for ruleSet in ruleSets {
            appendLimit(ruleSet.rules.count > ConfigurationAutomationLimits.ruleSetRules, String(describing: ruleSet.id.rawValue))
        }
        for dns in dnsPolicies {
            appendLimit(
                dns.nameservers.count > ConfigurationAutomationLimits.dnsNameservers
                    || dns.fallbackNameservers.count > ConfigurationAutomationLimits.dnsNameservers
                    || dns.rules.count > ConfigurationAutomationLimits.dnsRules,
                String(describing: dns.id.rawValue)
            )
        }
        return result
    }

    private static func resourceLimitDiagnostic(subject: String) -> ConfigurationDiagnostic {
        .init(
            severity: .error,
            code: "configuration_resource_limit",
            subject: subject,
            message: AppLocalization.string("Configuration exceeds a supported resource limit.")
        )
    }

    private static func matcherCategoryCounts(
        _ rule: RoutingRule
    ) -> (destinations: Int, ports: Int, transports: Int) {
        var result = (destinations: 0, ports: 0, transports: 0)
        for matcher in rule.matchers {
            switch matcher {
            case .domainExact, .domainSuffix, .domainWildcard, .ipCIDR:
                result.destinations += 1
            case .port, .portRange:
                result.ports += 1
            case .transport:
                result.transports += 1
            case .application, .processPath, .userID:
                break
            }
        }
        return result
    }

    private static func matcherExpansionCount(_ rule: RoutingRule) -> Int? {
        let counts = matcherCategoryCounts(rule)
        let (first, firstOverflow) = max(counts.destinations, 1)
            .multipliedReportingOverflow(by: max(counts.ports, 1))
        guard !firstOverflow else { return nil }
        let (result, secondOverflow) = first.multipliedReportingOverflow(
            by: max(counts.transports, 1)
        )
        return secondOverflow ? nil : result
    }

    private static func dnsExpansionCount(_ dns: DNSPolicy) -> Int? {
        guard !dns.rules.isEmpty else { return 0 }
        let nameserverCount = dns.nameservers.isEmpty ? 2 : dns.nameservers.count
        let (result, overflow) = dns.rules.count.multipliedReportingOverflow(
            by: nameserverCount
        )
        return overflow ? nil : result
    }

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

    private enum GroupVisitState { case visiting, visited }

    private struct GroupTraversalResult {
        var hasCycle = false
        var depthExceeded = false
        var maxDepth = 1
    }

    private static func traverseGroup(
        from id: ProxyGroupID,
        map: [ProxyGroupID: ProxyGroup],
        depth: Int,
        states: inout [ProxyGroupID: GroupVisitState],
        memo: inout [ProxyGroupID: GroupTraversalResult]
    ) -> GroupTraversalResult {
        guard depth <= ConfigurationAutomationLimits.groupDepth else {
            return GroupTraversalResult(
                hasCycle: false,
                depthExceeded: true,
                maxDepth: 1
            )
        }
        if states[id] == .visiting {
            return GroupTraversalResult(
                hasCycle: true,
                depthExceeded: false,
                maxDepth: 0
            )
        }
        if states[id] == .visited {
            var cached = memo[id] ?? GroupTraversalResult()
            cached.depthExceeded = depth + cached.maxDepth - 1
                > ConfigurationAutomationLimits.groupDepth
            return cached
        }
        guard let group = map[id] else { return GroupTraversalResult() }

        states[id] = .visiting
        var result = GroupTraversalResult()
        for member in group.members {
            guard case let .group(next) = member else { continue }
            let nested = traverseGroup(
                from: next,
                map: map,
                depth: depth + 1,
                states: &states,
                memo: &memo
            )
            result.hasCycle = result.hasCycle || nested.hasCycle
            result.depthExceeded = result.depthExceeded || nested.depthExceeded
            result.maxDepth = max(result.maxDepth, nested.maxDepth + 1)
        }
        result.depthExceeded = result.depthExceeded
            || depth + result.maxDepth - 1 > ConfigurationAutomationLimits.groupDepth
        if result.depthExceeded {
            states[id] = nil
        } else {
            states[id] = .visited
            memo[id] = result
        }
        return result
    }
}

private extension ConfigurationDiagnostic {
    static func error<ID: RawRepresentable>(_ code: String, _ subject: ID, _ message: String) -> Self where ID.RawValue: CustomStringConvertible {
        .init(severity: .error, code: code, subject: String(describing: subject.rawValue), message: message)
    }
}
