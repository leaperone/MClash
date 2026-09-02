import Foundation
import Testing
@testable import MClashApp

struct ConfigurationAdvancedTests {
    @Test("Disabled rule set contents do not block active compilation")
    func disabledRuleSetIsIgnoredByWorkspaceValidation() throws {
        let dns = DNSPolicy(name: "DNS")
        let node = try Node(displayName: "Node", protocol: .vless, host: "node.example", port: 443)
        let group = ProxyGroup(name: "Node Selection", type: .select, members: [.node(node.id)])
        let disabled = RuleSet(name: "Disabled", rules: ["NOT-A-MIHOMO-RULE,x"], enabled: false)
        let entrance = Entrance(kind: .http, enabled: true, port: 18080)
        let workspace = Workspace(name: "Everyday", proxyGroupIDs: [group.id], ruleSetIDs: [disabled.id], dnsPolicyID: dns.id, entranceIDs: [entrance.id])
        let document = ConfigurationDocument(nodes: [node], proxyGroups: [group], ruleSets: [disabled], dnsPolicies: [dns], entrances: [entrance], workspaces: [workspace], currentWorkspaceID: workspace.id)
        _ = try ConfigurationCompiler().compile(document: document)
    }

    @Test("Rule sets preserve provider metadata and compile with the selected shape")
    func ruleSetMetadataRoundTripsAndRenders() throws {
        let dns = DNSPolicy(name: "DNS")
        let node = try Node(displayName: "Node", protocol: .vless, host: "node.example", port: 443)
        let group = ProxyGroup(name: "Node Selection", type: .select, members: [.node(node.id)])
        let set = RuleSet(
            name: "GFW",
            sourceURL: URL(string: "https://rules.example/gfw.mrs"),
            defaultAction: .proxyGroup(group.id),
            behavior: .domain,
            format: .mrs,
            path: "providers/gfw.mrs"
        )
        let entrance = Entrance(kind: .http, enabled: true, port: 18080)
        let workspace = Workspace(
            name: "Everyday",
            proxyGroupIDs: [group.id],
            ruleSetIDs: [set.id],
            dnsPolicyID: dns.id,
            entranceIDs: [entrance.id]
        )
        let document = ConfigurationDocument(
            nodes: [node],
            proxyGroups: [group],
            ruleSets: [set],
            dnsPolicies: [dns],
            entrances: [entrance],
            workspaces: [workspace],
            currentWorkspaceID: workspace.id
        )

        let encoded = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(RuleSet.self, from: encoded)
        #expect(decoded == set)

        let yaml = String(
            decoding: try ConfigurationCompiler().compile(document: document).yaml,
            as: UTF8.self
        )
        #expect(yaml.contains("behavior: domain"))
        #expect(yaml.contains("format: mrs"))
        #expect(yaml.contains("path: \"providers/gfw.mrs\""))
        #expect(yaml.contains("RULE-SET,gfw,Node Selection"))
    }

