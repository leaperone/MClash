import Foundation

public extension ConfigurationDocument {
    /// Creates the first-run strategy skeleton. It is intentionally empty of
    /// provider nodes and source rules; importing a source only fills the node
    /// catalog and never replaces these MClash-owned policies.
    static func mclashDefault() -> Self {
        let dns = DNSPolicy(name: "MClash DNS", mode: .redirHost, nameservers: ConfigurationCompiler.defaultDNSNameservers, takeoverEnabled: true)
        // An empty include list means “all enabled nodes in the catalog”. It
        // keeps the default group dynamic as subscriptions grow; individual
        // pins are stored separately by the group editor.
        let select = ProxyGroup(
            name: "MClash Select",
            type: .select,
            memberSelectors: [NodeSelector(name: "All enabled nodes")]
        )
        let builtInRuleSets = Self.builtInRuleSets(proxyGroupID: select.id)
        let builtInRoutingRules = Self.builtInRoutingRules()
        let http = Entrance(kind: .http, enabled: true, port: 7890, defaultAction: .proxyGroup(select.id))
        let socks = Entrance(kind: .socks5, enabled: true, port: 7891, defaultAction: .proxyGroup(select.id))
        let appRouting = Entrance(kind: .appRouting, enabled: false, defaultAction: .proxyGroup(select.id))
        let tun = Entrance(kind: .tun, enabled: false, defaultAction: .proxyGroup(select.id))
        let workspace = Workspace(
            name: "Everyday",
            proxyGroupIDs: [select.id],
            ruleIDs: builtInRoutingRules.map(\.id),
            ruleSetIDs: builtInRuleSets.map(\.id),
            dnsPolicyID: dns.id,
            entranceIDs: [http.id, socks.id, appRouting.id, tun.id],
            routingMode: .rule,
            globalProxyGroupID: select.id
        )
        return Self(
            sources: [],
            nodes: [],
            proxyGroups: [select],
            rules: builtInRoutingRules,
            ruleSets: builtInRuleSets,
            dnsPolicies: [dns],
            entrances: [http, socks, appRouting, tun],
            workspaces: [workspace],
            currentWorkspaceID: workspace.id
        )
    }

    /// Rule sets owned by MClash itself.  These use mihomo's bundled GeoData
    /// instead of importing executable provider sections from a source
    /// profile, so the policy remains deterministic and editable here.
    static func builtInRuleSets(proxyGroupID: ProxyGroupID) -> [RuleSet] {
        let china = RuleSet(
            id: RuleSetID.stable(for: "mclash-builtin-ruleset-cn-v1"),
            name: "中国大陆直连",
            rules: ["GEOSITE,cn", "GEOIP,CN,no-resolve"],
            defaultAction: .direct,
            behavior: .classical,
            format: .text
        )
        let gfw = RuleSet(
            id: RuleSetID.stable(for: "mclash-builtin-ruleset-gfw-v1"),
            name: "GFW List",
            rules: ["GEOSITE,gfw"],
            defaultAction: .proxyGroup(proxyGroupID),
            behavior: .classical,
            format: .text
        )
        let privateNetworks = RuleSet(
            id: RuleSetID.stable(for: "mclash-builtin-ruleset-private-v1"),
            name: "私有网络直连",
            rules: ["GEOSITE,private", "GEOIP,PRIVATE,no-resolve"],
            defaultAction: .direct,
            behavior: .classical,
            format: .text
        )
        let adBlock = RuleSet(
            id: RuleSetID.stable(for: "mclash-builtin-ruleset-ads-v1"),
            name: "广告拦截",
            rules: ["GEOSITE,category-ads-all"],
            defaultAction: .reject,
            behavior: .classical,
            format: .text
        )
        return [privateNetworks, china, gfw, adBlock]
    }

    /// Local-network bypasses are emitted as both Mihomo rules and App
    /// Routing capture rules.  The latter is important: a transparent
    /// provider must never tunnel Docker/SSH traffic destined for the LAN.
    static func builtInRoutingRules() -> [RoutingRule] {
        let cidrs = [
            "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12",
            "192.168.0.0/16", "169.254.0.0/16", "::1/128",
            "fc00::/7", "fe80::/10",
        ]
        let networkRules = cidrs.enumerated().map { offset, cidr in
            RoutingRule(
                id: RoutingRuleID.stable(for: "mclash-builtin-lan-direct-v1|\(cidr)"),
                priority: -1_000 + offset,
                matchers: [.ipCIDR(cidr)],
                action: .direct
            )
        }
        let parsec = RoutingRule(
            id: RoutingRuleID.stable(for: "mclash-builtin-parsec-direct-v1"),
            priority: -900,
            matchers: [.application("tv.parsec.www")],
            action: .direct
        )
        return networkRules + [parsec]
    }
}
