import SwiftUI

struct ConfigurationView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MClashLayout.sectionSpacing) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(AppLocalization.string("Configuration"), systemImage: "slider.horizontal.3")
                        .font(.title.weight(.semibold))
                    Text(AppLocalization.string("MClash combines imported nodes with rules, groups, DNS and entrances managed here."))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GroupBox {
                    HStack(alignment: .top, spacing: MClashLayout.controlSpacing) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.configurationDocument.currentWorkspace.map { configurationDisplayName($0.name) } ?? AppLocalization.string("No Configuration"))
                                .font(.headline)
                            if let workspace = model.configurationDocument.currentWorkspace {
                                Text(AppLocalization.format("This configuration is used by %@ entrances and contains %@ rules.", AppLocalization.number(workspace.entranceIDs.count), AppLocalization.number(workspace.ruleIDs.count)))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(AppLocalization.string("Create a configuration after importing your first source."))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: MClashLayout.compactSpacing)
                        if let workspace = model.configurationDocument.currentWorkspace {
                            if model.unifiedConfigurationEnabled {
                                if configurationIsApplied(workspace) {
                                    Label(AppLocalization.string("Active"), systemImage: "bolt.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                } else {
                                    Button(AppLocalization.string("Apply changes")) {
                                        Task {
                                            do {
                                                try await model.activateConfigurationWorkspace(workspace.id)
                                            } catch {
                                                model.errorMessage = error.localizedDescription
                                            }
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            } else {
                                Button(AppLocalization.string("Use This Configuration")) {
                                    Task {
                                        do {
                                            try await model.activateConfigurationWorkspace(workspace.id)
                                        } catch {
                                            model.errorMessage = error.localizedDescription
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                    if !model.unifiedConfigurationEnabled {
                        Label(
                            AppLocalization.string("Activate this configuration to let MClash replace imported profile strategies with its own nodes, rules, groups and DNS."),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                    }
                }

                let document = model.configurationDocument
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: MClashLayout.controlSpacing)], spacing: MClashLayout.controlSpacing) {
                    configurationMetric(AppLocalization.string("Nodes"), value: document.nodes.count, symbol: "point.3.connected.trianglepath.dotted")
                    configurationMetric(AppLocalization.string("Node Groups"), value: document.proxyGroups.count, symbol: "square.3.layers.3d")
                    configurationMetric(AppLocalization.string("Rules"), value: document.rules.count, symbol: "list.bullet.indent")
                    configurationMetric(AppLocalization.string("Entrances"), value: document.entrances.count, symbol: "arrow.triangle.branch")
                    configurationMetric(AppLocalization.string("DNS"), value: document.dnsPolicies.count, symbol: "network")
                }

                GroupBox(AppLocalization.string("Open a section")) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)],
                        alignment: .leading,
                        spacing: MClashLayout.compactSpacing
                    ) {
                        configurationLink(AppLocalization.string("Rules"), symbol: "list.bullet.indent", destination: .rules)
                        configurationLink(AppLocalization.string("Node Groups"), symbol: "square.3.layers.3d", destination: .proxyGroups)
                        configurationLink(AppLocalization.string("Nodes"), symbol: "point.3.connected.trianglepath.dotted", destination: .nodes)
                        configurationLink(AppLocalization.string("Entrances"), symbol: "arrow.triangle.branch", destination: .entrances)
                        configurationLink(AppLocalization.string("DNS"), symbol: "network", destination: .dns)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Label(AppLocalization.string("Sources contribute node connection data only. Their groups, rules, DNS and TUN settings are not executed by MClash."), systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(MClashLayout.pagePadding)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .mclashPageSurface()
        .navigationTitle(AppLocalization.string("Configuration"))
    }

    private func configurationMetric(_ title: String, value: Int, symbol: String) -> some View {
        GroupBox {
            HStack(spacing: MClashLayout.compactSpacing) {
                Image(systemName: symbol).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLocalization.number(value))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func configurationLink(_ title: String, symbol: String, destination: AppModel.Destination) -> some View {
        Button { model.selection = destination } label: {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.bordered)
    }

    private func configurationIsApplied(_ workspace: Workspace) -> Bool {
        model.configurationDiagnostics.contains(where: { $0.code == "configuration_compile_failed" }) == false
            && model.compiledConfiguration?.workspaceID == workspace.id
            && model.compiledConfiguration?.workspaceRevision == workspace.revision
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
            title: AppLocalization.string("Node Groups"),
            sections: [.proxyGroups],
            items: model.configurationWorkbenchItems,
            onAdd: { _ in
                editRequest = ConfigurationEditRequest(
                    section: .proxyGroups,
                    itemID: UUID(),
                    isNew: true
                )
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
            ConfigurationEditorSheet(model: model, section: request.section, id: request.itemID, isNew: request.isNew)
        }
    }
}

struct ConfigurationRulesView: View {
    @Bindable var model: AppModel
    @State private var editRequest: ConfigurationRuleEditRequest?
    @State private var applicationCandidates: [ApplicationCaptureCandidate] = []
    var body: some View {
        ConfigurationWorkbench(
            title: AppLocalization.string("Rules"),
            sections: [.rules],
            items: model.configurationWorkbenchItems,
            onAdd: { _ in
                editRequest = ConfigurationRuleEditRequest(rule: nil)
            },
            statusMessage: model.configurationStatusMessage,
            onToggleEnabled: { section, id in
                Task {
                    do { try await model.toggleConfigurationEnabled(section: section, id: id) }
                    catch { model.errorMessage = error.localizedDescription }
                }
            },
            onEdit: { _, id in
                let rule = model.configurationDocument.rules.first { $0.id.rawValue == id }
                editRequest = ConfigurationRuleEditRequest(rule: rule)
            }
        )
        .sheet(item: $editRequest) { request in
            UnifiedRoutingRuleEditor(
                rule: request.rule,
                proxyGroups: model.configurationDocument.proxyGroups,
                applicationCandidates: applicationCandidates,
                onSave: { rule in
                    Task {
                        do {
                            try await model.saveConfigurationRule(rule)
                            editRequest = nil
                        } catch {
                            model.errorMessage = error.localizedDescription
                        }
                    }
                },
                onCancel: { editRequest = nil }
            )
        }
        .task {
            applicationCandidates = (await ApplicationCaptureCandidateProvider().loadRunningCandidates()).applications
        }
    }
}

struct ConfigurationEntrancesView: View {
    @Bindable var model: AppModel
    @State private var editRequest: ConfigurationEditRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            appRoutingCapability
                .padding(.horizontal, MClashLayout.pagePadding)
                .padding(.top, MClashLayout.compactPagePadding)
                .padding(.bottom, MClashLayout.compactPagePadding)
            Divider()
            ConfigurationWorkbench(
                title: AppLocalization.string("Entrances"),
                sections: [.entrances],
                items: entranceWorkbenchItems,
                onAdd: { _ in
                    editRequest = ConfigurationEditRequest(
                        section: .entrances,
                        itemID: UUID(),
                        isNew: true
                    )
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
        }
        .sheet(item: $editRequest) { request in
            ConfigurationEditorSheet(model: model, section: request.section, id: request.itemID, isNew: request.isNew)
        }
    }

    private var entranceWorkbenchItems: [ConfigurationWorkbenchSection: [ConfigurationWorkbenchItem]] {
        var items = model.configurationWorkbenchItems
        // App Routing is a capability switch, not a second editable entrance.
        // Keep its state in the card above and remove the duplicate row from
        // the resource list so there is one obvious control surface.
        items[.entrances] = items[.entrances, default: []].filter {
            $0.title != AppLocalization.string("Application traffic")
                && $0.title != AppLocalization.string("App Routing")
        }
        return items
    }

    private var appRoutingCapability: some View {
        HStack(spacing: MClashLayout.controlSpacing) {
            Image(systemName: "app.badge")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.string("Application traffic"))
                    .font(.headline)
                Text(AppLocalization.string("Use the unified Rules page to match applications, domains, IPs and ports."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: MClashLayout.compactSpacing)
            Toggle("", isOn: Binding(
                get: { model.appRoutingCapabilityEnabled },
                set: { value in Task { await model.setNetworkCaptureEnabled(value) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(
                model.pendingNetworkCaptureEnabled != nil
                    || !model.canPerform(.changeNetworkCapture)
            )
            .accessibilityLabel(AppLocalization.string("Application traffic capture"))
            .accessibilityValue(AppLocalization.string(model.appRoutingCapabilityEnabled ? "Enabled" : "Disabled"))
        }
        .padding(MClashLayout.controlSpacing)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ConfigurationDNSView: View {
    @Bindable var model: AppModel
    @State private var editRequest: ConfigurationEditRequest?

    var body: some View {
        ConfigurationWorkbench(
            title: AppLocalization.string("DNS"),
            sections: [.dns],
            items: model.configurationWorkbenchItems,
            onAdd: { _ in
                editRequest = ConfigurationEditRequest(
                    section: .dns,
                    itemID: UUID(),
                    isNew: true
                )
            },
            statusMessage: model.configurationStatusMessage,
            onEdit: { section, id in
                editRequest = ConfigurationEditRequest(section: section, itemID: id)
            }
        )
        .sheet(item: $editRequest) { request in
            ConfigurationEditorSheet(model: model, section: request.section, id: request.itemID, isNew: request.isNew)
        }
    }
}

struct ConfigurationWorkspacesView: View {
    @Bindable var model: AppModel
    @State private var editRequest: ConfigurationEditRequest?
    var body: some View {
        ConfigurationWorkbench(
            title: AppLocalization.string("Configuration"),
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
    var isNew = false
    var id: String { "\(section.rawValue):\(itemID.uuidString):\(isNew)" }
}

struct ConfigurationRuleEditRequest: Identifiable {
    let id = UUID()
    let rule: RoutingRule?
}

private func rulePresentationDetail(_ rule: RoutingRule, action: String) -> String {
    let conditions = ruleConditionPresentation(rule.matchers)
    if conditions.isEmpty {
        return AppLocalization.format("Matches traffic and sends it to %@.", action)
    }
    return AppLocalization.format("When %@, send traffic to %@.", conditions, action)
}

private enum RuleMatcherFamily: String, CaseIterable, Hashable {
    case application, destination, protocolValue, port
}

private func ruleConditionPresentation(_ matchers: [RoutingMatcher]) -> String {
    let andWord = AppLocalization.string("and")
    let orWord = AppLocalization.string("or")
    let grouped = Dictionary(grouping: matchers, by: ruleMatcherFamily)
    let parts = RuleMatcherFamily.allCases.compactMap { family -> String? in
        let values = grouped[family, default: []].map(ruleMatcherPresentation)
        guard !values.isEmpty else { return nil }
        return values.count == 1 ? values[0] : values.joined(separator: " \(orWord) ")
    }
    return parts.joined(separator: " \(andWord) ")
}

private func ruleMatcherFamily(_ matcher: RoutingMatcher) -> RuleMatcherFamily {
    switch matcher {
    case .application, .processPath, .userID: .application
    case .domainExact, .domainSuffix, .domainWildcard, .ipCIDR: .destination
    case .transport: .protocolValue
    case .port, .portRange: .port
    }
}

private func ruleMatcherPresentation(_ matcher: RoutingMatcher) -> String {
    switch matcher {
    case let .application(value): return AppLocalization.format("App %@", value)
    case let .processPath(value): return AppLocalization.format("Process %@", URL(fileURLWithPath: value).lastPathComponent)
    case let .userID(value): return AppLocalization.format("User %@", String(value))
    case let .domainExact(value): return value
    case let .domainSuffix(value): return "*.\(value)"
    case let .domainWildcard(value): return value
    case let .ipCIDR(value): return value
    case let .transport(value): return value.uppercased()
    case let .port(value): return AppLocalization.format("Port %d", value)
    case let .portRange(value): return AppLocalization.format("Port %d-%d", value.lowerBound, value.upperBound)
    }
}

private extension ConfigurationWorkbenchItem {
    static func from(document: ConfigurationDocument) -> [ConfigurationWorkbenchSection: [Self]] {
        let groupByID = Dictionary(
            document.proxyGroups.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let sourceByID = Dictionary(
            document.sources.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let workspaceItems = document.workspaces.map { workspace in
            let nodeScope = workspace.nodeIDs.isEmpty
                ? AppLocalization.string("All enabled nodes")
                : AppLocalization.format("%@ nodes", AppLocalization.number(workspace.nodeIDs.count))
            return Self(
                id: workspace.id.rawValue,
                title: configurationDisplayName(workspace.name),
                subtitle: AppLocalization.format(
                    "%@ · %@ rules",
                    nodeScope,
                    AppLocalization.number(workspace.ruleIDs.count)
                ),
                symbol: "rectangle.3.group",
                detail: AppLocalization.string(
                    "A MClash configuration shared by the configured traffic entrances."
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
                        AppLocalization.string("Node Groups"),
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
                        Self.sourceDisplayLocation(source)
                    ),
                    (AppLocalization.string("Nodes"), AppLocalization.number(count)),
                ] + (!source.parseDiagnostics.isEmpty
                    ? [(AppLocalization.string("Diagnostics"), AppLocalization.number(source.parseDiagnostics.count))]
                    : [])
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
                ] + (node.region.map { [(AppLocalization.string("Region"), $0)] } ?? [])
                    + (!node.tags.isEmpty
                        ? [(AppLocalization.string("Tags"), node.tags.sorted().joined(separator: ", "))]
                        : []),
                isEnabled: node.enabled
            )
        }
        let selectorNodes = document.nodes.filter {
            $0.enabled
                && $0.health.availability != .sourceRemoved
                && $0.health.availability != .unsupported
        }
        let groupItems = document.proxyGroups.map { group in
            let resolution = NodeSelectorResolver.resolve(
                selectors: group.memberSelectors,
                nodes: selectorNodes
            )
            let explicitNodeIDs = Set(group.members.compactMap { member -> NodeID? in
                if case let .node(id) = member { return id }
                return nil
            })
            let selectorPinnedIDs = Set(group.memberSelectors.flatMap(\.fixedNodeIDs))
            let fixedCount = explicitNodeIDs.union(selectorPinnedIDs).count
            let effectiveCount = explicitNodeIDs.union(selectorPinnedIDs).union(resolution.nodeIDs).count
            return Self(
                id: group.id.rawValue,
                title: configurationDisplayName(group.name),
                subtitle: AppLocalization.format(
                    "%@ · %@ nodes",
                    group.type.localizedTitle,
                    AppLocalization.number(effectiveCount)
                ),
                symbol: "square.3.layers.3d",
                detail: AppLocalization.string(
                    "A MClash-owned group. Pin specific nodes or add automatic conditions that update after a source refresh."
                ),
                metadata: [
                    (
                        AppLocalization.string("Status"),
                        AppLocalization.string(group.enabled ? "Enabled" : "Disabled")
                    ),
                    (
                        AppLocalization.string("Fixed members"),
                        AppLocalization.number(fixedCount)
                    ),
                    (
                        AppLocalization.string("Automatic selectors"),
                        AppLocalization.number(group.memberSelectors.count)
                    ),
                    (
                        AppLocalization.string("Automatic matches"),
                        AppLocalization.number(resolution.nodeIDs.count)
                    ),
                    (
                        AppLocalization.string("Used by"),
                        AppLocalization.format(
                            "%@ configurations",
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
                title: rule.matchers.first.map(ruleMatcherPresentation)
                    ?? AppLocalization.format("Rule %d", rule.priority),
                subtitle: AppLocalization.format(
                    "%@ conditions · %@",
                    AppLocalization.number(rule.matchers.count),
                    action
                ),
                symbol: "list.bullet.indent",
                detail: rulePresentationDetail(rule, action: action),
                metadata: [
                    (
                        AppLocalization.string("Priority"),
                        AppLocalization.number(rule.priority)
                    ),
                    (
                        AppLocalization.string("When"),
                        ruleConditionPresentation(rule.matchers)
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
        let dnsItems = document.dnsPolicies.map { policy in
            let isCurrent = document.currentWorkspace?.dnsPolicyID == policy.id
            return Self(
                id: policy.id.rawValue,
                title: policy.name,
                subtitle: AppLocalization.format(
                    "%@ · %@ nameservers",
                    policy.mode.rawValue,
                    AppLocalization.number(policy.nameservers.count)
                ),
                symbol: "network",
                detail: AppLocalization.string(
                    "A MClash-owned DNS policy shared by the active configuration."
                ),
                metadata: [
                    (AppLocalization.string("Status"), AppLocalization.string(isCurrent ? "Active" : "Available")),
                    (AppLocalization.string("Mode"), policy.mode.rawValue),
                    (AppLocalization.string("Nameservers"), AppLocalization.number(policy.nameservers.count)),
                    (AppLocalization.string("Fallback resolvers"), AppLocalization.number(policy.fallbackNameservers.count)),
                    (AppLocalization.string("DNS takeover"), AppLocalization.string(policy.takeoverEnabled ? "Enabled" : "Disabled")),
                ]
            )
        }
        let entranceItems = document.entrances.map { entrance in
            let title = entrance.kind == .appRouting
                ? AppLocalization.string("Application traffic")
                : entrance.kind.localizedTitle
            return Self(
                id: entrance.id.rawValue,
                title: title,
                subtitle: entrance.port.map { "127.0.0.1:\($0)" }
                    ?? AppLocalization.string("System Capability"),
                symbol: entrance.kind == .appRouting ? "app.badge" : "arrow.triangle.branch",
                detail: entrance.kind == .appRouting
                    ? AppLocalization.string(
                    "Application capture is a capability switch. Its rules are managed on the unified Rules page."
                    )
                    : AppLocalization.string(
                        "A MClash traffic entrance that follows the active configuration."
                    ),
                metadata: [
                    (
                        AppLocalization.string("Status"),
                        AppLocalization.string(entrance.enabled ? "Enabled" : "Disabled")
                    ),
                    (AppLocalization.string("Bind Address"), entrance.bindAddress),
                    (
                            AppLocalization.string("Configuration"),
                        AppLocalization.string(
                            entrance.workspaceOverride == nil
                                ? "Current configuration"
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
            .dns: dnsItems,
        ]
    }

    private static func sourceDisplayLocation(_ source: Source) -> String {
        guard source.location != "local",
              source.kind == .subscription,
              var components = URLComponents(string: source.location) else {
            if source.location == "local" {
                return AppLocalization.string("Local")
            }
            return source.kind == .subscription
                ? AppLocalization.string("Subscription")
                : source.location
        }
        // Subscription URLs can contain access tokens in query/userinfo. Keep
        // the persisted source untouched, but never expose those credentials
        // in the ordinary Source inspector.
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if let host = components.host {
            return components.port.map { "\(host):\($0)" } ?? host
        }
        return components.host ?? AppLocalization.string("Subscription")
    }
}

extension AppModel {
    var configurationWorkbenchItems: [ConfigurationWorkbenchSection: [ConfigurationWorkbenchItem]] {
        ConfigurationWorkbenchItem.from(document: configurationDocument)
    }
}
