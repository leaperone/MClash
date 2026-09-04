import SwiftUI

struct ConfigurationEditorSheet: View {
    @Bindable var model: AppModel
    let section: ConfigurationWorkbenchSection
    let id: UUID
    let isNew: Bool
    let isEmbedded: Bool
    let onSaved: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var alias = ""
    @State private var enabled = true
    @State private var groupType: ProxyGroupType = .select
    @State private var selectedNodeIDs: Set<NodeID> = []
    @State private var orderedNodeIDs: [NodeID] = []
    @State private var nodeSelectors: [NodeSelector] = []
    @State private var selectedGroupIDs: Set<ProxyGroupID> = []
    @State private var orderedGroupIDs: [ProxyGroupID] = []
    @State private var selectedRuleIDs: Set<RoutingRuleID> = []
    @State private var selectedRuleSetIDs: Set<RuleSetID> = []
    @State private var selectedEntranceIDs: Set<EntranceID> = []
    @State private var workspaceRoutingMode: ConfigurationRoutingMode = .rule
    @State private var workspaceGlobalProxyGroupID: ProxyGroupID?
    @State private var workspaceNodeSearch = ""
    @State private var entranceKind: EntranceKind = .http
    @State private var entranceAction = RuleActionChoice.direct
    @State private var bindAddress = "127.0.0.1"
    @State private var portText = ""
    @State private var dnsMode: DNSMode = .redirHost
    @State private var dnsNameserversText = ""
    @State private var dnsFallbackNameserversText = ""
    @State private var dnsProxyServerText = ""
    @State private var dnsRulesText = ""
    @State private var dnsTakeoverEnabled = false
    @State private var ruleSetBehavior: RuleSetBehavior = .classical
    @State private var ruleSetFormat: RuleSetFormat = .yaml
    @State private var ruleSetSourceURLText = ""
    @State private var ruleSetPathText = ""
    @State private var ruleSetRulesText = ""
    @State private var isRefreshingRuleSet = false
    @State private var errorMessage: String?

    init(
        model: AppModel,
        section: ConfigurationWorkbenchSection,
        id: UUID,
        isNew: Bool = false,
        isEmbedded: Bool = false,
        onSaved: (() -> Void)? = nil
    ) {
        self.model = model
        self.section = section
        self.id = id
        self.isNew = isNew
        self.isEmbedded = isEmbedded
        self.onSaved = onSaved
    }

