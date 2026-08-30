import CryptoKit
import Foundation
import MClashNetworkShared

public struct CompiledConfiguration: Equatable, Sendable {
    public let workspaceID: WorkspaceID
    public let workspaceRevision: Int
    public let yaml: Data
    public let networkExtensionRules: [RoutingRule]
    public let captureRules: [CaptureRule]
    public let captureEnabled: Bool
    public let captureDNSEnabled: Bool
    public let diagnostics: [ConfigurationDiagnostic]
    public let configHash: String

    public init(
        workspaceID: WorkspaceID,
        workspaceRevision: Int,
        yaml: Data,
        networkExtensionRules: [RoutingRule],
        captureRules: [CaptureRule],
        captureEnabled: Bool,
        captureDNSEnabled: Bool,
        diagnostics: [ConfigurationDiagnostic]
    ) {
        self.workspaceID = workspaceID
        self.workspaceRevision = workspaceRevision
        self.yaml = yaml
        self.networkExtensionRules = networkExtensionRules
        self.captureRules = captureRules
        self.captureEnabled = captureEnabled
        self.captureDNSEnabled = captureDNSEnabled
        self.diagnostics = diagnostics
        self.configHash = SHA256.hash(data: yaml).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ConfigurationCompilationError: Error, Equatable, Sendable {
    case invalid([ConfigurationDiagnostic])
    case invalidText(String)
}

extension ConfigurationCompilationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalid(diagnostics):
            AppLocalization.format(
                "MClash could not generate a runtime configuration: %@",
                diagnostics.map(\.message).joined(separator: " ")
            )
        case let .invalidText(message): message
        }
    }
}

/// Deterministically renders the strategy-owned model into a minimal Mihomo
/// document. It intentionally starts from a blank document, so source YAML
/// sections can never leak into runtime configuration.
public struct ConfigurationCompiler: Sendable {
    public static let version = "mclash-config-1"

    public init() {}

    public func compile(
        document: ConfigurationDocument,
        workspaceID: WorkspaceID? = nil
    ) throws -> CompiledConfiguration {
        try compile(
            document: document,
            workspaceID: workspaceID,
            validatedDiagnostics: nil
        )
    }

