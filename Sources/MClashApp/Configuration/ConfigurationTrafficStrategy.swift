import Foundation

struct ConfigurationTrafficStrategy {
    let mode: ConfigurationRoutingMode
    let groups: [ProxyGroup]

    init(document: ConfigurationDocument) {
        guard let workspace = document.currentWorkspace else {
            mode = .rule
            groups = []
            return
        }
        mode = workspace.routingMode
        let available = workspace.proxyGroupIDs.compactMap { id in
            document.proxyGroups.first { $0.id == id && $0.enabled }
        }
        let defaultID = workspace.globalProxyGroupID ?? available.first?.id
        if mode == .direct {
            groups = []
        } else if mode == .global {
            groups = available.filter { $0.id == defaultID }
        } else {
            let actions = document.rules.filter {
                $0.enabled && workspace.ruleIDs.contains($0.id)
                    && ($0.workspaceScope == nil || $0.workspaceScope == workspace.id)
            }.map(\.action) + document.ruleSets.filter {
                $0.enabled && workspace.ruleSetIDs.contains($0.id)
            }.map(\.defaultAction) + document.entrances.filter {
                $0.enabled && workspace.entranceIDs.contains($0.id)
                    && ($0.workspaceOverride == nil || $0.workspaceOverride == workspace.id)
            }.map(\.defaultAction)
            let used = Set(actions.compactMap { action -> ProxyGroupID? in
                if case let .proxyGroup(id) = action { return id }
                return nil
            })
            groups = available.filter { used.contains($0.id) || $0.id == defaultID }
        }
    }
}
