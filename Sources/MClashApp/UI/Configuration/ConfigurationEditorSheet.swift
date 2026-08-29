import SwiftUI

struct ConfigurationEditorSheet: View {
    @Bindable var model: AppModel
    let section: ConfigurationWorkbenchSection
    let id: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var alias = ""
    @State private var enabled = true
    @State private var groupType: ProxyGroupType = .select
    @State private var selectedNodeIDs: Set<NodeID> = []
    @State private var selectedGroupIDs: Set<ProxyGroupID> = []
    @State private var selectedRuleIDs: Set<RoutingRuleID> = []
    @State private var selectedEntranceIDs: Set<EntranceID> = []
    @State private var priority = 100
    @State private var bindAddress = "127.0.0.1"
    @State private var portText = ""
    @State private var action = RuleActionChoice.direct
    @State private var matcherText = ""
    @State private var originalMatchers: [RoutingMatcher] = []
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                editorForm
            }
            .formStyle(.grouped)
            .navigationTitle(
                AppLocalization.format(
                    "Edit %@",
                    AppLocalization.string(section.singularTitle)
                )
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("Save")) { save() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .task { load() }
        }
        .frame(minWidth: 460, minHeight: 420)
        .alert(
            AppLocalization.string("Could Not Save Configuration"),
            isPresented: errorIsPresented
        ) {
            Button(AppLocalization.string("OK"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var editorForm: some View {
        switch section {
        case .nodes:
            Section(AppLocalization.string("Node")) {
                TextField(AppLocalization.string("Alias (Optional)"), text: $alias)
                Toggle(AppLocalization.string("Enabled"), isOn: $enabled)
            }
        case .proxyGroups:
            Section(AppLocalization.string("Proxy Group")) {
                TextField(AppLocalization.string("Name"), text: $name)
                Picker(AppLocalization.string("Type"), selection: $groupType) {
                    ForEach(ProxyGroupType.allCases, id: \.self) { type in
                        Text(type.localizedTitle).tag(type)
                    }
                }
                Toggle(AppLocalization.string("Enabled"), isOn: $enabled)
                nodeSelection
                groupSelection
            }
        case .rules:
            Section(AppLocalization.string("Rule")) {
                TextField(AppLocalization.string("Priority"), value: $priority, format: .number)
                Picker(AppLocalization.string("Action"), selection: $action) {
                    Text(AppLocalization.string("Direct")).tag(RuleActionChoice.direct)
                    Text(AppLocalization.string("Reject")).tag(RuleActionChoice.reject)
                    ForEach(model.configurationDocument.proxyGroups) { group in
                        Text(configurationDisplayName(group.name))
                            .tag(RuleActionChoice.group(group.id))
                    }
                }
                TextField(AppLocalization.string("Domain suffix (Optional)"), text: $matcherText)
                Toggle(AppLocalization.string("Enabled"), isOn: $enabled)
            }
        case .workspaces:
            Section(AppLocalization.string("Workspace")) {
                TextField(AppLocalization.string("Name"), text: $name)
                nodeSelection
                groupSelection
                ruleSelection
                entranceSelection
            }
        case .entrances:
            Section(AppLocalization.string("Entrance")) {
                TextField(AppLocalization.string("Bind Address"), text: $bindAddress)
                TextField(AppLocalization.string("Port (Optional)"), text: $portText)
                    .textFieldStyle(.roundedBorder)
                Toggle(AppLocalization.string("Enabled"), isOn: $enabled)
            }
        case .sources:
            Section(AppLocalization.string("Source")) {
                Text(AppLocalization.string("Sources are refreshed from the original profile and provide node data only."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var nodeSelection: some View {
        Section(AppLocalization.string("Nodes")) {
            if model.configurationDocument.nodes.isEmpty {
                Text(AppLocalization.string("No nodes imported yet."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.configurationDocument.nodes) { node in
                    Toggle(isOn: Binding(
                        get: { selectedNodeIDs.contains(node.id) },
                        set: { value in
                            if value { selectedNodeIDs.insert(node.id) } else { selectedNodeIDs.remove(node.id) }
                        }
                    )) {
                        Text(node.userAlias ?? node.displayName)
                    }
                }
            }
        }
    }

    private var groupSelection: some View {
        Section(AppLocalization.string("Proxy Groups")) {
            ForEach(model.configurationDocument.proxyGroups.filter {
                section != .proxyGroups || $0.id.rawValue != id
            }) { group in
                Toggle(isOn: Binding(
                    get: { selectedGroupIDs.contains(group.id) },
                    set: { value in
                        if value { selectedGroupIDs.insert(group.id) } else { selectedGroupIDs.remove(group.id) }
                    }
                )) { Text(configurationDisplayName(group.name)) }
            }
        }
    }

    private var ruleSelection: some View {
        Section(AppLocalization.string("Rules")) {
            ForEach(model.configurationDocument.rules) { rule in
                Toggle(isOn: Binding(
                    get: { selectedRuleIDs.contains(rule.id) },
                    set: { value in
                        if value { selectedRuleIDs.insert(rule.id) } else { selectedRuleIDs.remove(rule.id) }
                    }
                )) {
                    Text(AppLocalization.format("Rule %d", rule.priority))
                }
            }
        }
    }

    private var entranceSelection: some View {
        Section(AppLocalization.string("Entrances")) {
            ForEach(model.configurationDocument.entrances) { entrance in
                Toggle(isOn: Binding(
                    get: { selectedEntranceIDs.contains(entrance.id) },
                    set: { value in
                        if value { selectedEntranceIDs.insert(entrance.id) } else { selectedEntranceIDs.remove(entrance.id) }
                    }
                )) { Text(entrance.kind.localizedTitle) }
            }
        }
    }

    private func load() {
        switch section {
        case .nodes:
            guard let node = model.configurationDocument.nodes.first(where: { $0.id.rawValue == id }) else { return }
            alias = node.userAlias ?? ""
            enabled = node.enabled
        case .proxyGroups:
            guard let group = model.configurationDocument.proxyGroups.first(where: { $0.id.rawValue == id }) else { return }
            name = configurationDisplayName(group.name)
            groupType = group.type
            enabled = group.enabled
            selectedNodeIDs = Set(group.members.compactMap { if case let .node(nodeID) = $0 { return nodeID }; return nil })
            selectedGroupIDs = Set(group.members.compactMap { if case let .group(groupID) = $0 { return groupID }; return nil })
            selectedGroupIDs.remove(group.id)
        case .rules:
            guard let rule = model.configurationDocument.rules.first(where: { $0.id.rawValue == id }) else { return }
            priority = rule.priority
            enabled = rule.enabled
            originalMatchers = rule.matchers
            if let matcher = rule.matchers.first(where: {
                if case .domainSuffix = $0 { return true }
                return false
            }), case let .domainSuffix(value) = matcher {
                matcherText = value
            }
            switch rule.action {
            case .direct: action = .direct
            case .reject: action = .reject
            case let .proxyGroup(groupID): action = .group(groupID)
            }
        case .workspaces:
            guard let workspace = model.configurationDocument.workspaces.first(where: { $0.id.rawValue == id }) else { return }
            name = configurationDisplayName(workspace.name)
            selectedNodeIDs = Set(workspace.nodeIDs)
            selectedGroupIDs = Set(workspace.proxyGroupIDs)
            selectedRuleIDs = Set(workspace.ruleIDs)
            selectedEntranceIDs = Set(workspace.entranceIDs)
        case .entrances:
            guard let entrance = model.configurationDocument.entrances.first(where: { $0.id.rawValue == id }) else { return }
            bindAddress = entrance.bindAddress
            portText = entrance.port.map(String.init) ?? ""
            enabled = entrance.enabled
        case .sources:
            break
        }
    }

    private func save() {
        var document = model.configurationDocument
        switch section {
        case .nodes:
            guard let index = document.nodes.firstIndex(where: { $0.id.rawValue == id }) else { return }
            let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            document.nodes[index].userAlias = normalized.isEmpty ? nil : normalized
            document.nodes[index].enabled = enabled
        case .proxyGroups:
            guard let index = document.proxyGroups.firstIndex(where: { $0.id.rawValue == id }) else { return }
            let normalized = canonicalConfigurationDefaultName(
                name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard !normalized.isEmpty else { errorMessage = AppLocalization.string("Name is required."); return }
            document.proxyGroups[index].name = normalized
            document.proxyGroups[index].type = groupType
            document.proxyGroups[index].enabled = enabled
            document.proxyGroups[index].members = selectedNodeIDs.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }.map { .node($0) }
                + selectedGroupIDs.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }.map { .group($0) }
            let group = document.proxyGroups[index]
            let cycle = document.currentWorkspace.flatMap { current -> ConfigurationDiagnostic? in
                var validationWorkspace = current
                validationWorkspace.proxyGroupIDs = document.proxyGroups.map(\.id)
                return document.diagnostics(for: validationWorkspace).first {
                    $0.code == "group_cycle"
                        && $0.subject == String(describing: group.id.rawValue)
                }
            }
            if let cycle {
                errorMessage = cycle.message
                return
            }
        case .rules:
            guard let index = document.rules.firstIndex(where: { $0.id.rawValue == id }) else { return }
            document.rules[index].priority = max(0, priority)
            document.rules[index].enabled = enabled
            document.rules[index].action = action.routingAction
            let normalized = matcherText.trimmingCharacters(in: .whitespacesAndNewlines)
            var matchers = originalMatchers
            if let matcherIndex = matchers.firstIndex(where: {
                if case .domainSuffix = $0 { return true }
                return false
            }) {
                if normalized.isEmpty {
                    matchers.remove(at: matcherIndex)
                } else {
                    matchers[matcherIndex] = .domainSuffix(normalized)
                }
            } else if !normalized.isEmpty {
                matchers.append(.domainSuffix(normalized))
            }
            document.rules[index].matchers = matchers
        case .workspaces:
            guard let index = document.workspaces.firstIndex(where: { $0.id.rawValue == id }) else { return }
            let normalized = canonicalConfigurationDefaultName(
                name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard !normalized.isEmpty else { errorMessage = AppLocalization.string("Name is required."); return }
            document.workspaces[index].name = normalized
            document.workspaces[index].nodeIDs = Array(selectedNodeIDs).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            document.workspaces[index].proxyGroupIDs = Array(selectedGroupIDs).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            document.workspaces[index].ruleIDs = Array(selectedRuleIDs).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            document.workspaces[index].entranceIDs = Array(selectedEntranceIDs).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            document.workspaces[index].revision += 1
        case .entrances:
            guard let index = document.entrances.firstIndex(where: { $0.id.rawValue == id }) else { return }
            let normalizedAddress = bindAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedAddress.isEmpty else { errorMessage = AppLocalization.string("Bind address is required."); return }
            let normalizedPort = portText.trimmingCharacters(in: .whitespacesAndNewlines)
            let port = normalizedPort.isEmpty ? nil : Int(normalizedPort)
            if normalizedPort.isEmpty == false && (port == nil || !(1...65_535).contains(port!)) {
                errorMessage = AppLocalization.string("Port must be between 1 and 65535.")
                return
            }
            document.entrances[index].bindAddress = normalizedAddress
            document.entrances[index].port = port
            document.entrances[index].enabled = enabled
        case .sources:
            dismiss()
            return
        }
        Task {
            do {
                try await model.saveConfigurationDocument(document)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

private enum RuleActionChoice: Hashable, Identifiable {
    case direct, reject, group(ProxyGroupID)
    var id: String { switch self { case .direct: "direct"; case .reject: "reject"; case let .group(id): "group-\(id.rawValue.uuidString)" } }
    var routingAction: RoutingAction { switch self { case .direct: .direct; case .reject: .reject; case let .group(id): .proxyGroup(id) } }
}