    @Test("Legacy rule sets decode with safe provider defaults")
    func legacyRuleSetDefaults() throws {
        let value = RuleSet(name: "legacy")
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(value)
        ) as! [String: Any]
        object.removeValue(forKey: "behavior")
        object.removeValue(forKey: "format")
        object.removeValue(forKey: "path")
        object.removeValue(forKey: "enabled")
        let decoded = try JSONDecoder().decode(
            RuleSet.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.behavior == .classical)
        #expect(decoded.format == .yaml)
        #expect(decoded.enabled)
    }

    @Test("Rule set entries preserve options and explicit actions")
    func ruleSetEntriesRenderSafely() throws {
        let node = try Node(displayName: "Node", protocol: .vless, host: "node.example", port: 443)
        let group = ProxyGroup(name: "Node Selection", type: .select, members: [.node(node.id)])
        let set = RuleSet(
            name: "Local rules",
            rules: ["IP-CIDR,192.0.2.0/24,no-resolve", "DOMAIN,example.com,REJECT"]
        )
        let dns = DNSPolicy(name: "DNS")
        let entrance = Entrance(kind: .http, enabled: true, port: 18120)
        let workspace = Workspace(name: "Rules", proxyGroupIDs: [group.id], ruleSetIDs: [set.id], dnsPolicyID: dns.id, entranceIDs: [entrance.id])
        let document = ConfigurationDocument(nodes: [node], proxyGroups: [group], ruleSets: [set], dnsPolicies: [dns], entrances: [entrance], workspaces: [workspace], currentWorkspaceID: workspace.id)
        let yaml = String(decoding: try ConfigurationCompiler().compile(document: document).yaml, as: UTF8.self)
        #expect(yaml.contains("IP-CIDR,192.0.2.0/24,DIRECT,no-resolve"))
        #expect(yaml.contains("DOMAIN,example.com,REJECT"))
    }

    @Test("Process name and path rules are available to both core and App Routing")
    func processMatchersCompileWithoutWidening() throws {
        let node = try Node(displayName: "Node", protocol: .vless, host: "node.example", port: 443)
        let group = ProxyGroup(name: "Node Selection", type: .select, members: [.node(node.id)])
        let processRule = RoutingRule(
            priority: 10,
            matchers: [.processName("curl"), .domainSuffix("example.com")],
            action: .proxyGroup(group.id)
        )
        let pathRule = RoutingRule(
            priority: 20,
            matchers: [.processPath("/usr/bin/curl")],
            action: .direct
        )
        let dns = DNSPolicy(name: "DNS")
        let entrance = Entrance(kind: .socks5, enabled: true, port: 18081)
        let workspace = Workspace(
            name: "Everyday",
            proxyGroupIDs: [group.id],
            ruleIDs: [processRule.id, pathRule.id],
            dnsPolicyID: dns.id,
            entranceIDs: [entrance.id]
        )
        let document = ConfigurationDocument(
            nodes: [node],
            proxyGroups: [group],
            rules: [processRule, pathRule],
            dnsPolicies: [dns],
            entrances: [entrance],
            workspaces: [workspace],
            currentWorkspaceID: workspace.id
        )
        let compiled = try ConfigurationCompiler().compile(document: document)
        let yaml = String(decoding: compiled.yaml, as: UTF8.self)
        #expect(yaml.contains("PROCESS-NAME,curl"))
        #expect(yaml.contains("PROCESS-PATH,/usr/bin/curl"))
        #expect(compiled.networkExtensionRules.count == 1)
        #expect(compiled.captureRules.count == 2) // path rule plus catch-all
    }

    @Test("IPv6 networks use Mihomo's IP-CIDR6 matcher")
    func ipv6CIDRUsesNativeRuleType() throws {
        let node = try Node(displayName: "Node", protocol: .vless, host: "node.example", port: 443)
        let group = ProxyGroup(name: "Node Selection", type: .select, members: [.node(node.id)])
        let dns = DNSPolicy(name: "DNS")
        let entrance = Entrance(kind: .http, enabled: true, port: 18110)
        let rule = RoutingRule(
            priority: 10,
            matchers: [.ipCIDR("2001:db8::/32")],
            action: .proxyGroup(group.id)
        )
        let workspace = Workspace(
            name: "IPv6",
            proxyGroupIDs: [group.id],
            ruleIDs: [rule.id],
            dnsPolicyID: dns.id,
            entranceIDs: [entrance.id]
        )
        let document = ConfigurationDocument(
            nodes: [node],
            proxyGroups: [group],
            rules: [rule],
            dnsPolicies: [dns],
            entrances: [entrance],
            workspaces: [workspace],
            currentWorkspaceID: workspace.id
        )
        let yaml = String(decoding: try ConfigurationCompiler().compile(document: document).yaml, as: UTF8.self)
        #expect(yaml.contains("IP-CIDR6,2001:db8::/32"))
    }

    @Test("Invalid GEO tokens fail validation before Mihomo startup")
    func invalidGeoTokenIsRejected() throws {
        let node = try Node(displayName: "Node", protocol: .vless, host: "node.example", port: 443)
        let group = ProxyGroup(name: "Node Selection", type: .select, members: [.node(node.id)])
        let dns = DNSPolicy(name: "DNS")
        let entrance = Entrance(kind: .http, enabled: true, port: 18111)
        let rule = RoutingRule(priority: 10, matchers: [.geoIP("C")], action: .direct)
        let workspace = Workspace(name: "Invalid", proxyGroupIDs: [group.id], ruleIDs: [rule.id], dnsPolicyID: dns.id, entranceIDs: [entrance.id])
        let document = ConfigurationDocument(nodes: [node], proxyGroups: [group], rules: [rule], dnsPolicies: [dns], entrances: [entrance], workspaces: [workspace], currentWorkspaceID: workspace.id)
        let diagnostics = document.diagnostics(for: workspace)
        #expect(diagnostics.contains { $0.code == "invalid_geoip_token" })
        #expect(throws: ConfigurationCompilationError.self) {
            try ConfigurationCompiler().compile(document: document)
        }
    }

    @Test("GEOIP6 remains decodable but is rejected before runtime generation")
    func geoIP6IsExplicitlyUnsupported() throws {
        let node = try Node(displayName: "Node", protocol: .vless, host: "node.example", port: 443)
        let group = ProxyGroup(name: "Node Selection", type: .select, members: [.node(node.id)])
        let dns = DNSPolicy(name: "DNS")
        let entrance = Entrance(kind: .http, enabled: true, port: 18112)
        let rule = RoutingRule(priority: 10, matchers: [.geoIP6("CN")], action: .direct)
        let workspace = Workspace(name: "IPv6 country", proxyGroupIDs: [group.id], ruleIDs: [rule.id], dnsPolicyID: dns.id, entranceIDs: [entrance.id])
        let document = ConfigurationDocument(nodes: [node], proxyGroups: [group], rules: [rule], dnsPolicies: [dns], entrances: [entrance], workspaces: [workspace], currentWorkspaceID: workspace.id)
        #expect(document.diagnostics(for: workspace).contains { $0.code == "unsupported_geoip6" })
        #expect(throws: ConfigurationCompilationError.self) {
            try ConfigurationCompiler().compile(document: document)
        }
    }

    @Test("Listener route pruning removes renamed groups while retaining valid ports")
    func listenerPruningIsStable() throws {
        let old = try NetworkExtensionMihomoListenerConfiguration(
            port: 19000,
            authentication: try NetworkExtensionMihomoAuthentication(
                username: "u",
                password: "p"
            ),
            routePorts: [
                .group("Old Group"): 19001,
                .group("Node Selection"): 19002,
            ],
            includesLegacyProfileRules: true
        )
        let narrowed = try old.retaining(routes: [.group("Node Selection")])
        #expect(narrowed.port == old.port)
        #expect(narrowed.authentication == old.authentication)
        #expect(narrowed.endpoint(for: .group("Old Group")) == nil)
        #expect(narrowed.endpoint(for: .group("Node Selection"))?.port == 19002)
        #expect(narrowed.endpoint(for: .profileRules)?.port == old.port)
    }

    @Test("Multiple named HTTP and SOCKS entrances remain distinct")
    func multipleEntrancesValidateAndCompile() throws {
        let group = ProxyGroup(name: "Node Selection", type: .select)
        let httpA = Entrance(name: "HTTP work", kind: .http, enabled: true, port: 18100, defaultAction: .proxyGroup(group.id))
        let httpB = Entrance(name: "HTTP tools", kind: .http, enabled: true, port: 18101)
        let socks = Entrance(name: "SOCKS apps", kind: .socks5, enabled: true, port: 18102)
        let dns = DNSPolicy(name: "DNS")
        let workspace = Workspace(
            name: "Everyday",
            proxyGroupIDs: [group.id],
            dnsPolicyID: dns.id,
            entranceIDs: [httpA.id, httpB.id, socks.id]
        )
        let document = ConfigurationDocument(
            proxyGroups: [group],
            dnsPolicies: [dns],
            entrances: [httpA, httpB, socks],
            workspaces: [workspace],
            currentWorkspaceID: workspace.id
        )
        #expect(document.diagnostics(for: workspace).filter { $0.severity == .error }.isEmpty)
        let yaml = String(decoding: try ConfigurationCompiler().compile(document: document).yaml, as: UTF8.self)
        #expect(yaml.components(separatedBy: "name: \"HTTP work\"").count == 2)
        #expect(yaml.contains("port: 18100"))
        #expect(yaml.contains("port: 18101"))
        #expect(yaml.contains("port: 18102"))
        // Rule-mode HTTP/SOCKS listeners pin to each entrance default
        // action so split-traffic browser and app exits stay independent.
        #expect(yaml.contains("proxy: \"Node Selection\""))
    }

    @Test("Fallback member order is preserved instead of being UUID-sorted")
    func fallbackOrderIsDurable() throws {
        let first = try Node(displayName: "First", protocol: .vless, host: "first.example", port: 443)
        let second = try Node(displayName: "Second", protocol: .vless, host: "second.example", port: 443)
        let group = ProxyGroup(name: "Failover", type: .fallback, members: [.node(second.id), .node(first.id)])
        let dns = DNSPolicy(name: "DNS")
        let entrance = Entrance(kind: .http, enabled: true, port: 18130)
        let workspace = Workspace(name: "Order", nodeIDs: [first.id, second.id], proxyGroupIDs: [group.id], dnsPolicyID: dns.id, entranceIDs: [entrance.id])
        let document = ConfigurationDocument(nodes: [first, second], proxyGroups: [group], dnsPolicies: [dns], entrances: [entrance], workspaces: [workspace], currentWorkspaceID: workspace.id)
        let yaml = String(decoding: try ConfigurationCompiler().compile(document: document).yaml, as: UTF8.self)
        #expect(yaml.contains("proxies: [\"Second\", \"First\"]"))
    }
}
