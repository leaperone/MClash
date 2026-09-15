import Foundation
import MClashAutomationProtocol

public struct XrayInbound: Equatable, Sendable {
    public enum Kind: String, Sendable { case http, socks, mixed }
    public enum Target: Equatable, Sendable {
        case rules
        case rulesWithDefault(RoutingAction)
        case group(ProxyGroupID)
        case node(NodeID)
        case direct
        case reject
    }
    public struct Authentication: Equatable, Sendable {
        public let username: String
        public let password: String
        public init(username: String, password: String) { self.username = username; self.password = password }
    }
    public let tag: String
    public let kind: Kind
    public let bindAddress: String
    public let port: Int
    public let target: Target
    public let authentication: Authentication?

    public init(tag: String, kind: Kind, bindAddress: String = "127.0.0.1", port: Int,
                target: Target = .rules, authentication: Authentication? = nil) {
        self.tag = tag
        self.kind = kind
        self.bindAddress = bindAddress
        self.port = port
        self.target = target
        self.authentication = authentication
    }
}

public struct XrayRuntimePlan: Equatable, Sendable {
    public let workspace: Workspace
    public let nodes: [Node]
    public let groups: [ProxyGroup]
    public let inbounds: [XrayInbound]
    public let nodeTags: [NodeID: String]
    public let groupTags: [ProxyGroupID: String]
    public let unavailableNodes: [NodeID: String]
    public let diagnostics: [ConfigurationDiagnostic]
    public let configuration: [String: AutomationJSONValue]

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(configuration)
    }

    public static func nodeTag(_ id: NodeID) -> String { "n-" + id.rawValue.uuidString.lowercased() }
    public static func groupTag(_ id: ProxyGroupID) -> String { "g-" + id.rawValue.uuidString.lowercased() }
    public static func probeTag(_ id: NodeID) -> String { "probe-" + id.rawValue.uuidString.lowercased() }
}

public enum XrayConfigurationCompiler {
    public static let version = "mclash-xray-1"

