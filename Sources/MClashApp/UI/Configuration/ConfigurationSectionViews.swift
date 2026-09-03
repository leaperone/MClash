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
                                Text(AppLocalization.string(
                                    model.activeProfileID == nil
                                        ? "Choose a node source for the active MClash configuration."
                                        : "Create a configuration after importing your first source."
                                ))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: MClashLayout.compactSpacing)
                        if let workspace = model.configurationDocument.currentWorkspace {
                            if model.activeProfileID == nil {
                                Button(AppLocalization.string("Sources")) {
                                    model.selection = .sources
                                }
                                .buttonStyle(.borderedProminent)
                            } else if model.unifiedConfigurationEnabled {
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

                if model.configurationDocument.currentWorkspace != nil {
                    configurationRoutingModeCard
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

    private var configurationRoutingModeCard: some View {
        let workspace = model.configurationDocument.currentWorkspace
        let mode = workspace?.routingMode ?? .rule
        let groups = model.configurationDocument.proxyGroups.filter { group in
            group.enabled && workspace?.proxyGroupIDs.contains(group.id) == true
        }
        return GroupBox {
            VStack(alignment: .leading, spacing: MClashLayout.controlSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Label(
                        AppLocalization.string("How traffic is routed"),
                        systemImage: "arrow.triangle.branch"
                    )
                    .font(.headline)
                    Spacer()
                    if model.pendingMode != nil {
                        ProgressView().controlSize(.small)
                    }
                }
                Picker(
                    AppLocalization.string("Routing mode"),
                    selection: Binding(
                        get: { mode },
                        set: { nextMode in
                            Task {
                                do {
                                    _ = try await model.setConfigurationRoutingMode(nextMode)
                                } catch {
                                    model.errorMessage = error.localizedDescription
                                }
                            }
                        }
                    )
                ) {
                    Text(AppLocalization.string("Rule")).tag(ConfigurationRoutingMode.rule)
                    Text(AppLocalization.string("Global")).tag(ConfigurationRoutingMode.global)
                    Text(AppLocalization.string("Direct")).tag(ConfigurationRoutingMode.direct)
                }
                .pickerStyle(.segmented)
                .disabled(model.pendingMode != nil || !model.canPerform(.changeRuntimeSettings))

                Text(configurationRoutingModeExplanation(mode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if mode == .global, !groups.isEmpty {
                    Picker(
                        AppLocalization.string("Global exit"),
                        selection: Binding(
                            get: {
                                workspace?.globalProxyGroupID ?? groups[0].id
                            },
                            set: { groupID in
                                Task {
                                    do {
                                        try await model.setConfigurationGlobalProxyGroup(
                                            groupID
                                        )
                                    } catch {
                                        model.errorMessage = error.localizedDescription
                                    }
                                }
                            }
                        )
                    ) {
                        ForEach(groups) { group in
                            Text(configurationDisplayName(group.name)).tag(group.id)
                        }
                    }
                    .frame(maxWidth: 360, alignment: .leading)
                    .help(AppLocalization.string("The selected group is used by Global mode."))
                }
            }
        }
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
        VStack(spacing: 0) {
            Label(
                AppLocalization.string("A node keeps the same identity when its name, tags or credentials change. Protocol, normalized host, port and transport settings define the stable fingerprint; an endpoint change creates a new node."),
                systemImage: "fingerprint"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, MClashLayout.pagePadding)
            .padding(.vertical, MClashLayout.compactSpacing)
            Divider()
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
        }
        .sheet(item: $editRequest) { request in
            ConfigurationEditorSheet(model: model, section: request.section, id: request.itemID)
        }
    }
}

struct ConfigurationProxyGroupsView: View {
    @Bindable var model: AppModel
    @State private var editRequest: ConfigurationEditRequest?
    @State private var showsPresetConfirmation = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            commonStrategyGroups
                .padding(.horizontal, MClashLayout.pagePadding)
                .padding(.vertical, MClashLayout.compactPagePadding)
            Divider()
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
        }
        .sheet(item: $editRequest) { request in
            ConfigurationEditorSheet(model: model, section: request.section, id: request.itemID, isNew: request.isNew)
        }
        .alert(
            AppLocalization.string("Install Node Selection setup?"),
            isPresented: $showsPresetConfirmation
        ) {
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
            Button(AppLocalization.string("Install setup")) {
                Task {
                    do { try await model.installCommonProxyGroupPreset() }
                    catch { model.errorMessage = error.localizedDescription }
                }
            }
        } message: {
            Text(AppLocalization.string("Adds Node Selection, US/JP/HK priority, Auto, Manual, Failover, Residential and Direct groups. Existing rules are redirected to Node Selection; source rules are not imported."))
        }
    }

    private var commonPresetInstalled: Bool {
        model.configurationDocument.proxyGroups.contains {
            $0.name == ConfigurationProxyGroupPreset.mainGroupName
        }
    }

    private var commonStrategyGroups: some View {
        HStack(spacing: MClashLayout.controlSpacing) {
            Image(systemName: commonPresetInstalled ? "checkmark.circle.fill" : "point.3.filled.connected.trianglepath.dotted")
                .font(.title3)
                .foregroundStyle(commonPresetInstalled ? Color.green : Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.string("Node Selection setup"))
                    .font(.headline)
                Text(AppLocalization.string("One stable parent for rules, with regional and automatic child groups that refresh with your sources."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    [
                        AppLocalization.string("Rules"),
                        configurationDisplayName(ConfigurationProxyGroupPreset.mainGroupName),
                        AppLocalization.string("US / United States"),
                        AppLocalization.string("Nodes"),
                    ].joined(separator: " → ")
                )
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: MClashLayout.compactSpacing)
            if commonPresetInstalled {
                Text(AppLocalization.string("Added"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Button(AppLocalization.string("Install setup")) {
                    showsPresetConfirmation = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct ConfigurationRulesView: View {
    @Bindable var model: AppModel
    @State private var editRequest: ConfigurationRuleEditRequest?
    @State private var ruleSetEditRequest: ConfigurationEditRequest?
    @State private var tab: RulesSurface = .rules
    @State private var applicationCandidates: [ApplicationCaptureCandidate] = []
    var body: some View {
        VStack(spacing: 0) {
            Picker(AppLocalization.string("Rules surface"), selection: $tab) {
                Text(AppLocalization.string("Rules")).tag(RulesSurface.rules)
                Text(AppLocalization.string("Rule Sets")).tag(RulesSurface.ruleSets)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .padding(.horizontal, MClashLayout.pagePadding)
            .padding(.vertical, MClashLayout.compactSpacing)
            .accessibilityLabel(AppLocalization.string("Rules surface"))
            Divider()
            if tab == .rules {
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
            } else {
                ConfigurationWorkbench(
                    title: AppLocalization.string("Rule Sets"),
                    sections: [.ruleSets],
                    items: model.configurationWorkbenchItems,
                    onAdd: { _ in
                        ruleSetEditRequest = ConfigurationEditRequest(
                            section: .ruleSets,
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
                    onEdit: { section, id in
                        ruleSetEditRequest = ConfigurationEditRequest(section: section, itemID: id)
                    }
                )
            }
        }
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
        .sheet(item: $ruleSetEditRequest) { request in
            ConfigurationEditorSheet(
                model: model,
                section: request.section,
                id: request.itemID,
                isNew: request.isNew
            )
        }
        .task {
            applicationCandidates = (await ApplicationCaptureCandidateProvider().loadRunningCandidates()).applications
        }
    }
}

private enum RulesSurface: String, CaseIterable, Identifiable {
    case rules, ruleSets
    var id: Self { self }
}

struct ConfigurationEntrancesView: View {
    @Bindable var model: AppModel
    @State private var editRequest: ConfigurationEditRequest?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: MClashLayout.compactSpacing) {
                Text(AppLocalization.string("Traffic entrances"))
                    .font(.title3.weight(.semibold))
                Text(AppLocalization.string("Choose how traffic enters MClash. Routing mode, rules and node groups determine where it goes next."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
                .padding(.horizontal, MClashLayout.pagePadding)
                .padding(.vertical, MClashLayout.compactPagePadding)
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
                        do {
                            if section == .entrances,
                               model.configurationDocument.entrances.first(where: {
                                   $0.id.rawValue == id
                               })?.kind == .appRouting {
                                await model.setNetworkCaptureEnabled(
                                    !model.appRoutingCapabilityEnabled
                                )
                            } else {
                                try await model.toggleConfigurationEnabled(
                                    section: section,
                                    id: id
                                )
                            }
                        } catch {
                            model.errorMessage = error.localizedDescription
                        }
                    }
                },
                onEdit: { section, id in
                    editRequest = ConfigurationEditRequest(section: section, itemID: id)
                }
            )
        }
        .sheet(item: $editRequest) { request in
            ConfigurationEditorSheet(model: model, section: request.section, id: request.itemID, isNew: request.isNew)
        }
    }

    private var entranceWorkbenchItems: [ConfigurationWorkbenchSection: [ConfigurationWorkbenchItem]] {
        model.configurationWorkbenchItems
    }

    private var appRoutingEntranceControl: some View {
        let hasEntrance = model.configurationDocument.entrances.contains { $0.kind == .appRouting }
        return HStack(spacing: 12) {
            Image(systemName: "app.badge")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.string("App Routing"))
                    .font(.headline)
                Text(AppLocalization.string("Route selected applications through this configuration. Rules stay on the Rules page; this switch only controls the entrance."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(
                AppLocalization.string("App Routing"),
                isOn: Binding(
                    get: { hasEntrance && model.appRoutingCapabilityEnabled },
                    set: { enabled in
                        Task { await model.setNetworkCaptureEnabled(enabled) }
                    }
                )
            )
            .labelsHidden()
            .disabled(!hasEntrance || !model.canPerform(.changeNetworkCapture))
            .accessibilityLabel(AppLocalization.string("App Routing"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MClashLayout.compactPagePadding)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    /// macOS System Proxy is a capture entrance, not a configuration or
    /// advanced setting. It is displayed beside App Routing while retaining
    /// its distinct system-level semantics and recovery state.
    private var systemProxyEntranceControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "macbook.and.iphone")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.string("macOS System Proxy"))
                    .font(.headline)
                Text(AppLocalization.string("Send macOS application traffic to a MClash HTTP or SOCKS entrance."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.systemProxyRecoveryRequired {
                    Label(AppLocalization.string("Needs restoration"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            Toggle(
                AppLocalization.string("macOS System Proxy"),
                isOn: Binding(
                    get: { model.pendingSystemProxyEnabled ?? model.systemProxyEnabled },
                    set: { enabled in
                        Task { await model.setSystemProxyEnabled(enabled) }
                    }
                )
            )
            .labelsHidden()
            .disabled(!model.canPerform(.changeSystemProxy) || model.systemProxyRecoveryRequired)
            .accessibilityLabel(AppLocalization.string("macOS System Proxy"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MClashLayout.compactPagePadding)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
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
    case .application, .processPath, .processName, .userID: .application
    case .domainExact, .domainSuffix, .domainWildcard, .ipCIDR,
         .geoIP, .geoIP6, .geoSite: .destination
    case .transport: .protocolValue
    case .port, .portRange: .port
    }
}

private func ruleMatcherPresentation(_ matcher: RoutingMatcher) -> String {
    switch matcher {
    case let .application(value): return AppLocalization.format("App %@", value)
    case let .processPath(value): return AppLocalization.format("Process %@", URL(fileURLWithPath: value).lastPathComponent)
    case let .processName(value): return AppLocalization.format("Process %@", value)
    case let .userID(value): return AppLocalization.format("User %@", String(value))
    case let .domainExact(value): return value
    case let .domainSuffix(value): return "*.\(value)"
    case let .domainWildcard(value): return value
    case let .ipCIDR(value): return value
    case let .geoIP(value): return AppLocalization.format("GEOIP %@", value)
    case let .geoIP6(value): return AppLocalization.format("GEOIP6 %@", value)
    case let .geoSite(value): return AppLocalization.format("GEOSITE %@", value)
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
                    "%@ · %@ · %@ rules",
                    nodeScope,
                    configurationRoutingModeTitle(workspace.routingMode),
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
                        AppLocalization.string("Routing mode"),
                        configurationRoutingModeTitle(workspace.routingMode)
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
            let nestedOrder = group.members.compactMap { member in
                if case let .group(id) = member {
                    return document.proxyGroups.first(where: { $0.id == id })?.name
                }
                return nil
            }.map { configurationDisplayName($0) }.joined(separator: " → ")
            return Self(
                id: group.id.rawValue,
                title: configurationDisplayName(group.name),
                subtitle: AppLocalization.format(
                    "%@ · %@ nodes · %@ automatic · %@ fixed",
                    group.type.localizedTitle,
                    AppLocalization.number(effectiveCount),
                    AppLocalization.number(resolution.nodeIDs.count),
                    AppLocalization.number(fixedCount)
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
                        AppLocalization.string("Nested group order"),
                        nestedOrder.isEmpty ? AppLocalization.string("None") : nestedOrder
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
                    "%@ → %@",
                    ruleConditionPresentation(rule.matchers).isEmpty
                        ? AppLocalization.string("All traffic")
                        : ruleConditionPresentation(rule.matchers),
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
        let ruleSetItems = document.ruleSets.map { ruleSet in
            let action: String
            switch ruleSet.defaultAction {
            case .direct: action = AppLocalization.string("Direct")
            case .reject: action = AppLocalization.string("Reject")
            case let .proxyGroup(id):
                action = groupByID[id].map { configurationDisplayName($0.name) }
                    ?? AppLocalization.string("Missing Group")
            }
            let source = ruleSet.sourceURL?.host
                ?? AppLocalization.string("Local entries")
            return Self(
                id: ruleSet.id.rawValue,
                title: ruleSet.name,
                subtitle: AppLocalization.format(
                    "%@ · %@ rules · %@",
                    ruleSet.behavior.localizedTitle,
                    AppLocalization.number(ruleSet.rules.count),
                    source
                ),
                symbol: "list.bullet.rectangle",
                detail: AppLocalization.string(
                    "A MClash-owned reusable rule collection. Imported source providers are never enabled automatically."
                ),
                metadata: [
                    (AppLocalization.string("Status"), AppLocalization.string(ruleSet.enabled ? "Enabled" : "Disabled")),
                    (AppLocalization.string("Behavior"), ruleSet.behavior.localizedTitle),
                    (AppLocalization.string("Format"), ruleSet.format.localizedTitle),
                    (AppLocalization.string("Entries"), AppLocalization.number(ruleSet.rules.count)),
                    (AppLocalization.string("Default action"), action),
                    (AppLocalization.string("Source"), source),
                    (AppLocalization.string("Used by"), AppLocalization.format(
                        "%@ configurations",
                        AppLocalization.number(document.workspaces.count(where: { $0.ruleSetIDs.contains(ruleSet.id) }))
                    )),
                ],
                isEnabled: ruleSet.enabled
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
            let title = entrance.name
            return Self(
                id: entrance.id.rawValue,
                title: title,
                subtitle: [
                    entrance.kind.localizedTitle,
                    entrance.port.map { "\(entrance.bindAddress):\($0)" }
                        ?? AppLocalization.string("Switch")
                ].joined(separator: " · "),
                symbol: entrance.kind == .appRouting ? "app.badge" : "arrow.triangle.branch",
                detail: entrance.kind == .appRouting
                    ? AppLocalization.string(
                    "Application Routing is a system entrance. Its matching rules are managed on the Rules page."
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
                    (AppLocalization.string("Type"), entrance.kind.localizedTitle),
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
            .ruleSets: ruleSetItems,
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