    var body: some View {
        Group {
            if isEmbedded {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text(editorTitle)
                            .font(.headline)
                        Spacer(minLength: 0)
                        if section != .rules {
                            Button(AppLocalization.string("Save")) { save() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.horizontal, MClashLayout.pagePadding)
                    .padding(.vertical, 10)
                    Divider()
                    if section == .proxyGroups {
                        proxyGroupEmbeddedEditor
                    } else {
                        Form {
                            editorForm
                        }
                        .formStyle(.grouped)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NavigationStack {
                    Form {
                        editorForm
                    }
                    .formStyle(.grouped)
                    .navigationTitle(editorTitle)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(AppLocalization.string("Cancel")) { dismiss() }
                        }
                        if section != .rules {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(AppLocalization.string("Save")) { save() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
                .frame(
                    minWidth: section == .proxyGroups ? 760 : section == .ruleSets ? 620 : 460,
                    minHeight: section == .proxyGroups ? 680 : section == .ruleSets ? 560 : 420
                )
            }
        }
        .task { load() }
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

    private var editorTitle: String {
        AppLocalization.format(
            isNew ? "Create %@" : "Edit %@",
            AppLocalization.string(section.presentationSingularTitle)
        )
    }

    private var proxyGroupSourceNames: [SourceID: String] {
        Dictionary(
            model.configurationDocument.sources.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    @ViewBuilder
    private var proxyGroupIdentityFields: some View {
        Label(
            AppLocalization.string("Choose a group type, then add fixed nodes or automatic matches below."),
            systemImage: "checklist"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        TextField(AppLocalization.string("Name"), text: $name)
        Picker(AppLocalization.string("Type"), selection: $groupType) {
            ForEach(ProxyGroupType.allCases.filter { $0 != .relay }, id: \.self) { type in
                Text(type.localizedTitle).tag(type)
            }
        }
        Text(groupType.taskDescription)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Toggle(AppLocalization.string("Enabled"), isOn: $enabled)
    }

    private var proxyGroupEmbeddedEditor: some View {
        Form {
            Section(AppLocalization.string("Group")) {
                proxyGroupIdentityFields
            }
            NodeMembershipEditor(
                nodes: model.configurationDocument.nodes,
                sourceNames: proxyGroupSourceNames,
                selectedNodeIDs: $selectedNodeIDs,
                selectors: $nodeSelectors,
                orderedNodeIDs: $orderedNodeIDs
            )
            groupSelection
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Section(AppLocalization.string("Group")) {
                proxyGroupIdentityFields
                NodeMembershipEditor(
                    nodes: model.configurationDocument.nodes,
                    sourceNames: proxyGroupSourceNames,
                    selectedNodeIDs: $selectedNodeIDs,
                    selectors: $nodeSelectors,
                    orderedNodeIDs: $orderedNodeIDs
                )
                groupSelection
            }
        case .rules:
            Section(AppLocalization.string("Rule")) {
                Label(
                    AppLocalization.string("Rules are edited in the unified rule editor."),
                    systemImage: "list.bullet.indent"
                )
                .foregroundStyle(.secondary)
            }
        case .ruleSets:
            Section(AppLocalization.string("Rule Set")) {
                TextField(AppLocalization.string("Name"), text: $name)
                Toggle(AppLocalization.string("Enabled"), isOn: $enabled)
                Picker(AppLocalization.string("Behavior"), selection: $ruleSetBehavior) {
                    ForEach(RuleSetBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.localizedTitle).tag(behavior)
                    }
                }
                Picker(AppLocalization.string("Format"), selection: $ruleSetFormat) {
                    ForEach(RuleSetFormat.allCases, id: \.self) { format in
                        Text(format.localizedTitle).tag(format)
                    }
                }
                TextField(AppLocalization.string("Source URL (optional)"), text: $ruleSetSourceURLText)
                    .textFieldStyle(.roundedBorder)
                TextField(AppLocalization.string("Local cache path (optional)"), text: $ruleSetPathText)
                    .textFieldStyle(.roundedBorder)
                Picker(AppLocalization.string("Default action"), selection: $entranceAction) {
                    Text(AppLocalization.string("Direct")).tag(RuleActionChoice.direct)
                    Text(AppLocalization.string("Reject")).tag(RuleActionChoice.reject)
                    ForEach(model.configurationDocument.proxyGroups.filter(\.enabled)) { group in
                        Text(configurationDisplayName(group.name))
                            .tag(RuleActionChoice.group(group.id))
                    }
                }
                TextEditor(text: $ruleSetRulesText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                if !isNew, ruleSetSourceURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   ruleSetFormat == .text {
                    Button {
                        isRefreshingRuleSet = true
                        Task {
                            defer { isRefreshingRuleSet = false }
                            do {
                                _ = try await model.refreshConfigurationRuleSet(
                                    RuleSetID(rawValue: id)
                                )
                                load()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        if isRefreshingRuleSet {
                            ProgressView().controlSize(.small)
                        }
                        Label(
                            AppLocalization.string("Refresh native text rule set"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRefreshingRuleSet)
                    Text(AppLocalization.string("The HTTPS source is fetched into MClash's private cache and used on the next policy revision."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(AppLocalization.string("Inline entries are one routing rule per line. Native mode supports local classical text sets; URL, YAML and MRS sources need an explicit compatible loader."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .workspaces:
            Section(AppLocalization.string("Configuration")) {
                TextField(AppLocalization.string("Name"), text: $name)
                Picker(AppLocalization.string("Traffic mode"), selection: $workspaceRoutingMode) {
                    Text(AppLocalization.string("Rule — use the rule list")).tag(ConfigurationRoutingMode.rule)
                    Text(AppLocalization.string("Global — use one Global exit")).tag(ConfigurationRoutingMode.global)
                    Text(AppLocalization.string("Direct — bypass proxy groups")).tag(ConfigurationRoutingMode.direct)
                }
                if workspaceRoutingMode == .global {
                    let groups = model.configurationDocument.proxyGroups.filter { group in
                        group.enabled && selectedGroupIDs.contains(group.id)
                    }
                    if !groups.isEmpty {
                        Picker(AppLocalization.string("Global exit"), selection: Binding(
                            get: { workspaceGlobalProxyGroupID ?? groups[0].id },
                            set: { workspaceGlobalProxyGroupID = $0 }
                        )) {
                            ForEach(groups) { group in
                                Text(configurationDisplayName(group.name)).tag(group.id)
                            }
                        }
                    }
                }
                Text(configurationRoutingModeExplanation(workspaceRoutingMode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                nodeSelection
                groupSelection
                ruleSelection
                ruleSetSelection
                entranceSelection
            }
        case .entrances:
            Section(AppLocalization.string("Entrance")) {
                TextField(AppLocalization.string("Name"), text: $name)
                Picker(AppLocalization.string("Type"), selection: $entranceKind) {
                    ForEach(entranceKindOptions, id: \.self) { kind in
                        Text(kind.localizedTitle).tag(kind)
                    }
                }
                .disabled(!isNew)
                if entranceKind == .appRouting {
                    Text(AppLocalization.string("App Routing is an entrance. Its matching rules are managed on the Rules page."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if entranceKind == .tun {
                    Text(AppLocalization.string("TUN is not supported by this macOS runtime. Use HTTP, SOCKS5, or App Routing instead."))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField(AppLocalization.string("Bind Address"), text: $bindAddress)
                TextField(AppLocalization.string("Port (Optional)"), text: $portText)
                    .textFieldStyle(.roundedBorder)
                Picker(AppLocalization.string("Default action"), selection: $entranceAction) {
                    Text(AppLocalization.string("Direct")).tag(RuleActionChoice.direct)
                    Text(AppLocalization.string("Reject")).tag(RuleActionChoice.reject)
                    ForEach(model.configurationDocument.proxyGroups.filter(\.enabled)) { group in
                        Text(configurationDisplayName(group.name))
                            .tag(RuleActionChoice.group(group.id))
                    }
                }
                Toggle(AppLocalization.string("Enabled"), isOn: $enabled)
                    .disabled(entranceKind == .tun)
            }
        case .dns:
            Section(AppLocalization.string("DNS")) {
                Picker(AppLocalization.string("Mode"), selection: $dnsMode) {
                    ForEach(DNSMode.allCases, id: \.self) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
                if model.usesNativeRuntimeForDiagnostics, dnsMode == .fakeIP {
                    Text(AppLocalization.string(
                        "Native Fake IP DNS mode is not implemented yet. Choose Redir Host or System DNS."
                    ))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                TextField(AppLocalization.string("Nameservers (comma or newline separated)"), text: $dnsNameserversText, axis: .vertical)
                    .lineLimit(2...4)
                TextField(AppLocalization.string("Fallback resolvers (optional)"), text: $dnsFallbackNameserversText, axis: .vertical)
                    .lineLimit(2...4)
                TextField(AppLocalization.string("DNS proxy server (optional)"), text: $dnsProxyServerText)
                TextField(AppLocalization.string("DNS rules (one domain per line, optional)"), text: $dnsRulesText, axis: .vertical)
                    .lineLimit(2...4)
                Toggle(AppLocalization.string("Take over system DNS"), isOn: $dnsTakeoverEnabled)
                Text(AppLocalization.string("DNS is managed here independently from the App Routing capture switch."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .sources:
            Section(AppLocalization.string("Source")) {
                Text(AppLocalization.string("Sources are refreshed from the original profile and provide node data only."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var nodeSelection: some View {
        Section(AppLocalization.string("Node scope")) {
            if model.configurationDocument.nodes.isEmpty {
                Text(AppLocalization.string("No nodes imported yet."))
                    .foregroundStyle(.secondary)
            } else {
                Toggle(AppLocalization.string("Use all enabled nodes"), isOn: Binding(
                    get: { selectedNodeIDs.isEmpty },
                    set: { value in
                        if value {
                            selectedNodeIDs.removeAll()
                        } else if selectedNodeIDs.isEmpty {
                            selectedNodeIDs = Set(model.configurationDocument.nodes.filter(\.enabled).map(\.id))
                        }
                    }
                ))
                Text(selectedNodeIDs.isEmpty
                    ? AppLocalization.string("All enabled catalog nodes are available to groups.")
                    : AppLocalization.format("%@ nodes are in this configuration.", AppLocalization.number(selectedNodeIDs.count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !selectedNodeIDs.isEmpty {
                    TextField(AppLocalization.string("Search nodes by name or host"), text: $workspaceNodeSearch)
                        .textFieldStyle(.roundedBorder)
                    if workspaceNodeSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(AppLocalization.string("Enter a search term to edit a specific node scope."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredWorkspaceNodes) { node in
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
        }
    }

    private var filteredWorkspaceNodes: [Node] {
        let query = workspaceNodeSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.configurationDocument.nodes.filter { node in
            query.isEmpty
                || (node.userAlias ?? node.displayName).localizedCaseInsensitiveContains(query)
                || node.host.localizedCaseInsensitiveContains(query)
        }
    }

    private var groupSelection: some View {
        Section(AppLocalization.string("Node Groups")) {
            if section == .proxyGroups {
                Text(
                    groupTypeExplanation
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                List {
                    ForEach(orderedGroupIDs, id: \.self) { groupID in
                        if let group = model.configurationDocument.proxyGroups.first(where: {
                            $0.id == groupID
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.secondary)
                                Text(configurationDisplayName(group.name))
                                    .lineLimit(1)
                                Spacer()
                                let position = orderedGroupIDs.firstIndex(of: groupID) ?? 0
                                Button {
                                    moveNestedGroup(from: position, by: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(position == 0)
                                .accessibilityLabel(AppLocalization.string("Move nested group up"))
                                Button {
                                    moveNestedGroup(from: position, by: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(position >= orderedGroupIDs.count - 1)
                                .accessibilityLabel(AppLocalization.string("Move nested group down"))
                                Button {
                                    selectedGroupIDs.remove(groupID)
                                    orderedGroupIDs.removeAll { $0 == groupID }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(AppLocalization.string("Remove nested group"))
                            }
                        }
                    }
                    .onMove { offsets, destination in
                        orderedGroupIDs.move(fromOffsets: offsets, toOffset: destination)
                    }
                    ForEach(model.configurationDocument.proxyGroups.filter {
                        $0.id.rawValue != id && !selectedGroupIDs.contains($0.id)
                    }) { group in
                        Button {
                            selectedGroupIDs.insert(group.id)
                            orderedGroupIDs.append(group.id)
                        } label: {
                            Label(
                                configurationDisplayName(group.name),
                                systemImage: "plus.circle"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minHeight: 100, maxHeight: 260)
            } else {
                ForEach(model.configurationDocument.proxyGroups.filter {
                    $0.id.rawValue != id
                }) { group in
                    Toggle(isOn: Binding(
                        get: { selectedGroupIDs.contains(group.id) },
                        set: { value in
                            if value {
                                selectedGroupIDs.insert(group.id)
                                if !orderedGroupIDs.contains(group.id) {
                                    orderedGroupIDs.append(group.id)
                                }
                            } else {
                                selectedGroupIDs.remove(group.id)
                                orderedGroupIDs.removeAll { $0 == group.id }
                            }
                        }
                    )) { Text(configurationDisplayName(group.name)) }
                }
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

    private var ruleSetSelection: some View {
        Section(AppLocalization.string("Rule Sets")) {
            ForEach(model.configurationDocument.ruleSets) { ruleSet in
                Toggle(isOn: Binding(
                    get: { selectedRuleSetIDs.contains(ruleSet.id) },
                    set: { value in
                        if value { selectedRuleSetIDs.insert(ruleSet.id) }
                        else { selectedRuleSetIDs.remove(ruleSet.id) }
                    }
                )) {
                    Text(ruleSet.name)
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
                )) {
                    Text(entrance.kind.localizedTitle)
                }
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
            guard let group = model.configurationDocument.proxyGroups.first(where: { $0.id.rawValue == id }) else {
                guard isNew else { return }
                name = ""
                groupType = .select
                enabled = true
                nodeSelectors = []
                selectedNodeIDs = []
                orderedNodeIDs = []
                selectedGroupIDs = []
                orderedGroupIDs = []
                return
            }
            name = configurationDisplayName(group.name)
            groupType = group.type
            enabled = group.enabled
            selectedNodeIDs = Set(group.members.compactMap { if case let .node(nodeID) = $0 { return nodeID }; return nil })
            orderedNodeIDs = group.members.compactMap {
                if case let .node(nodeID) = $0 { return nodeID }
                return nil
            }
            nodeSelectors = group.memberSelectors
            for selector in group.memberSelectors {
                selectedNodeIDs.formUnion(selector.fixedNodeIDs)
                orderedNodeIDs.append(contentsOf: selector.fixedNodeIDs)
            }
            orderedNodeIDs = orderedNodeIDs.filter { selectedNodeIDs.contains($0) }
                + selectedNodeIDs.subtracting(Set(orderedNodeIDs)).sorted {
                    $0.rawValue.uuidString < $1.rawValue.uuidString
                }
            selectedGroupIDs = Set(group.members.compactMap { if case let .group(groupID) = $0 { return groupID }; return nil })
            orderedGroupIDs = group.members.compactMap {
                if case let .group(groupID) = $0 { return groupID }
                return nil
            }
            selectedGroupIDs.remove(group.id)
        case .rules:
            return
        case .ruleSets:
            guard let ruleSet = model.configurationDocument.ruleSets.first(where: { $0.id.rawValue == id }) else {
                guard isNew else { return }
                name = ""
                enabled = true
                ruleSetBehavior = .classical
                ruleSetFormat = .yaml
                ruleSetSourceURLText = ""
                ruleSetPathText = ""
                ruleSetRulesText = ""
                entranceAction = model.configurationDocument.proxyGroups
                    .first(where: \.enabled)
                    .map { .group($0.id) } ?? .direct
                return
            }
            name = ruleSet.name
            enabled = ruleSet.enabled
            ruleSetBehavior = ruleSet.behavior
            ruleSetFormat = ruleSet.format
            ruleSetSourceURLText = ruleSet.sourceURL?.absoluteString ?? ""
            ruleSetPathText = ruleSet.path ?? ""
            ruleSetRulesText = ruleSet.rules.joined(separator: "\n")
            entranceAction = switch ruleSet.defaultAction {
            case .direct: .direct
            case .reject: .reject
            case let .proxyGroup(groupID): .group(groupID)
            }
        case .workspaces:
            guard let workspace = model.configurationDocument.workspaces.first(where: { $0.id.rawValue == id }) else { return }
            name = configurationDisplayName(workspace.name)
            selectedNodeIDs = Set(workspace.nodeIDs)
            let enabledNodeIDs = Set(model.configurationDocument.nodes.filter(\.enabled).map(\.id))
            if selectedNodeIDs == enabledNodeIDs {
                selectedNodeIDs.removeAll()
            }
            selectedGroupIDs = Set(workspace.proxyGroupIDs)
            orderedGroupIDs = workspace.proxyGroupIDs
            workspaceRoutingMode = workspace.routingMode
            workspaceGlobalProxyGroupID = workspace.globalProxyGroupID
            selectedRuleIDs = Set(workspace.ruleIDs)
            selectedRuleSetIDs = Set(workspace.ruleSetIDs)
            selectedEntranceIDs = Set(workspace.entranceIDs)
            selectedEntranceIDs.formUnion(
                model.configurationDocument.entrances
                    .filter { $0.kind == .appRouting }
                    .map(\.id)
            )
        case .entrances:
            guard let entrance = model.configurationDocument.entrances.first(where: { $0.id.rawValue == id }) else {
                guard isNew else { return }
                entranceKind = .http
                name = uniqueEntranceName(for: entranceKind)
                entranceAction = model.configurationDocument.proxyGroups
                    .first(where: \.enabled)
                    .map { .group($0.id) }
                    ?? .direct
                bindAddress = "127.0.0.1"
                portText = defaultEntrancePort().map(String.init) ?? ""
                enabled = true
                return
            }
            entranceKind = entrance.kind
            name = entrance.name
            switch entrance.defaultAction {
            case .direct: entranceAction = .direct
            case .reject: entranceAction = .reject
            case let .proxyGroup(groupID): entranceAction = .group(groupID)
            }
            bindAddress = entrance.bindAddress
            portText = entrance.port.map(String.init) ?? ""
            enabled = entrance.enabled
        case .dns:
            guard let policy = model.configurationDocument.dnsPolicies.first(where: { $0.id.rawValue == id }) else {
                guard isNew else { return }
                name = ""
                dnsMode = .redirHost
                dnsNameserversText = "223.5.5.5\n1.1.1.1"
                dnsFallbackNameserversText = ""
                dnsProxyServerText = ""
                dnsRulesText = ""
                dnsTakeoverEnabled = true
                return
            }
            name = policy.name
            dnsMode = policy.mode
            dnsNameserversText = policy.nameservers.joined(separator: "\n")
            dnsFallbackNameserversText = policy.fallbackNameservers.joined(separator: "\n")
            dnsProxyServerText = policy.proxyServer ?? ""
            dnsRulesText = policy.rules.joined(separator: "\n")
            dnsTakeoverEnabled = policy.takeoverEnabled
        case .sources:
            break
        }
    }

    private func save() {
        var document = model.configurationDocument
        var appRoutingEnableAfterSave: Bool?
        switch section {
        case .nodes:
            guard let index = document.nodes.firstIndex(where: { $0.id.rawValue == id }) else { return }
            let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            document.nodes[index].userAlias = normalized.isEmpty ? nil : normalized
            document.nodes[index].enabled = enabled
            for workspaceIndex in document.workspaces.indices
            where document.workspaces[workspaceIndex].nodeIDs.isEmpty
                || document.workspaces[workspaceIndex].nodeIDs.contains(document.nodes[index].id) {
                document.workspaces[workspaceIndex].revision += 1
            }
        case .proxyGroups:
            let normalized = canonicalConfigurationDefaultName(
                name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard !normalized.isEmpty else { errorMessage = AppLocalization.string("Name is required."); return }
            let selectorPinnedIDs = Set(nodeSelectors.flatMap(\.fixedNodeIDs))
            let explicitNodeIDs = nodeSelectors.isEmpty
                ? selectedNodeIDs
                : selectedNodeIDs.subtracting(selectorPinnedIDs)
            let orderedNodes = orderedNodeIDs.filter(explicitNodeIDs.contains)
                + explicitNodeIDs.subtracting(Set(orderedNodeIDs)).sorted {
                    $0.rawValue.uuidString < $1.rawValue.uuidString
                }
            let memberNodes = orderedNodes.map { ProxyGroupMember.node($0) }
            let orderedGroups = orderedGroupIDs.filter(selectedGroupIDs.contains)
            let remainingGroups = selectedGroupIDs.subtracting(orderedGroups)
                .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            let memberGroups = (orderedGroups + remainingGroups)
                .map { ProxyGroupMember.group($0) }
            let group: ProxyGroup
            if let index = document.proxyGroups.firstIndex(where: { $0.id.rawValue == id }) {
                document.proxyGroups[index].name = normalized
                document.proxyGroups[index].type = groupType
                document.proxyGroups[index].enabled = enabled
                document.proxyGroups[index].members = memberNodes + memberGroups
                document.proxyGroups[index].memberSelectors = nodeSelectors
                group = document.proxyGroups[index]
            } else if isNew {
                group = ProxyGroup(
                    id: ProxyGroupID(rawValue: id),
                    name: normalized,
                    type: groupType,
                    members: memberNodes + memberGroups,
                    memberSelectors: nodeSelectors,
                    enabled: enabled
                )
                document.proxyGroups.append(group)
                if let workspaceIndex = currentWorkspaceIndex(in: document),
                   !document.workspaces[workspaceIndex].proxyGroupIDs.contains(group.id) {
                    document.workspaces[workspaceIndex].proxyGroupIDs.append(group.id)
                }
            } else { return }
            let cycle = document.currentWorkspace.flatMap { current -> ConfigurationDiagnostic? in
                var validationWorkspace = current
                validationWorkspace.proxyGroupIDs = document.proxyGroups.map(\.id)
                return document.diagnostics(for: validationWorkspace).first {
                    ($0.code == "group_cycle" || $0.code == "empty_group")
                        && $0.subject == String(describing: group.id.rawValue)
                }
            }
            if let cycle {
                errorMessage = cycle.message
                return
            }
            for workspaceIndex in document.workspaces.indices
            where document.workspaces[workspaceIndex].proxyGroupIDs.contains(group.id) {
                document.workspaces[workspaceIndex].revision += 1
            }
        case .rules:
            // The Rules destination owns this flow through
            // UnifiedRoutingRuleEditor. Keep the generic sheet from silently
            // writing a reduced, domain-only representation.
            return
        case .ruleSets:
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                errorMessage = AppLocalization.string("Name is required.")
                return
            }
            let sourceText = ruleSetSourceURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceURL: URL?
            if sourceText.isEmpty {
                sourceURL = nil
            } else {
                guard let parsed = URL(string: sourceText),
                      ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                      parsed.host?.isEmpty == false else {
                    errorMessage = AppLocalization.string("Rule set source must be an HTTP or HTTPS URL.")
                    return
                }
                sourceURL = parsed
            }
            let pathText = ruleSetPathText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pathText.isEmpty,
               !model.isManagedNativeRuleSetCachePath(pathText),
               (pathText.hasPrefix("/") || pathText.contains("..") || pathText.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\\" || $0 == ":" })) {
                errorMessage = AppLocalization.string("Rule set path must be a relative safe path without line breaks or parent-directory segments.")
                return
            }
            let action: RoutingAction = entranceAction.routingAction
            let rules = parseRuleLines(ruleSetRulesText)
            let ruleSet: RuleSet
            if let index = document.ruleSets.firstIndex(where: { $0.id.rawValue == id }) {
                document.ruleSets[index].name = normalized
                document.ruleSets[index].sourceURL = sourceURL
                document.ruleSets[index].path = pathText.isEmpty ? nil : pathText
                document.ruleSets[index].rules = rules
                document.ruleSets[index].defaultAction = action
                document.ruleSets[index].behavior = ruleSetBehavior
                document.ruleSets[index].format = ruleSetFormat
                document.ruleSets[index].enabled = enabled
                document.ruleSets[index].revision += 1
                ruleSet = document.ruleSets[index]
            } else if isNew {
                ruleSet = RuleSet(
                    id: RuleSetID(rawValue: id),
                    name: normalized,
                    sourceURL: sourceURL,
                    rules: rules,
                    defaultAction: action,
                    behavior: ruleSetBehavior,
                    format: ruleSetFormat,
                    path: pathText.isEmpty ? nil : pathText,
                    enabled: enabled
                )
                document.ruleSets.append(ruleSet)
                if let workspaceIndex = currentWorkspaceIndex(in: document),
                   !document.workspaces[workspaceIndex].ruleSetIDs.contains(ruleSet.id) {
                    document.workspaces[workspaceIndex].ruleSetIDs.append(ruleSet.id)
                }
            } else {
                return
            }
            for workspaceIndex in document.workspaces.indices
            where document.workspaces[workspaceIndex].ruleSetIDs.contains(ruleSet.id) {
                document.workspaces[workspaceIndex].revision += 1
            }
        case .workspaces:
            guard let index = document.workspaces.firstIndex(where: { $0.id.rawValue == id }) else { return }
            let normalized = canonicalConfigurationDefaultName(
                name.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard !normalized.isEmpty else { errorMessage = AppLocalization.string("Name is required."); return }
            document.workspaces[index].name = normalized
            document.workspaces[index].routingMode = workspaceRoutingMode
            document.workspaces[index].globalProxyGroupID = workspaceGlobalProxyGroupID
            document.workspaces[index].nodeIDs = Array(selectedNodeIDs).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            let orderedWorkspaceGroups = orderedGroupIDs.filter(selectedGroupIDs.contains)
            let remainingWorkspaceGroups = selectedGroupIDs.subtracting(orderedWorkspaceGroups)
                .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            document.workspaces[index].proxyGroupIDs = orderedWorkspaceGroups + remainingWorkspaceGroups
            if workspaceRoutingMode == .global,
               workspaceGlobalProxyGroupID.map({ !selectedGroupIDs.contains($0) }) ?? true {
                document.workspaces[index].globalProxyGroupID = (orderedWorkspaceGroups + remainingWorkspaceGroups)
                    .first(where: { groupID in
                        document.proxyGroups.contains { $0.id == groupID && $0.enabled }
                    })
            }
            document.workspaces[index].ruleIDs = Array(selectedRuleIDs).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            document.workspaces[index].ruleSetIDs = Array(selectedRuleSetIDs).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            document.workspaces[index].entranceIDs = selectedEntranceIDs
                .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            document.workspaces[index].revision += 1
        case .entrances:
            let existingIndex = document.entrances.firstIndex(where: { $0.id.rawValue == id })
            let persistedEnabled: Bool
            if entranceKind == .tun {
                persistedEnabled = false
            } else if entranceKind == .appRouting {
                appRoutingEnableAfterSave = enabled
                persistedEnabled = existingIndex.map {
                    document.entrances[$0].enabled
                } ?? false
            } else {
                persistedEnabled = enabled
            }
            let normalizedAddress = bindAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedAddress.isEmpty else { errorMessage = AppLocalization.string("Bind address is required."); return }
            let normalizedPort = portText.trimmingCharacters(in: .whitespacesAndNewlines)
            let port: Int? = entranceKind == .appRouting || entranceKind == .tun
                ? nil
                : (normalizedPort.isEmpty ? nil : Int(normalizedPort))
            if (entranceKind == .http || entranceKind == .socks5),
               normalizedPort.isEmpty == false,
               (port == nil || !(1...65_535).contains(port!)) {
                errorMessage = AppLocalization.string("Port must be between 1 and 65535.")
                return
            }
            if enabled, (entranceKind == .http || entranceKind == .socks5), port == nil {
                errorMessage = AppLocalization.string("Enabled HTTP and SOCKS5 entrances require a port.")
                return
            }
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else {
                errorMessage = AppLocalization.string("Entrance name is required.")
                return
            }
            if let port,
               enabled,
               document.entrances.enumerated().contains(where: { offset, entrance in
                   (existingIndex.map { offset != $0 } ?? true)
                       && entrance.enabled
                       && entrance.port == port
               }) {
                errorMessage = AppLocalization.string("Enabled entrances cannot share a listening port.")
                return
            }
            let savedID = EntranceID(rawValue: id)
            if let index = existingIndex {
                document.entrances[index].name = normalizedName
                document.entrances[index].kind = entranceKind
                document.entrances[index].defaultAction = entranceAction.routingAction
                document.entrances[index].bindAddress = normalizedAddress
                document.entrances[index].port = port
                document.entrances[index].enabled = persistedEnabled
            } else if isNew {
                let entrance = Entrance(
                    id: savedID,
                    name: normalizedName,
                    kind: entranceKind,
                    enabled: persistedEnabled,
                    bindAddress: normalizedAddress,
                    port: port,
                    defaultAction: entranceAction.routingAction
                )
                document.entrances.append(entrance)
                if let workspaceIndex = currentWorkspaceIndex(in: document),
                   !document.workspaces[workspaceIndex].entranceIDs.contains(savedID) {
                    document.workspaces[workspaceIndex].entranceIDs.append(savedID)
                }
            } else {
                return
            }
            for workspaceIndex in document.workspaces.indices
            where document.workspaces[workspaceIndex].entranceIDs.contains(savedID) {
                document.workspaces[workspaceIndex].revision += 1
            }
        case .dns:
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                errorMessage = AppLocalization.string("Name is required.")
                return
            }
            let nameservers = parseList(dnsNameserversText)
            let fallbackNameservers = parseList(dnsFallbackNameserversText)
            let proxyServer = dnsProxyServerText.trimmingCharacters(in: .whitespacesAndNewlines)
            let rules = parseList(dnsRulesText)
            let policy: DNSPolicy
            if let index = document.dnsPolicies.firstIndex(where: { $0.id.rawValue == id }) {
                document.dnsPolicies[index].name = normalized
                document.dnsPolicies[index].mode = dnsMode
                document.dnsPolicies[index].nameservers = nameservers
                document.dnsPolicies[index].fallbackNameservers = fallbackNameservers
                document.dnsPolicies[index].proxyServer = proxyServer.isEmpty ? nil : proxyServer
                document.dnsPolicies[index].rules = rules
                document.dnsPolicies[index].takeoverEnabled = dnsTakeoverEnabled
                policy = document.dnsPolicies[index]
            } else if isNew {
                policy = DNSPolicy(
                    id: DNSPolicyID(rawValue: id),
                    name: normalized,
                    mode: dnsMode,
                    nameservers: nameservers,
                    fallbackNameservers: fallbackNameservers,
                    proxyServer: proxyServer.isEmpty ? nil : proxyServer,
                    rules: rules,
                    takeoverEnabled: dnsTakeoverEnabled
                )
                document.dnsPolicies.append(policy)
                if let workspaceIndex = currentWorkspaceIndex(in: document) {
                    document.workspaces[workspaceIndex].dnsPolicyID = policy.id
                }
            } else { return }
            for workspaceIndex in document.workspaces.indices
            where document.workspaces[workspaceIndex].dnsPolicyID == policy.id {
                document.workspaces[workspaceIndex].revision += 1
            }
        case .sources:
            dismiss()
            return
        }
        Task {
            do {
                try await model.saveConfigurationDocument(document)
                if let appRoutingEnableAfterSave {
                    await model.setNetworkCaptureEnabled(appRoutingEnableAfterSave)
                    guard model.appRoutingCapabilityEnabled == appRoutingEnableAfterSave else {
                        errorMessage = model.errorMessage ?? AppLocalization.string(
                            "App Routing did not reach a verified running state."
                        )
                        return
                    }
                }
                onSaved?()
                if !isEmbedded {
                    dismiss()
                }
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

    private func parseList(_ value: String) -> [String] {
        var seen = Set<String>()
        return value
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func parseRuleLines(_ value: String) -> [String] {
        var seen = Set<String>()
        return value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private var entranceKindOptions: [EntranceKind] {
        // Every supported entrance is a first-class configuration object. A
        // capability may still be unavailable on this macOS build, but it is
        // represented and edited as an entrance rather than a global switch.
        [.http, .socks5, .appRouting, .tun]
    }

    private func currentWorkspaceIndex(in document: ConfigurationDocument) -> Int? {
        guard let workspaceID = document.currentWorkspace?.id else { return nil }
        return document.workspaces.firstIndex { $0.id == workspaceID }
    }

    private func moveNestedGroup(from index: Int, by offset: Int) {
        let destination = index + offset
        guard orderedGroupIDs.indices.contains(index), orderedGroupIDs.indices.contains(destination) else { return }
        orderedGroupIDs.swapAt(index, destination)
    }

    private var groupTypeExplanation: String {
        switch groupType {
        case .fallback:
            AppLocalization.string("Fallback checks members from top to bottom and uses the first healthy option. Move members to set priority.")
        case .select:
            AppLocalization.string("Select one member manually. Nested groups keep the order shown.")
        case .urlTest:
            AppLocalization.string("URL Test chooses the member with the best recent health check.")
        case .loadBalance:
            AppLocalization.string("Load Balance distributes new connections across the available members.")
        case .direct:
            AppLocalization.string("Direct always connects without a proxy.")
        case .reject:
            AppLocalization.string("Reject blocks matching traffic.")
        case .relay:
            AppLocalization.string("Relay is not supported by this MClash runtime.")
        }
    }

    private func defaultEntrancePort() -> Int? {
        let usedPorts = Set(model.configurationDocument.entrances.compactMap(\.port))
        return (7890...65535).first { !usedPorts.contains($0) }
    }

    private func uniqueEntranceName(for kind: EntranceKind) -> String {
        let base = kind.localizedTitle
        let existing = Set(model.configurationDocument.entrances.map { $0.name.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        var index = 2
        while existing.contains("\(base) \(index)".lowercased()) {
            index += 1
        }
        return "\(base) \(index)"
    }
}

private enum RuleActionChoice: Hashable, Identifiable {
    case direct, reject, group(ProxyGroupID)
    var id: String { switch self { case .direct: "direct"; case .reject: "reject"; case let .group(id): "group-\(id.rawValue.uuidString)" } }
    var routingAction: RoutingAction { switch self { case .direct: .direct; case .reject: .reject; case let .group(id): .proxyGroup(id) } }
}