    func compile(
        document: ConfigurationDocument,
        workspaceID: WorkspaceID?,
        validatedDiagnostics: [ConfigurationDiagnostic]?
    ) throws -> CompiledConfiguration {
        guard let workspace = workspaceID.flatMap({ id in document.workspaces.first(where: { $0.id == id }) }) ?? document.currentWorkspace else {
            throw ConfigurationCompilationError.invalidText(
                AppLocalization.string("No MClash workspace is configured.")
            )
        }
        var diagnostics = validatedDiagnostics ?? document.diagnostics(for: workspace)

        // Validation reports duplicate identities, but the compiler must not
        // trap while constructing lookup tables for that diagnostic path.
        let nodesByID = Dictionary(
            document.nodes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let groupsByID = Dictionary(
            document.proxyGroups.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let rulesByID = Dictionary(
            document.rules.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let ruleSetsByID = Dictionary(
            document.ruleSets.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let dnsByID = Dictionary(
            document.dnsPolicies.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let entrancesByID = Dictionary(
            document.entrances.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let dns = dnsByID[workspace.dnsPolicyID]
        // An empty workspace node scope is intentional: it means “the whole
        // enabled catalog”. This is the default and is what lets selector
        // backed groups follow subscription refreshes automatically.
        let workspaceNodes = workspace.nodeIDs.isEmpty
            ? document.nodes.filter(runtimeEligible)
            : workspace.nodeIDs.compactMap { nodesByID[$0] }.filter(runtimeEligible)
        let workspaceGroups = workspace.proxyGroupIDs.compactMap { groupsByID[$0] }.filter(\.enabled)
        let workspaceRuleSets = workspace.ruleSetIDs.compactMap { ruleSetsByID[$0] }
        let workspaceRules = workspace.ruleIDs.compactMap { rulesByID[$0] }.filter(\.enabled).sorted {
            if $0.priority == $1.priority { return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
            return $0.priority < $1.priority
        }
        let runtimeNodeNames = makeRuntimeNodeNames(
            workspaceNodes,
            reserving: Set(workspaceGroups.map { $0.name.lowercased() })
        )
        // Selectors are a user-facing membership policy, not a Mihomo field.
        // Resolve them against the current catalog immediately before render;
        // this is what makes a subscription refresh update dynamic members
        // without rewriting the saved group definition.
        let resolvedGroups = workspaceGroups.map { group -> ProxyGroup in
            let resolution = NodeSelectorResolver.resolve(selectors: group.memberSelectors, nodes: workspaceNodes)
            diagnostics.append(contentsOf: resolution.diagnostics)
            var merged = group
            let existingNodeIDs = Set(group.members.compactMap { member -> NodeID? in
                if case let .node(id) = member { return id }
                return nil
            })
            let additions = resolution.nodeIDs
                .filter { !existingNodeIDs.contains($0) }
                .map { ProxyGroupMember.node($0) }
            merged.members.append(contentsOf: additions)
            return merged
        }
        let errors = diagnostics.filter { $0.severity == .error }
        guard errors.isEmpty else { throw ConfigurationCompilationError.invalid(errors) }
        let yaml = render(
            nodes: workspaceNodes,
            nodeNames: runtimeNodeNames,
            groups: resolvedGroups,
            rules: workspaceRules,
            ruleSets: workspaceRuleSets,
            dns: dns,
            entrances: workspace.entranceIDs.compactMap { entrancesByID[$0] }
        )
        let yamlData = Data(yaml.utf8)
        guard yamlData.count <= ConfigurationAutomationLimits.compiledYAMLBytes else {
            throw ConfigurationCompilationError.invalidText(
                AppLocalization.string(
                    "Compiled configuration exceeds the supported size limit."
                )
            )
        }
        let appRules = workspaceRules.filter { rule in
            rule.matchers.contains { matcher in
                if case .application = matcher { return true }
                if case .processPath = matcher { return true }
                if case .userID = matcher { return true }
                return false
            }
        }
        let capture = ConfigurationCaptureAdapter.convert(
            from: appRules,
            groups: workspaceGroups,
            workspaceID: workspace.id
        )
        guard capture.diagnostics.isEmpty else {
            throw ConfigurationCompilationError.invalid(capture.diagnostics)
        }
        let catchAll = try CaptureRule(
            id: "mclash-compiled-workspace-catch-all",
            priority: .max,
            action: .mihomo(.profileRules),
            unavailableFallback: .reject
        )
        let workspaceEntrances = workspace.entranceIDs.compactMap { entrancesByID[$0] }
        return CompiledConfiguration(
            workspaceID: workspace.id,
            workspaceRevision: workspace.revision,
            yaml: yamlData,
            networkExtensionRules: appRules,
            captureRules: capture.rules + [catchAll],
            captureEnabled: workspaceEntrances.contains {
                $0.kind == .appRouting && $0.enabled
            },
            captureDNSEnabled: dns?.takeoverEnabled == true,
            diagnostics: diagnostics,
        )
    }

    private func render(
        nodes: [Node],
        nodeNames: [NodeID: String],
        groups: [ProxyGroup],
        rules: [RoutingRule],
        ruleSets: [RuleSet],
        dns: DNSPolicy?,
        entrances: [Entrance]
    ) -> String {
        let enabledPortEntrances = entrances.filter { ($0.kind == .http || $0.kind == .socks5) && $0.enabled }
        let bindAddress = enabledPortEntrances.first?.bindAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupNames = Dictionary(
            groups.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        var lines: [String] = [
            "# Generated by MClash \(Self.version)",
            "allow-lan: false",
            "bind-address: \(yamlScalar(bindAddress?.isEmpty == false ? bindAddress! : "127.0.0.1"))",
            "mode: rule",
            "log-level: info",
            "ipv6: true",
            "",
            "proxies:",
        ]
        if let http = enabledPortEntrances.first(where: { $0.kind == .http }), let port = http.port {
            lines.insert("port: \(port)", at: 7)
        }
        if let socks = enabledPortEntrances.first(where: { $0.kind == .socks5 }), let port = socks.port {
            lines.insert("socks-port: \(port)", at: lines.firstIndex(of: "") ?? lines.endIndex)
        }
        if nodes.isEmpty {
            lines[lines.count - 1] = "proxies: []"
        } else {
            for node in nodes {
                lines.append(contentsOf: render(node: node, name: nodeNames[node.id]))
            }
        }

        lines.append("")
        lines.append("proxy-groups:")
        if groups.isEmpty {
            lines[lines.count - 1] = "proxy-groups: []"
        } else {
            for group in groups {
                lines.append("  - name: \(yamlString(group.name))")
                lines.append("    type: \(mihomoGroupType(group.type))")
                let members: [String]
                switch group.type {
                case .direct:
                    members = ["DIRECT"]
                case .reject:
                    members = ["REJECT"]
                default:
                    members = group.members.compactMap { member -> String? in
                        switch member {
                        case let .node(id): return nodeNames[id]
                        case let .group(id): return groupNames[id]
                        }
                    }
                }
                let values = members.isEmpty && group.type != .direct && group.type != .reject
                    ? ["DIRECT"]
                    : members
                lines.append("    proxies: [\(values.map(yamlString).joined(separator: ", "))]")
            }
        }

        if !ruleSets.isEmpty {
            lines.append("")
            lines.append("rule-providers:")
            for ruleSet in ruleSets where ruleSet.sourceURL != nil {
                let providerName = Self.ruleSetRuntimeName(ruleSet.name)
                lines.append("  \(yamlString(providerName)):")
                lines.append("    type: http")
                lines.append("    behavior: classical")
                lines.append("    format: yaml")
                lines.append("    path: ./providers/\(providerName).yaml")
                if let sourceURL = ruleSet.sourceURL {
                    lines.append("    url: \(yamlScalar(sourceURL.absoluteString))")
                }
            }
        }

        lines.append("")
        lines.append("rules:")
        for ruleSet in ruleSets {
            let action = render(action: ruleSet.defaultAction, groupNames: groupNames)
            if ruleSet.sourceURL != nil {
                lines.append("  - \(yamlString("RULE-SET,\(Self.ruleSetRuntimeName(ruleSet.name)),\(action)"))")
            }
            for rawRule in ruleSet.rules {
                let trimmed = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
                if parts.count == 2 {
                    let rendered = parts[0].trimmingCharacters(in: .whitespaces)
                        + ",\(parts[1].trimmingCharacters(in: .whitespaces)),\(action)"
                    lines.append(
                        "  - \(yamlString(rendered))"
                    )
                } else {
                    lines.append("  - \(yamlString("DOMAIN-SUFFIX,\(trimmed),\(action)"))")
                }
            }
        }
        for rule in rules {
            let action = render(action: rule.action, groupNames: groupNames)
            for line in render(rule: rule, action: action) {
                lines.append("  - \(yamlString(line))")
            }
        }
        let fallback = entrances.first(where: \.enabled)?.defaultAction ?? .direct
        lines.append("  - \(yamlString("MATCH,\(render(action: fallback, groupNames: groupNames))"))")

        lines.append("")
        lines.append("dns:")
        let dnsEnabled = dns?.takeoverEnabled == true && dns?.mode != .system
        lines.append("  enable: \(dnsEnabled)")
        lines.append("  enhanced-mode: \(mihomoDNSMode(dns?.mode ?? .system))")
        let nameservers = dns?.nameservers.isEmpty == false ? dns!.nameservers : ["223.5.5.5", "1.1.1.1"]
        lines.append("  nameserver: [\(nameservers.map(yamlScalar).joined(separator: ", "))]")
        if let fallback = dns?.fallbackNameservers, !fallback.isEmpty {
            lines.append("  fallback: [\(fallback.map(yamlScalar).joined(separator: ", "))]")
        }
        if let proxyServer = dns?.proxyServer, !proxyServer.isEmpty {
            lines.append("  proxy-server: \(yamlScalar(proxyServer))")
        }
        if let dnsRules = dns?.rules, !dnsRules.isEmpty {
            lines.append("  nameserver-policy:")
            for rule in dnsRules where !rule.contains(where: { $0 == "\n" || $0 == "\r" }) {
                lines.append("    \(yamlScalar(rule)): [\(nameservers.map(yamlScalar).joined(separator: ", "))]")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func render(node: Node, name: String?) -> [String] {
        let type: String
        switch node.proto {
        case .https: type = "http"
        case .shadowsocks: type = "ss"
        default: type = node.proto.rawValue
        }
        var lines = [
            "  - name: \(yamlString(name ?? node.userAlias ?? node.displayName))",
            "    type: \(type)",
            "    server: \(yamlScalar(node.host))",
            "    port: \(node.port)",
        ]
        if node.proto == .https {
            lines.append("    tls: true")
        }
        for (key, value) in node.parameters.sorted(by: { $0.key < $1.key })
        where !key.isEmpty && !(node.proto == .https && key == "tls") {
            lines.append("    \(key): \(yamlScalar(value))")
        }
        return lines
    }

    /// Mihomo identifies proxies by their rendered name. Providers often
    /// reuse names (for example “US 01”), so assign deterministic suffixes
    /// without changing the user-facing catalog or stable NodeID. Group
    /// references use this same map, keeping refreshes and duplicate names
    /// unambiguous.
    private func makeRuntimeNodeNames(
        _ nodes: [Node],
        reserving groupNames: Set<String>
    ) -> [NodeID: String] {
        let ordered = nodes.sorted { lhs, rhs in
            let left = (lhs.userAlias ?? lhs.displayName).lowercased()
                + "|" + lhs.host + "|" + String(format: "%05d", lhs.port)
                + "|" + lhs.id.rawValue.uuidString
            let right = (rhs.userAlias ?? rhs.displayName).lowercased()
                + "|" + rhs.host + "|" + String(format: "%05d", rhs.port)
                + "|" + rhs.id.rawValue.uuidString
            return left < right
        }
        var counts: [String: Int] = [:]
        var result: [NodeID: String] = [:]
        var usedNames = groupNames
        let reserved: Set<String> = [
            "DIRECT", "REJECT", "REJECT-DROP", "COMPATIBLE",
            "PASS", "PASS-RULE", "GLOBAL",
        ]
        for node in ordered {
            let raw = (node.userAlias ?? node.displayName).trimmingCharacters(in: .whitespacesAndNewlines)
            let base = raw.isEmpty ? "node-\(node.id.rawValue.uuidString.prefix(8))" : raw
            let normalized = base.uppercased()
            let nameKey = base.lowercased()
            counts[nameKey, default: 0] += 1
            let occurrence = counts[nameKey] ?? 1
            var candidate: String
            if reserved.contains(normalized) {
                candidate = "\(base) (node \(occurrence))"
            } else if occurrence == 1 {
                candidate = base
            } else {
                candidate = "\(base) (\(occurrence))"
            }
            var suffix = occurrence
            while usedNames.contains(candidate.lowercased()) {
                suffix += 1
                candidate = "\(base) (\(suffix))"
            }
            usedNames.insert(candidate.lowercased())
            result[node.id] = candidate
        }
        return result
    }

    private func runtimeEligible(_ node: Node) -> Bool {
        node.enabled
            && node.health.availability != .sourceRemoved
            && node.health.availability != .unsupported
    }

    private func render(rule: RoutingRule, action: String) -> [String] {
        var destinations: [String] = []
        var ports: [String] = []
        var transports: [String] = []
        var hasSourceMatcher = false
        for matcher in rule.matchers {
            switch matcher {
            case let .domainExact(value): destinations.append("DOMAIN,\(safeCSV(value))")
            case let .domainSuffix(value): destinations.append("DOMAIN-SUFFIX,\(safeCSV(value))")
            case let .domainWildcard(value): destinations.append("DOMAIN-KEYWORD,\(safeCSV(value.replacingOccurrences(of: "*", with: "")))")
            case let .ipCIDR(value): destinations.append("IP-CIDR,\(safeCSV(value))")
            case let .port(value): ports.append("DST-PORT,\(value)")
            case let .portRange(range): ports.append("DST-PORT,\(range.lowerBound)-\(range.upperBound)")
            case let .transport(value): transports.append("NETWORK,\(safeCSV(value))")
            case .application, .processPath, .userID: hasSourceMatcher = true
            }
        }
        // Application/process/user identity is only available from the
        // Network Extension. Emitting the remaining domain matcher to Mihomo
        // would widen an app-scoped rule to every HTTP/SOCKS/TUN flow.
        if hasSourceMatcher { return [] }
        let families = [destinations, ports, transports].filter { !$0.isEmpty }
        guard let first = families.first else { return ["MATCH,\(action)"] }
        guard families.count > 1 else { return first.map { "\($0),\(action)" } }
        let combinations = families.dropFirst().reduce(first.map { [$0] }) { partial, family in
            partial.flatMap { values in family.map { values + [$0] } }
        }
        return combinations.map { values in
            "AND,(\(values.map { "(\($0))" }.joined(separator: ","))),\(action)"
        }
    }

    private func safeCSV(_ value: String) -> String {
        value.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
    }

    private func render(
        action: RoutingAction,
        groupNames: [ProxyGroupID: String]
    ) -> String {
        switch action {
        case .direct: return "DIRECT"
        case .reject: return "REJECT"
        case let .proxyGroup(id):
            guard let groupName = groupNames[id] else {
                preconditionFailure("Configuration validation must reject unavailable proxy group actions")
            }
            return groupName
        }
    }

    private func mihomoGroupType(_ type: ProxyGroupType) -> String {
        switch type {
        case .urlTest: return "url-test"
        case .loadBalance: return "load-balance"
        case .fallback: return "fallback"
        case .relay: return "relay"
        case .direct: return "select"
        case .reject: return "select"
        case .select: return "select"
        }
    }

    private func mihomoDNSMode(_ mode: DNSMode) -> String {
        switch mode {
        case .system: return "redir-host"
        case .fakeIP: return "fake-ip"
        case .redirHost: return "redir-host"
        }
    }

    static func ruleSetRuntimeName(_ value: String) -> String {
        let sanitized = value.lowercased().map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let result = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "ruleset" : result
    }

    private func yamlString(_ value: String) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    private func yamlScalar(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if ((trimmed.first == "{" && trimmed.last == "}") || (trimmed.first == "[" && trimmed.last == "]")), !trimmed.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return trimmed
        }
        if ["true", "false", "null"].contains(trimmed.lowercased()) || Int(trimmed) != nil {
            return trimmed
        }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
