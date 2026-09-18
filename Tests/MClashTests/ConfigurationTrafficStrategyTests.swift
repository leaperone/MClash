import Testing
@testable import MClashApp

@Suite("Traffic strategy controls")
struct ConfigurationTrafficStrategyTests {
    @Test("Rule mode exposes the actual rule and entrance groups, not every child group")
    func ruleTargets() {
        let regional = ProxyGroup(name: "Japan first")
        let fallback = ProxyGroup(name: "Default", members: [.group(regional.id)])
        let ruleGroup = ProxyGroup(name: "Apps")
        let unused = ProxyGroup(name: "Unused")
        let entranceGroup = ProxyGroup(name: "Browser")
        let rule = RoutingRule(priority: 1, action: .proxyGroup(ruleGroup.id))
        let inactive = RoutingRule(enabled: false, priority: 2, action: .proxyGroup(unused.id))
        let entrance = Entrance(kind: .http, enabled: true, port: 8080, defaultAction: .proxyGroup(entranceGroup.id))
        let groups = [fallback, regional, ruleGroup, unused, entranceGroup]
        let workspace = Workspace(name: "Daily", proxyGroupIDs: groups.map(\.id),
            ruleIDs: [rule.id, inactive.id], dnsPolicyID: DNSPolicyID(), entranceIDs: [entrance.id], globalProxyGroupID: fallback.id)
        let document = ConfigurationDocument(proxyGroups: groups, rules: [rule, inactive],
            entrances: [entrance], workspaces: [workspace], currentWorkspaceID: workspace.id)
        #expect(ConfigurationTrafficStrategy(document: document).groups.map(\.id) == [fallback.id, ruleGroup.id, entranceGroup.id])
    }

    @Test("Global mode controls its chosen exit and Direct mode has no group control")
    func modes() {
        let first = ProxyGroup(name: "Japan")
        let second = ProxyGroup(name: "US")
        let workspace = Workspace(name: "Daily", proxyGroupIDs: [first.id, second.id],
            dnsPolicyID: DNSPolicyID(), routingMode: .global, globalProxyGroupID: second.id)
        var document = ConfigurationDocument(proxyGroups: [first, second], workspaces: [workspace], currentWorkspaceID: workspace.id)
        #expect(ConfigurationTrafficStrategy(document: document).groups.map(\.id) == [second.id])
        document.workspaces[0].routingMode = .direct
        #expect(ConfigurationTrafficStrategy(document: document).groups.isEmpty)
    }

    @Test("A missing saved default uses the compiler's first enabled workspace group")
    func defaultWithoutID() {
        let disabled = ProxyGroup(name: "Disabled", enabled: false)
        let first = ProxyGroup(name: "Manual")
        let workspace = Workspace(name: "Daily", proxyGroupIDs: [disabled.id, first.id], dnsPolicyID: DNSPolicyID())
        let document = ConfigurationDocument(proxyGroups: [disabled, first], workspaces: [workspace], currentWorkspaceID: workspace.id)
        #expect(ConfigurationTrafficStrategy(document: document).groups.map(\.id) == [first.id])
    }
}
