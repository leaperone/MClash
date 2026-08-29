import SwiftUI

struct ConfigurationView: View {
    @Bindable var model: AppModel

    var body: some View {
        ConfigurationWorkbench(
            title: "Configuration",
            items: model.configurationWorkbenchItems,
            statusMessage: model.configurationStatusMessage,
            onToggleEnabled: { section, id in
                Task {
                    do { try await model.toggleConfigurationEnabled(section: section, id: id) }
                    catch { model.errorMessage = error.localizedDescription }
                }
            }
        )
        .navigationTitle(AppLocalization.string("Configuration"))
    }
}

/// Ready-to-wire section views. They intentionally expose one consistent
/// workbench API so navigation can be migrated independently later.
struct ConfigurationSourcesView: View {
    @Bindable var model: AppModel
    @State private var editRequest: ConfigurationEditRequest?
    var body: some View {
        ConfigurationWorkbench(
            title: AppLocalization.string("Sources"),
            sections: [.sources],
            items: model.configurationWorkbenchItems,
            onAdd: { _ in Task { await model.importConfigurationSource() } },
            statusMessage: model.configurationStatusMessage
        )
    }
}

struct ConfigurationNodesView: View {
    @Bindable var model: AppModel
    @State private var editRequest: ConfigurationEditRequest?
    var body: some View {
        ConfigurationWorkbench(
            title: AppLocalization.string("Nodes"),
            sections: [.nodes],
            items: model.configurationWorkbenchItems,
            statusMessage: model.configurationStatusMessage,
            onToggleEnabled: { section, id in
                Task {
                    do { try await model.toggleConfigurationEnabled(section: section, id: id) }
                    catch { model.errorMessage = error.localizedDescription }
                }
            },
            onEdit: { section, id in editRequest = ConfigurationEditRequest(section: section, itemID: id) }
        )
        .sheet(item: $editRequest) { request in
            ConfigurationEditorSheet(model: model, section: request.section, id: request.itemID)
        }
    }
}

struct ConfigurationProxyGroupsView: View {
    @Bindable var model: AppModel
    @State private var editRequest: ConfigurationEditRequest?
    var body: some View {
        ConfigurationWorkbench(
            title: AppLocalization.string("Proxy Groups"),
            sections: [.proxyGroups],
            items: model.configurationWorkbenchItems,
            onAdd: { _ in
                Task {
                    do { try await model.createConfigurationProxyGroup() }
                    catch { model.errorMessage = error.localizedDescription }
                }
            },
            statusMessage: model.configurationStatusMessage,
            onToggleEnabled: { section, id in
                Task {
                    do { try await model.toggleConfigurationEnabled(section: section, id: id) }
                    catch { model.errorMessage = error.localizedDescription }
                }
            },
            onEdit: { section, id in editRequest = ConfigurationEditRequest(section: section, itemID: id) }
        )
        .sheet(item: $editRequest) { request in
            ConfigurationEditorSheet(model: model, section: request.section, id: request.itemID)
        }
    }
}

struct ConfigurationRulesView: View {
    @Bindable var model: AppModel
    @State private var editRequest: ConfigurationEditRequest?
    var body: some View {
        ConfigurationWorkbench(
            title: AppLocalization.string("Rules"),
            sections: [.rules],
            items: model.configurationWorkbenchItems,
            onAdd: { _ in
                Task {
                    do { try await model.createConfigurationRule() }
                    catch { model.errorMessage = error.localizedDescription }
                }
            },
            statusMessage: model.configurationStatusMessage,
            onToggleEnabled: { section, id in
                Task {
                    do { try await model.toggleConfigurationEnabled(section: section, id: id) }
                    catch { model.errorMessage = error.localizedDescription }
                }
            },
            onEdit: { section, id in editRequest = ConfigurationEditRequest(section: section, itemID: id) }
        )
        .sheet(item: $editRequest) { request in
            ConfigurationEditorSheet(model: model, section: request.section, id: request.itemID)
        }
    }
}

struct ConfigurationEntrancesView: View {
    @Bindable var model: AppModel
    @State private var editRequest: ConfigurationEditRequest?

    var body: some View {
        ConfigurationWorkbench(
            title: AppLocalization.string("Entrances"),
            sections: [.entrances],
            items: model.configurationWorkbenchItems,
            statusMessage: model.configurationStatusMessage,
            onToggleEnabled: { section, id in
                Task {
                    do { try await model.toggleConfigurationEnabled(section: section, id: id) }
                    catch { model.errorMessage = error.localizedDescription }
                }
            },
            onEdit: { section, id in editRequest = ConfigurationEditRequest(section: section, itemID: id) }
        )
        .sheet(item: $editRequest) { request in
            ConfigurationEditorSheet(model: model, section: request.section, id: request.itemID)
        }
    }
}

struct ConfigurationWorkspacesView: View {
    @Bindable var model: AppModel
    @State private var editRequest: ConfigurationEditRequest?
    var body: some View {
        ConfigurationWorkbench(
            title: AppLocalization.string("Workspaces"),
            sections: [.workspaces],
            items: model.configurationWorkbenchItems,
            onAdd: { _ in
                Task {
                    do { try await model.createConfigurationWorkspace() }
                    catch { model.errorMessage = error.localizedDescription }
                }
            },
            onActivate: { id in
                Task {
                    do { try await model.activateConfigurationWorkspace(WorkspaceID(rawValue: id)) }
                    catch { model.errorMessage = error.localizedDescription }
                }
            },
            statusMessage: model.configurationStatusMessage,
            onEdit: { section, id in editRequest = ConfigurationEditRequest(section: section, itemID: id) }
        )
        .sheet(item: $editRequest) { request in
            ConfigurationEditorSheet(model: model, section: request.section, id: request.itemID)
        }
    }
}

