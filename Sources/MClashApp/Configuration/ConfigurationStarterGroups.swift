import Foundation

enum ConfigurationStarterGroups {
    private static let strategies: [(ProxyGroupType, String)] = [
        (.select, "Select"), (.urlTest, "URL Test"), (.fallback, "Fallback"),
    ]

    static func groupID(_ type: ProxyGroupType, workspaceID: WorkspaceID) -> ProxyGroupID {
        .stable(for: "mclash-starter-groups-v1|\(workspaceID.rawValue)|\(type.rawValue)")
    }

    static func isInstalled(in document: ConfigurationDocument) -> Bool {
        guard let workspace = document.currentWorkspace else { return false }
        return strategies.allSatisfy { type, _ in
            let id = groupID(type, workspaceID: workspace.id)
            return workspace.proxyGroupIDs.contains(id) && document.proxyGroups.contains { $0.id == id }
        }
    }

    static func apply(to original: ConfigurationDocument) throws -> ConfigurationProxyGroupPreset.Result {
        guard let workspace = original.currentWorkspace,
              let workspaceIndex = original.workspaces.firstIndex(where: { $0.id == workspace.id }) else {
            throw ConfigurationProxyGroupPresetError.workspaceMissing
        }
        var document = original
        var created = 0
        var names = Set(document.proxyGroups.map(\.name) + document.nodes.map { $0.userAlias ?? $0.displayName })
        for (type, title) in strategies {
            let id = groupID(type, workspaceID: workspace.id)
            if !document.proxyGroups.contains(where: { $0.id == id }) {
                let baseName = AppLocalization.string(title)
                var name = baseName
                var suffix = 2
                while names.contains(name) {
                    name = "\(baseName) \(suffix)"
                    suffix += 1
                }
                names.insert(name)
                document.proxyGroups.append(ProxyGroup(
                    id: id, name: name, type: type,
                    memberSelectors: [NodeSelector(name: AppLocalization.string("All enabled nodes"))]
                ))
                created += 1
            }
            if !document.workspaces[workspaceIndex].proxyGroupIDs.contains(id) {
                document.workspaces[workspaceIndex].proxyGroupIDs.append(id)
            }
        }
        if document.workspaces[workspaceIndex].proxyGroupIDs != workspace.proxyGroupIDs {
            document.workspaces[workspaceIndex].revision += 1
        }
        return ConfigurationProxyGroupPreset.Result(
            document: document, mainGroupID: groupID(.select, workspaceID: workspace.id),
            createdGroupCount: created, redirectedRuleCount: 0
        )
    }
}
