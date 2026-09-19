import Foundation

struct ConfigurationRuntimeState: Equatable, Sendable {
    private let workspace: Workspace
    private let nodes: [Node]
    private let groups: [ProxyGroup]
    private let rules: [RoutingRule]
    private let ruleSets: [RuleSet]
    private let dns: DNSPolicy?
    private let entrances: [Entrance]

    init?(document: ConfigurationDocument, workspaceID: WorkspaceID) {
        guard var workspace = document.workspaces.first(where: { $0.id == workspaceID }) else { return nil }
        workspace.revision = 0
        self.workspace = workspace
        let nodeIDs = Set(workspace.nodeIDs)
        let groupIDs = Set(workspace.proxyGroupIDs)
        let ruleIDs = Set(workspace.ruleIDs)
        let ruleSetIDs = Set(workspace.ruleSetIDs)
        let entranceIDs = Set(workspace.entranceIDs)
        nodes = document.nodes.filter { nodeIDs.isEmpty || nodeIDs.contains($0.id) }.map {
            var node = $0
            node.lastSeenAt = nil
            node.health.checkedAt = nil
            node.health.latencyMilliseconds = nil
            return node
        }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
        groups = document.proxyGroups.filter { groupIDs.contains($0.id) }
        rules = document.rules.filter { ruleIDs.contains($0.id) }
        ruleSets = document.ruleSets.filter { ruleSetIDs.contains($0.id) }.map {
            var value = $0
            value.revision = 0
            return value
        }
        dns = document.dnsPolicies.first { $0.id == workspace.dnsPolicyID }
        entrances = document.entrances.filter { entranceIDs.contains($0.id) }
    }
}