    public static func compile(
        document: ConfigurationDocument,
        workspaceID: WorkspaceID,
        inbounds: [XrayInbound],
        apiSocketPath: String,
        capturedRuleIDs: Set<RoutingRuleID> = [],
        logDirectory: String? = nil
    ) throws -> XrayRuntimePlan {
        guard let workspace = document.workspaces.first(where: { $0.id == workspaceID }) else {
            throw ConfigurationCompilationError.invalidText("No MClash workspace is configured.")
        }
        guard apiSocketPath.hasPrefix("/"), apiSocketPath.utf8.count < 104,
              !apiSocketPath.contains("\0"), !apiSocketPath.split(separator: "/").contains("..") else {
            throw ConfigurationCompilationError.invalidText("Xray requires a private absolute Unix socket path shorter than 104 bytes.")
        }
        var diagnostics = document.diagnostics(for: workspace, backend: .xray).filter {
            $0.code != "unsupported_node_protocol" && $0.code != "unsupported_geoip6"
        }
        let invalid = diagnostics.filter { $0.severity == .error }
        guard invalid.isEmpty else { throw ConfigurationCompilationError.invalid(invalid) }
        let nodeScope = Set(workspace.nodeIDs)
        let nodes = document.nodes.filter {
            $0.enabled && (nodeScope.isEmpty || nodeScope.contains($0.id)) && $0.health.availability != .sourceRemoved
        }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        let groupScope = Set(workspace.proxyGroupIDs)
        let groups = document.proxyGroups.filter { $0.enabled && groupScope.contains($0.id) }.map { group in
            var resolved = group
            var members = Set(resolved.members)
            let automatic = NodeSelectorResolver.resolve(selectors: group.memberSelectors, nodes: nodes)
            resolved.members += automatic.nodeIDs.map(ProxyGroupMember.node).filter { members.insert($0).inserted }
            return resolved
        }
        let groupTags = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, XrayRuntimePlan.groupTag($0.id)) })
        var nodeTags: [NodeID: String] = [:]
        var unavailable: [NodeID: String] = [:]
        var outbounds: [AutomationJSONValue] = [
            .object(["tag": .string("reject"), "protocol": .string("blackhole")]),
            .object(["tag": .string("dns-direct"), "protocol": .string("freedom")]),
            .object(["tag": .string("direct"), "protocol": .string("freedom"),
                     "streamSettings": .object(["sockopt": .object(["domainStrategy": .string("ForceIP")])])]),
        ]
        for node in nodes {
            let tag = XrayRuntimePlan.nodeTag(node.id)
            do {
                outbounds.append(try XrayNodeRenderer.render(node, tag: tag))
                nodeTags[node.id] = tag
            } catch let error as XrayNodeRenderError {
                unavailable[node.id] = error.localizedDescription
                diagnostics.append(.init(severity: .warning, code: "xray_node_unsupported",
                    subject: node.id.rawValue.uuidString.lowercased(), message: error.localizedDescription))
            }
        }
        var ports = Set<String>()
        var tags = Set<String>()
        let renderedInbounds = try inbounds.map { inbound -> AutomationJSONValue in
            guard (1...65535).contains(inbound.port), !inbound.tag.isEmpty,
                  tags.insert(inbound.tag).inserted, !inbound.bindAddress.isEmpty,
                  ports.insert(inbound.bindAddress + ":" + String(inbound.port)).inserted else {
                throw ConfigurationCompilationError.invalidText("Duplicate or invalid Xray entrance.")
            }
            return try renderInbound(inbound)
        }
        let dnsPolicy = document.dnsPolicies.first { $0.id == workspace.dnsPolicyID }
        var routing = try XrayRuleRenderer.rules(document: document, workspace: workspace,
            groupTags: groupTags, capturedRuleIDs: capturedRuleIDs)
        let defaultTag = workspace.globalProxyGroupID.flatMap { groupTags[$0] }
            ?? workspace.proxyGroupIDs.compactMap { groupTags[$0] }.first
        let defaultAction: [String: AutomationJSONValue] = defaultTag.map { ["balancerTag": .string($0)] }
            ?? ["outboundTag": .string("direct")]
        var prefix: [AutomationJSONValue] = []
        var final: [AutomationJSONValue] = []
        for inbound in inbounds {
            let fields: [String: AutomationJSONValue]
            switch (workspace.routingMode, inbound.target) {
            case (_, .direct): fields = ["outboundTag": .string("direct")]
            case (_, .reject): fields = ["outboundTag": .string("reject")]
            case (_, let .node(id)):
                guard let tag = nodeTags[id] else {
                    throw ConfigurationCompilationError.invalidText("Selected Xray node is unavailable or unsupported.")
                }
                fields = ["outboundTag": .string(tag)]
            case (_, let .group(id)):
                guard let tag = groupTags[id] else { throw ConfigurationCompilationError.invalidText("Xray entrance references a missing group.") }
                fields = ["balancerTag": .string(tag)]
            case (.direct, _): fields = ["outboundTag": .string("direct")]
            case (.global, _): fields = defaultAction
            case (.rule, .rules):
                final.append(route(inbound: inbound.tag, target: defaultAction))
                continue
            case let (.rule, .rulesWithDefault(action)):
                final.append(route(inbound: inbound.tag, target: try XrayRuleRenderer.action(action, groups: groupTags)))
                continue
            }
            prefix.append(route(inbound: inbound.tag, target: fields))
        }
        if dnsPolicy?.takeoverEnabled == true {
            outbounds.append(.object(["tag": .string("dns-out"), "protocol": .string("dns"), "settings": .object([:])]))
            prefix.insert(.object(["type": .string("field"), "ruleTag": .string("mclash-dns"),
                "port": .string("53"), "outboundTag": .string("dns-out")]), at: 0)
        }
        for node in nodes {
            if let tag = nodeTags[node.id] {
                prefix.insert(route(inbound: XrayRuntimePlan.probeTag(node.id), target: ["outboundTag": .string(tag)]), at: 0)
            }
        }
        prefix.insert(route(inbound: "dns-query", target: ["outboundTag": .string("dns-direct")]), at: 0)
        routing = prefix + routing + final
        let balancers: [AutomationJSONValue] = groups.map { group in
            .object(["tag": .string(XrayRuntimePlan.groupTag(group.id)), "selector": .array([.string("reject")]),
                     "strategy": .object(["type": .string("random")])])
        }
        var logs: [String: AutomationJSONValue] = ["loglevel": .string("warning")]
        if let logDirectory {
            logs["access"] = .string(logDirectory + "/access.log")
            logs["error"] = .string(logDirectory + "/error.log")
        }
        var configuration: [String: AutomationJSONValue] = [
            "log": .object(logs),
            "api": .object(["tag": .string("mclash-api"), "listen": .string(apiSocketPath),
                "services": .array(["HandlerService", "RoutingService", "StatsService"].map(AutomationJSONValue.string))]),
            "stats": .object([:]),
            "policy": .object(["system": .object(["statsInboundUplink": .bool(true), "statsInboundDownlink": .bool(true),
                "statsOutboundUplink": .bool(true), "statsOutboundDownlink": .bool(true)])]),
            "inbounds": .array(renderedInbounds), "outbounds": .array(outbounds),
            "routing": .object(["domainStrategy": .string("IPIfNonMatch"), "rules": .array(routing), "balancers": .array(balancers)]),
            "dns": .object(try renderDNS(dnsPolicy, nodes: nodes)),
        ]
        if dnsPolicy?.mode == .fakeIP {
            configuration["fakedns"] = .array([.object(["ipPool": .string("198.18.0.0/15"), "poolSize": .integer(65535)])])
        }
        return XrayRuntimePlan(workspace: workspace, nodes: nodes, groups: groups, inbounds: inbounds,
            nodeTags: nodeTags, groupTags: groupTags, unavailableNodes: unavailable,
            diagnostics: diagnostics, configuration: configuration)
    }

    private static func route(inbound: String, target: [String: AutomationJSONValue]) -> AutomationJSONValue {
        .object(target.merging(["type": .string("field"), "inboundTag": .array([.string(inbound)])]) { old, _ in old })
    }

    private static func renderInbound(_ inbound: XrayInbound) throws -> AutomationJSONValue {
        var settings: [String: AutomationJSONValue] = [:]
        if inbound.kind != .http { settings = ["auth": .string("noauth"), "udp": .bool(true), "ip": .string("127.0.0.1")] }
        if let authentication = inbound.authentication {
            guard !authentication.username.isEmpty, !authentication.password.isEmpty else {
                throw ConfigurationCompilationError.invalidText("Xray entrance requires both authentication fields.")
            }
            let account: AutomationJSONValue = .object(["user": .string(authentication.username), "pass": .string(authentication.password)])
            settings["accounts"] = .array([account])
            if inbound.kind != .http { settings["auth"] = .string("password") }
        }
        return .object([
            "tag": .string(inbound.tag), "listen": .string(inbound.bindAddress), "port": .integer(Int64(inbound.port)),
            "protocol": .string(inbound.kind.rawValue), "settings": .object(settings),
            "sniffing": .object(["enabled": .bool(true), "routeOnly": .bool(true),
                "destOverride": .array(["http", "tls", "fakedns"].map(AutomationJSONValue.string))]),
        ])
    }

    private static func dnsServer(_ address: String) throws -> [String: AutomationJSONValue] {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://"), value.filter({ $0 == ":" }).count > 1, !value.hasPrefix("[") {
            return ["address": .string(value)]
        }
        let uri = value.contains("://") ? value : "udp://" + value
        guard let url = URLComponents(string: uri), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, let scheme = url.scheme?.lowercased(),
              url.port.map({ (1...65535).contains($0) }) ?? true else {
            throw ConfigurationCompilationError.invalidText("Invalid Xray DNS server address.")
        }
        if scheme == "udp" {
            guard url.path.isEmpty, url.query == nil, url.fragment == nil else {
                throw ConfigurationCompilationError.invalidText("A UDP DNS server cannot contain a path or query.")
            }
            return ["address": .string(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))),
                    "port": .integer(Int64(url.port ?? 53))]
        }
        guard ["tcp", "tcp+local", "https", "https+local", "h2c", "h2c+local", "quic+local"].contains(scheme) else {
            throw ConfigurationCompilationError.invalidText("This DNS transport is not supported by the bundled Xray core.")
        }
        return ["address": .string(value)]
    }

    private static func renderDNS(_ policy: DNSPolicy?, nodes: [Node]) throws -> [String: AutomationJSONValue] {
        guard let policy, policy.mode != .system else { return ["servers": .array([.string("localhost")])] }
        let nameservers = policy.nameservers.isEmpty ? ["223.5.5.5", "119.29.29.29"] : policy.nameservers
        var servers: [AutomationJSONValue] = []
        if let bootstrap = policy.proxyServer, !bootstrap.isEmpty {
            var server = try dnsServer(bootstrap)
            server["domains"] = .array(nodes.map { .string("full:" + $0.host) })
            server["skipFallback"] = .bool(true)
            servers.append(.object(server))
        }
        if policy.mode == .fakeIP {
            let endpoints = nodes.map { AutomationJSONValue.string("full:" + $0.host) }
            servers += try nameservers.map {
                var server = try dnsServer($0)
                server["domains"] = .array(endpoints)
                server["skipFallback"] = .bool(true)
                return .object(server)
            }
            servers.append(.string("fakedns"))
        }
        servers += try (nameservers + policy.fallbackNameservers).map { .object(try dnsServer($0)) }
        for line in policy.rules {
            let fields = line.split(separator: ",", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 3 else { throw ConfigurationCompilationError.invalidText("DNS policy rule requires matcher, domain and nameserver.") }
            let prefix: String
            switch fields[0].uppercased() {
            case "DOMAIN": prefix = "full:"
            case "DOMAIN-SUFFIX": prefix = "domain:"
            case "GEOSITE": prefix = "geosite:"
            default: throw ConfigurationCompilationError.invalidText("DNS policy matcher is not supported by Xray.")
            }
            var server = try dnsServer(fields[2])
            server["domains"] = .array([.string(prefix + fields[1])])
            server["skipFallback"] = .bool(true)
            servers.insert(.object(server), at: 0)
        }
        return ["servers": .array(servers), "queryStrategy": .string("UseIP"), "tag": .string("dns-query")]
    }
}