struct ConfigurationEditRequest: Identifiable {
    let section: ConfigurationWorkbenchSection
    let itemID: UUID
    var id: String { "\(section.rawValue):\(itemID.uuidString)" }
}

private extension ConfigurationWorkbenchItem {
    static func from(document: ConfigurationDocument) -> [ConfigurationWorkbenchSection: [Self]] {
        let groupByID = Dictionary(uniqueKeysWithValues: document.proxyGroups.map { ($0.id, $0) })
        let sourceByID = Dictionary(uniqueKeysWithValues: document.sources.map { ($0.id, $0) })
        let workspaceItems = document.workspaces.map { workspace in
            Self(
                id: workspace.id.rawValue,
                title: workspace.name,
                subtitle: "\(workspace.nodeIDs.count) nodes · \(workspace.ruleIDs.count) rules",
                symbol: "rectangle.3.group",
                detail: "A MClash strategy workspace shared by the configured traffic entrances.",
                metadata: [
                    ("Status", document.currentWorkspaceID == workspace.id ? "Active" : "Available"),
                    ("Proxy groups", "\(workspace.proxyGroupIDs.count)"),
                    ("Entrances", "\(workspace.entranceIDs.count)"),
                    ("Revision", "\(workspace.revision)"),
                ]
            )
        }
        let sourceItems = document.sources.map { source in
            let count = document.nodes.count(where: { $0.sourceLinks.contains(source.id) })
            return Self(
                id: source.id.rawValue,
                title: source.displayName,
                subtitle: "\(count) nodes · revision \(source.revision)",
                symbol: source.kind == .subscription ? "link" : "folder",
                detail: "Imported source. MClash uses it for node data only; source strategy sections are ignored.",
                metadata: [("Kind", source.kind.rawValue), ("Location", source.location), ("Nodes", "\(count)")]
            )
        }
        let nodeItems = document.nodes.map { node in
            let sourceNames = node.sourceLinks.compactMap { sourceByID[$0]?.displayName }.joined(separator: ", ")
            return Self(
                id: node.id.rawValue,
                title: node.userAlias ?? node.displayName,
                subtitle: "\(node.proto.rawValue) · \(node.host):\(node.port)",
                symbol: "point.3.filled.connected.trianglepath.dotted",
                detail: "A strategy-owned node. Refreshing a source updates its connection data without changing group membership.",
                metadata: [
                    ("Source", sourceNames.isEmpty ? "Unknown" : sourceNames),
                    ("Availability", node.health.availability.rawValue),
                    ("Fingerprint", String(node.fingerprint.prefix(12))),
                ]
            )
        }
        let groupItems = document.proxyGroups.map { group in
            Self(
                id: group.id.rawValue,
                title: group.name,
                subtitle: "\(group.type.rawValue) · \(group.members.count) members",
                symbol: "square.3.layers.3d",
                detail: "A MClash-owned proxy group. Members reference nodes or other MClash groups.",
                metadata: [("Enabled", group.enabled ? "Yes" : "No"), ("Members", "\(group.members.count)"), ("Used by", "\(document.workspaces.count(where: { $0.proxyGroupIDs.contains(group.id) })) workspaces")]
            )
        }
        let ruleItems = document.rules.map { rule in
            let action: String
            switch rule.action {
            case .direct: action = "DIRECT"
            case .reject: action = "REJECT"
            case let .proxyGroup(id): action = groupByID[id]?.name ?? "Missing group"
            }
            return Self(
                id: rule.id.rawValue,
                title: "Rule \(rule.priority)",
                subtitle: "\(rule.matchers.count) matchers · \(action)",
                symbol: "list.bullet.indent",
                detail: "A unified rule shared by HTTP, SOCKS5, App Routing and TUN when their context is available.",
                metadata: [("Priority", "\(rule.priority)"), ("Action", action), ("Enabled", rule.enabled ? "Yes" : "No")]
            )
        }
        let entranceItems = document.entrances.map { entrance in
            Self(
                id: entrance.id.rawValue,
                title: entrance.kind.rawValue.uppercased(),
                subtitle: entrance.port.map { "127.0.0.1:\($0)" } ?? "System capability",
                symbol: entrance.kind == .appRouting ? "app.badge" : "arrow.triangle.branch",
                detail: entrance.kind == .appRouting
                    ? "Application capture is a capability switch. Its rules are managed in the unified Rules workspace."
                    : "A MClash traffic entrance that follows the active Workspace.",
                metadata: [
                    ("Enabled", entrance.enabled ? "Yes" : "No"),
                    ("Bind", entrance.bindAddress),
                    ("Workspace", entrance.workspaceOverride == nil ? "Current Workspace" : "Override"),
                ]
            )
        }
        return [
            .workspaces: workspaceItems,
            .sources: sourceItems,
            .nodes: nodeItems,
            .proxyGroups: groupItems,
            .rules: ruleItems,
            .entrances: entranceItems,
        ]
    }
}

extension AppModel {
    var configurationWorkbenchItems: [ConfigurationWorkbenchSection: [ConfigurationWorkbenchItem]] {
        ConfigurationWorkbenchItem.from(document: configurationDocument)
    }
}
