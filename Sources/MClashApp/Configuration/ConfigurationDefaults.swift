import Foundation

public extension ConfigurationDocument {
    /// Creates the first-run strategy skeleton. It is intentionally empty of
    /// provider nodes and source rules; importing a source only fills the node
    /// catalog and never replaces these MClash-owned policies.
    static func mclashDefault() -> Self {
        let dns = DNSPolicy(name: "MClash DNS", mode: .redirHost, nameservers: ["223.5.5.5", "1.1.1.1"], takeoverEnabled: true)
        // An empty include list means “all enabled nodes in the catalog”. It
        // keeps the default group dynamic as subscriptions grow; individual
        // pins are stored separately by the group editor.
        let select = ProxyGroup(
            name: "MClash Select",
            type: .select,
            memberSelectors: [NodeSelector(name: "All enabled nodes")]
        )
        let http = Entrance(kind: .http, enabled: true, port: 7890, defaultAction: .proxyGroup(select.id))
        let socks = Entrance(kind: .socks5, enabled: true, port: 7891, defaultAction: .proxyGroup(select.id))
        let appRouting = Entrance(kind: .appRouting, enabled: false, defaultAction: .proxyGroup(select.id))
        let tun = Entrance(kind: .tun, enabled: false, defaultAction: .proxyGroup(select.id))
        let workspace = Workspace(
            name: "Everyday",
            proxyGroupIDs: [select.id],
            dnsPolicyID: dns.id,
            entranceIDs: [http.id, socks.id, appRouting.id, tun.id],
            routingMode: .rule,
            globalProxyGroupID: select.id
        )
        return Self(
            sources: [],
            nodes: [],
            proxyGroups: [select],
            rules: [],
            dnsPolicies: [dns],
            entrances: [http, socks, appRouting, tun],
            workspaces: [workspace],
            currentWorkspaceID: workspace.id
        )
    }
}
