import Foundation
import MClashAutomationProtocol

public enum XrayRuleRenderer {
    public static func rules(document: ConfigurationDocument, workspace: Workspace,
                             groupTags: [ProxyGroupID: String], capturedRuleIDs: Set<RoutingRuleID>) throws -> [AutomationJSONValue] {
        let scope = Set(workspace.ruleIDs)
        let ordered = document.rules.filter {
            $0.enabled && scope.contains($0.id) && ($0.workspaceScope == nil || $0.workspaceScope == workspace.id)
        }.sorted { $0.priority == $1.priority ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString : $0.priority < $1.priority }
        var result: [AutomationJSONValue] = []
        for rule in ordered {
            if capturedRuleIDs.contains(rule.id) { continue }
            let target = try action(rule.action, groups: groupTags)
            var fields = try matchers(rule.matchers)
            if fields.isEmpty { fields["network"] = .string("tcp,udp") }
            fields.merge(target) { _, value in value }
            fields["type"] = .string("field")
            fields["ruleTag"] = .string(rule.id.rawValue.uuidString.lowercased())
            result.append(.object(fields))
        }
        let sets = Dictionary(document.ruleSets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in workspace.ruleSetIDs {
            guard let ruleSet = sets[id], ruleSet.enabled else { continue }
            if ruleSet.rules.isEmpty, ruleSet.sourceURL != nil || ruleSet.path != nil {
                throw ConfigurationCompilationError.invalidText("Refresh the rule set before activating it with Xray: " + ruleSet.name)
            }
            if ruleSet.format == .mrs {
                throw ConfigurationCompilationError.invalidText("Xray requires a text or YAML rule set: " + ruleSet.name)
            }
            for (index, raw) in ruleSet.rules.enumerated() {
                guard let rule = try ruleSetLine(raw, behavior: ruleSet.behavior, fallback: ruleSet.defaultAction,
                    groups: document.proxyGroups, groupTags: groupTags, tag: "rs-\(id.rawValue.uuidString.lowercased())-\(index)") else { continue }
                result.append(rule)
            }
        }
        return result
    }

    public static func action(_ value: RoutingAction, groups: [ProxyGroupID: String]) throws -> [String: AutomationJSONValue] {
        switch value {
        case .direct: return ["outboundTag": .string("direct")]
        case .reject: return ["outboundTag": .string("reject")]
        case let .proxyGroup(id):
            guard let tag = groups[id] else { throw ConfigurationCompilationError.invalidText("Rule references an unavailable group.") }
            return ["balancerTag": .string(tag)]
        }
    }

    private static func matchers(_ values: [RoutingMatcher]) throws -> [String: AutomationJSONValue] {
        var domains: [String] = []
        var ips: [String] = []
        var ports: [String] = []
        var networks: [String] = []
        for matcher in values {
            switch matcher {
            case let .domainExact(value): domains.append("full:" + value)
            case let .domainSuffix(value): domains.append("domain:" + value)
            case let .domainWildcard(value):
                let escaped = NSRegularExpression.escapedPattern(for: value).replacingOccurrences(of: "\\*", with: ".*")
                domains.append("regexp:^" + escaped + "$")
            case let .geoSite(value): domains.append("geosite:" + value.lowercased())
            case let .ipCIDR(value): ips.append(value)
            case let .geoIP(value): ips.append("geoip:" + value.lowercased())
            case .geoIP6:
                throw ConfigurationCompilationError.invalidText("Use an IPv6 CIDR rule for IPv6-only country routing.")
            case let .port(value): ports.append(String(value))
            case let .portRange(value): ports.append("\(value.lowerBound)-\(value.upperBound)")
            case let .transport(value):
                guard value.lowercased() == "tcp" || value.lowercased() == "udp" else {
                    throw ConfigurationCompilationError.invalidText("Xray rule network must be TCP or UDP.")
                }
                networks.append(value.lowercased())
            case .application, .processPath, .processName, .userID:
                throw ConfigurationCompilationError.invalidText("Application and process rules require the App Routing entrance.")
            }
        }
        var fields: [String: AutomationJSONValue] = [:]
        if !domains.isEmpty { fields["domain"] = .array(domains.map(AutomationJSONValue.string)) }
        if !ips.isEmpty { fields["ip"] = .array(ips.map(AutomationJSONValue.string)) }
        if !ports.isEmpty { fields["port"] = .string(ports.joined(separator: ",")) }
        if !networks.isEmpty { fields["network"] = .string(networks.joined(separator: ",")) }
        return fields
    }

    private static func ruleSetLine(_ raw: String, behavior: RuleSetBehavior, fallback: RoutingAction,
                                    groups: [ProxyGroup], groupTags: [ProxyGroupID: String], tag: String) throws -> AutomationJSONValue? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { return nil }
        var target = fallback
        let condition: RoutingMatcher
        switch behavior {
        case .domain:
            if line.hasPrefix("+.") { condition = .domainSuffix(String(line.dropFirst(2))) }
            else if line.contains("*") { condition = .domainWildcard(line) }
            else { condition = .domainSuffix(line) }
        case .ipcidr:
            condition = .ipCIDR(line)
        case .classical:
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { throw ConfigurationCompilationError.invalidText("Rule set line is incomplete.") }
            switch parts[0].uppercased() {
            case "DOMAIN": condition = .domainExact(parts[1])
            case "DOMAIN-SUFFIX": condition = .domainSuffix(parts[1])
            case "DOMAIN-WILDCARD": condition = .domainWildcard(parts[1])
            case "IP-CIDR", "IP-CIDR6": condition = .ipCIDR(parts[1])
            case "GEOIP": condition = .geoIP(parts[1])
            case "GEOSITE": condition = .geoSite(parts[1])
            case "DST-PORT":
                guard let port = Int(parts[1]), (1...65535).contains(port) else {
                    throw ConfigurationCompilationError.invalidText("Rule set port is invalid.")
                }
                condition = .port(port)
            case "NETWORK": condition = .transport(parts[1])
            default: throw ConfigurationCompilationError.invalidText("Rule set matcher is not supported by Xray: " + parts[0])
            }
            if parts.count > 2, parts[2] != "no-resolve" {
                switch parts[2] {
                case "DIRECT": target = .direct
                case "REJECT": target = .reject
                default:
                    guard let group = groups.first(where: { $0.name == parts[2] }), groupTags[group.id] != nil else {
                        throw ConfigurationCompilationError.invalidText("Rule set references an unavailable group.")
                    }
                    target = .proxyGroup(group.id)
                }
            }
        }
        var fields = try matchers([condition])
        fields.merge(try action(target, groups: groupTags)) { _, value in value }
        fields["type"] = .string("field")
        fields["ruleTag"] = .string(tag)
        return .object(fields)
    }
}
