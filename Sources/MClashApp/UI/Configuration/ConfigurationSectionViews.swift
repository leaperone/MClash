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
                    do {
                        let id = try await model.createConfigurationProxyGroup()
                        editRequest = ConfigurationEditRequest(
                            section: .proxyGroups,
                            itemID: id.rawValue
                        )
                    }
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
                    do {
                        let id = try await model.createConfigurationRule()
                        editRequest = ConfigurationEditRequest(
                            section: .rules,
                            itemID: id.rawValue
                        )
                    }
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
                title: configurationDisplayName(workspace.name),
                subtitle: AppLocalization.format(
                    "%@ nodes · %@ rules",
                    AppLocalization.number(workspace.nodeIDs.count),
                    AppLocalization.number(workspace.ruleIDs.count)
                ),
                symbol: "rectangle.3.group",
                detail: AppLocalization.string(
                    "A MClash strategy workspace shared by the configured traffic entrances."
                ),
                metadata: [
                    (
                        AppLocalization.string("Status"),
                        AppLocalization.string(
                            document.currentWorkspaceID == workspace.id
                                ? "Active"
                                : "Available"
                        )
                    ),
                    (
                        AppLocalization.string("Proxy Groups"),
                        AppLocalization.number(workspace.proxyGroupIDs.count)
                    ),
                    (
                        AppLocalization.string("Entrances"),
                        AppLocalization.number(workspace.entranceIDs.count)
                    ),
                    (
                        AppLocalization.string("Revision"),
                        AppLocalization.number(workspace.revision)
                    ),
                ]
            )
        }
        let sourceItems = document.sources.map { source in
            let count = document.nodes.count(where: { $0.sourceLinks.contains(source.id) })
            return Self(
                id: source.id.rawValue,
                title: source.displayName,
                subtitle: AppLocalization.format(
                    "%@ nodes · revision %@",
                    AppLocalization.number(count),
                    AppLocalization.number(source.revision)
                ),
                symbol: source.kind == .subscription ? "link" : "folder",
                detail: AppLocalization.string(
                    "Imported source. MClash uses it for node data only; source strategy sections are ignored."
                ),
                metadata: [
                    (AppLocalization.string("Kind"), source.kind.localizedTitle),
                    (
                        AppLocalization.string("Location"),
                        source.location == "local"
                            ? AppLocalization.string("Local")
                            : source.location
                    ),
                    (AppLocalization.string("Nodes"), AppLocalization.number(count)),
                ]
            )
        }
        let nodeItems = document.nodes.map { node in
            let sourceNames = node.sourceLinks.compactMap { sourceByID[$0]?.displayName }.joined(separator: ", ")
            return Self(
                id: node.id.rawValue,
                title: node.userAlias ?? node.displayName,
                subtitle: "\(node.proto.rawValue) · \(node.host):\(node.port)",
                symbol: "point.3.filled.connected.trianglepath.dotted",
                detail: AppLocalization.string(
                    "A strategy-owned node. Refreshing a source updates its connection data without changing group membership."
                ),
                metadata: [
                    (
                        AppLocalization.string("Source"),
                        sourceNames.isEmpty ? AppLocalization.string("Unknown") : sourceNames
                    ),
                    (
                        AppLocalization.string("Availability"),
                        node.health.availability.localizedTitle
                    ),
                    (
                        AppLocalization.string("Fingerprint"),
                        String(node.fingerprint.prefix(12))
                    ),
                ],
                isEnabled: node.enabled
            )
        }
        let groupItems = document.proxyGroups.map { group in
            Self(
                id: group.id.rawValue,
                title: configurationDisplayName(group.name),
                subtitle: AppLocalization.format(
                    "%@ · %@ members",
                    group.type.localizedTitle,
                    AppLocalization.number(group.members.count)
                ),
                symbol: "square.3.layers.3d",
                detail: AppLocalization.string(
                    "A MClash-owned proxy group. Members reference nodes or other MClash groups."
                ),
                metadata: [
                    (
                        AppLocalization.string("Status"),
                        AppLocalization.string(group.enabled ? "Enabled" : "Disabled")
                    ),
                    (
                        AppLocalization.string("Members"),
                        AppLocalization.number(group.members.count)
                    ),
                    (
                        AppLocalization.string("Used by"),
                        AppLocalization.format(
                            "%@ workspaces",
                            AppLocalization.number(
                                document.workspaces.count(where: {
                                    $0.proxyGroupIDs.contains(group.id)
                                })
                            )
                        )
                    ),
                ],
                isEnabled: group.enabled
            )
        }
        let ruleItems = document.rules.map { rule in
            let action: String
            switch rule.action {
            case .direct: action = AppLocalization.string("Direct")
            case .reject: action = AppLocalization.string("Reject")
            case let .proxyGroup(id):
                action = groupByID[id].map {
                    configurationDisplayName($0.name)
                } ?? AppLocalization.string("Missing Group")
            }
            return Self(
                id: rule.id.rawValue,
                title: AppLocalization.format("Rule %d", rule.priority),
                subtitle: AppLocalization.format(
                    "%@ matchers · %@",
                    AppLocalization.number(rule.matchers.count),
                    action
                ),
                symbol: "list.bullet.indent",
                detail: AppLocalization.string(
                    "A unified rule shared by HTTP, SOCKS5, App Routing and TUN when their context is available."
                ),
                metadata: [
                    (
                        AppLocalization.string("Priority"),
                        AppLocalization.number(rule.priority)
                    ),
                    (AppLocalization.string("Action"), action),
                    (
                        AppLocalization.string("Status"),
                        AppLocalization.string(rule.enabled ? "Enabled" : "Disabled")
                    ),
                ],
                isEnabled: rule.enabled
            )
        }
        let entranceItems = document.entrances.map { entrance in
            Self(
                id: entrance.id.rawValue,
                title: entrance.kind.localizedTitle,
                subtitle: entrance.port.map { "127.0.0.1:\($0)" }
                    ?? AppLocalization.string("System Capability"),
                symbol: entrance.kind == .appRouting ? "app.badge" : "arrow.triangle.branch",
                detail: entrance.kind == .appRouting
                    ? AppLocalization.string(
                        "Application capture is a capability switch. Its rules are managed in the unified Rules workspace."
                    )
                    : AppLocalization.string(
                        "A MClash traffic entrance that follows the active Workspace."
                    ),
                metadata: [
                    (
                        AppLocalization.string("Status"),
                        AppLocalization.string(entrance.enabled ? "Enabled" : "Disabled")
                    ),
                    (AppLocalization.string("Bind Address"), entrance.bindAddress),
                    (
                        AppLocalization.string("Workspace"),
                        AppLocalization.string(
                            entrance.workspaceOverride == nil
                                ? "Current Workspace"
                                : "Override"
                        )
                    ),
                ],
                isEnabled: entrance.enabled
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
