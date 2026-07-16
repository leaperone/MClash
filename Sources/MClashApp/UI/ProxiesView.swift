import Foundation
import SwiftUI

struct ProxiesView: View {
    @Bindable var model: AppModel
    private let stateScope: String
    @SceneStorage private var selectedGroupName: String?
    @SceneStorage private var focusedNodeName: String?
    @SceneStorage private var workspaceMode: ProxyWorkspaceMode
    @State private var sortModesByGroup: [String: ProxyNodeSortMode] = [:]
    @State private var searchTextByGroup: [String: String] = [:]
    @SceneStorage private var serializedSearchTextByGroup: String
    @State private var hasRestoredSearchState = false
    @SceneStorage private var inspectorPresented: Bool
    @State private var groupNavigatorPresented = false
    @State private var workspaceLayout: ProxyWorkspaceLayout = .compact
    @State private var inspectorPresentation: ProxyInspectorPresentation = .popover
    @State private var workspaceLayoutIsResolved = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel) {
        self.model = model
        let stateScope = model.activeProfileID?.description ?? "runtime"
        self.stateScope = stateScope
        _selectedGroupName = SceneStorage("mclash.proxies.\(stateScope).selectedGroup")
        _focusedNodeName = SceneStorage("mclash.proxies.\(stateScope).focusedNode")
        _workspaceMode = SceneStorage(
            wrappedValue: .list,
            "mclash.proxies.\(stateScope).workspaceMode"
        )
        _serializedSearchTextByGroup = SceneStorage(
            wrappedValue: "",
            "mclash.proxies.\(stateScope).searches"
        )
        _inspectorPresented = SceneStorage(
            wrappedValue: false,
            "mclash.proxies.\(stateScope).inspectorPresented"
        )
    }

    var body: some View {
        let groups = ProxyGroupPartitionSnapshot(model: model, routingMode: routingMode)

        Group {
            if !model.isConnected {
                ContentUnavailableView(
                    "Connect to view proxies",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Proxy groups are read from the active Alpha core at runtime.")
                )
            } else if model.controllerState == .loading || model.controllerState == .idle {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting local HTTP and SOCKS5 listeners…")
                        .foregroundStyle(.secondary)
                }
            } else if case let .degraded(message) = model.controllerState {
                ContentUnavailableView {
                    Label("Proxy controls unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Reconnect") { Task { await model.restartConnection() } }
                    Button("View Logs") { model.selection = .logs }
                }
            } else if routingMode == "direct" {
                ContentUnavailableView(
                    "Direct routing is active",
                    systemImage: "arrow.right",
                    description: Text(
                        "Connections bypass proxy groups until Rule or Global mode is selected."
                    )
                )
            } else if groups.available.isEmpty {
                ContentUnavailableView(
                    "No selectable groups",
                    systemImage: "tray",
                    description: Text(
                        routingMode == "global"
                            ? "The active core did not expose the GLOBAL group."
                            : "The active configuration did not expose a selectable proxy group."
                    )
                )
            } else {
                proxyWorkspace(groups: groups)
            }
        }
        .navigationTitle("Proxies")
        .mclashPageSurface()
        .searchable(text: searchBinding, prompt: "Search nodes in the current group")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.controllerIsReady,
               model.localHTTPProxyAddress != nil || model.localSOCKSProxyAddress != nil {
                HStack(spacing: 14) {
                    if workspaceLayout == .compact {
                        compactEndpointLabel
                    } else {
                        localEndpointLabels
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
        .onAppear {
            restoreSearchStateIfNeeded()
            normalizeSelection(groups: groups)
        }
        .onChange(of: searchTextByGroup) { _, searches in
            persistSearchState(searches)
        }
        .onChange(of: model.proxyTopology.groupOrder) { _, _ in
            normalizeSelection(groups: groups)
        }
        .onChange(of: model.runtimeConfig?.mode) { _, _ in
            normalizeSelection(groups: groups)
        }
        .onChange(of: selectedGroupName) { _, name in
            guard let name, let group = model.proxiesByName[name] else { return }
            focusedNodeName = group.now ?? group.all.first
        }
        .toolbar {
            if model.controllerIsReady,
               workspaceLayout == .split || routingMode == "direct" || groups.available.isEmpty {
                ToolbarItemGroup {
                    routingModePicker(width: 190)
                    systemProxyToggle
                }
            }

            if model.controllerIsReady,
               routingMode != "direct",
                let group = selectedGroup(in: groups) {
                ToolbarItemGroup {
                    if inspectorPresentation == .popover {
                        compactProxyActions(group: group)
                    } else {
                        workspacePicker(width: 154)
                        if workspaceMode == .list {
                            sortPicker(group: group, width: 108)
                        }
                        testAllButton(group: group, compact: true)
                    }
                    inspectorButton(group: group)
                }
            }
        }
    }

    private func proxyWorkspace(groups: ProxyGroupPartitionSnapshot) -> some View {
        VStack(spacing: 0) {
            if workspaceLayout == .compact {
                compactRoutingControls
                Divider()
            }

            ProxyDataWarningBanner(model: model)
            Divider()

            if workspaceLayout == .compact {
                VStack(spacing: 0) {
                    compactGroupPicker(groups: groups)
                    Divider()
                    groupDetail(groups: groups)
                }
            } else {
                HSplitView {
                    groupSidebar(groups: groups)
                        .frame(minWidth: 190, idealWidth: 220, maxWidth: 270)

                    groupDetail(groups: groups)
                        .frame(minWidth: 420, maxWidth: .infinity)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { updateWorkspaceLayout(geometry.size.width) }
                    .onChange(of: geometry.size.width) { _, width in
                        updateWorkspaceLayout(width)
                    }
            }
        }
        .inspector(isPresented: attachedInspectorBinding) {
            ProxyInspectorView(
                model: model,
                group: selectedGroup(in: groups),
                focusedNodeName: focusedNodeName,
                openGroup: openGroup
            )
            .inspectorColumnWidth(min: 220, ideal: 280, max: 340)
        }
    }

    private func routingModePicker(width: CGFloat) -> some View {
        Picker("Routing mode", selection: modeBinding) {
            Text("Rule").tag("rule")
            Text("Global").tag("global")
            Text("Direct").tag("direct")
        }
        .pickerStyle(.segmented)
        .frame(width: width)
        .disabled(!model.canPerform(.changeMode))
    }

    private var compactRoutingControls: some View {
        HStack(spacing: 12) {
            routingModePicker(width: 210)
            Spacer(minLength: 8)
            systemProxyToggle
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var systemProxyToggle: some View {
        Toggle("System Proxy", isOn: systemProxyBinding)
            .toggleStyle(.switch)
            .disabled(!model.controllerIsReady || !model.canPerform(.changeSystemProxy))
    }

    private var localEndpointLabels: some View {
        HStack(spacing: 14) {
            if let http = model.localHTTPProxyAddress {
                Label("HTTP \(http)", systemImage: "globe")
            }
            if let socks = model.localSOCKSProxyAddress {
                Label("SOCKS5 \(socks)", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var compactEndpointLabel: some View {
        Label(compactEndpointTitle, systemImage: "network")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(endpointHelp)
    }

    private var compactEndpointTitle: String {
        switch (model.localHTTPProxyAddress, model.localSOCKSProxyAddress) {
        case (.some, .some): "HTTP and SOCKS5 listeners ready"
        case (.some, .none): "HTTP listener ready"
        case (.none, .some): "SOCKS5 listener ready"
        case (.none, .none): "Local listeners unavailable"
        }
    }

    private var endpointHelp: String {
        [
            model.localHTTPProxyAddress.map { "HTTP \($0)" },
            model.localSOCKSProxyAddress.map { "SOCKS5 \($0)" },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    @ViewBuilder
    private func inspectorButton(group: MihomoProxy) -> some View {
        if inspectorPresentation == .popover {
            Button {
                inspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(inspectorPresented ? "Hide Inspector" : "Show Inspector")
            .popover(isPresented: $inspectorPresented, arrowEdge: .top) {
                ProxyInspectorView(
                    model: model,
                    group: group,
                    focusedNodeName: focusedNodeName,
                    openGroup: openGroup
                )
                .frame(width: 360, height: 480)
            }
        } else {
            Button {
                inspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(inspectorPresented ? "Hide Inspector" : "Show Inspector")
        }
    }

    private var attachedInspectorBinding: Binding<Bool> {
        Binding(
            get: { inspectorPresented && inspectorPresentation == .attached },
            set: { inspectorPresented = $0 }
        )
    }

    private func groupSidebar(groups: ProxyGroupPartitionSnapshot) -> some View {
        List(selection: $selectedGroupName) {
            groupSections(groups: groups)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contentMargins(.vertical, 8, for: .scrollContent)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityLabel("Proxy groups with nested groups first")
    }

    private func compactGroupPicker(groups: ProxyGroupPartitionSnapshot) -> some View {
        let current = selectedGroup(in: groups)

        return Button {
            groupNavigatorPresented.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(current?.name ?? "Choose a group")
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let current {
                        Text(groupBehaviorTitle(current))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let current {
                    Text(formattedCount(current.all.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.bar)
        .help(current?.name ?? "Choose a proxy group")
        .popover(isPresented: $groupNavigatorPresented, arrowEdge: .bottom) {
            List(selection: compactGroupSelectionBinding) {
                groupSections(groups: groups)
            }
            .listStyle(.sidebar)
            .frame(width: 320, height: 430)
            .accessibilityLabel("Choose a proxy group")
        }
    }

    @ViewBuilder
    private func groupSections(groups: ProxyGroupPartitionSnapshot) -> some View {
        if !groups.nested.isEmpty {
            Section("Nested Groups") {
                ForEach(groups.nested, id: \.name) { group in
                    ProxyGroupSidebarRow(
                        group: group,
                        path: model.proxySelectionPaths[group.name]
                    )
                    .tag(group.name)
                }
            }
        }

        if !groups.roots.isEmpty {
            Section("Entry Groups") {
                ForEach(groups.roots, id: \.name) { group in
                    ProxyGroupSidebarRow(
                        group: group,
                        path: model.proxySelectionPaths[group.name]
                    )
                    .tag(group.name)
                }
            }
        }

        if !groups.special.isEmpty {
            Section("Special Groups") {
                ForEach(groups.special, id: \.name) { group in
                    ProxyGroupSidebarRow(
                        group: group,
                        path: model.proxySelectionPaths[group.name]
                    )
                    .tag(group.name)
                }
            }
        }
    }

    private var compactGroupSelectionBinding: Binding<String?> {
        Binding(
            get: { selectedGroupName },
            set: { selection in
                selectedGroupName = selection
                groupNavigatorPresented = false
            }
        )
    }

    @ViewBuilder
    private func groupDetail(groups: ProxyGroupPartitionSnapshot) -> some View {
        if let group = selectedGroup(in: groups) {
            VStack(spacing: 0) {
                groupHeader(group)

                if let fixed = group.fixedOverride,
                   group.groupBehavior?.supportsClearingOverride == true {
                    automaticOverrideBanner(group: group, fixed: fixed)
                }

                Divider()

                switch workspaceMode {
                case .list:
                    proxyNodeList(group)
                        .transition(.opacity)
                case .topology:
                    ProxyTopologyCanvas(
                        topology: model.proxyTopology,
                        rootGroup: group.name,
                        selectedPath: model.proxySelectionPaths[group.name],
                        delays: model.proxyDelayMap(for: group.name),
                        stateScope: stateScope,
                        focusedNodeName: $focusedNodeName,
                        openGroup: openGroup,
                        showGroupList: { name in
                            openGroup(name)
                            workspaceMode = .list
                        }
                    )
                    .transition(.opacity)
                }
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.18),
                value: workspaceMode
            )
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            ContentUnavailableView(
                "Choose a proxy group",
                systemImage: "sidebar.left",
                description: Text("Select a group to inspect its route and nodes.")
            )
        }
    }

    private func groupHeader(_ group: MihomoProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            groupTitle(group, stacked: true)

            if let path = model.proxySelectionPaths[group.name] {
                ProxyPathStrip(path: path)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func groupTitle(_ group: MihomoProxy, stacked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if stacked {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(groupBehaviorTitle(group))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 7) {
                    Text(group.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(groupBehaviorTitle(group))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text(groupStatusText(group))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func workspacePicker(width: CGFloat) -> some View {
        Picker("View", selection: $workspaceMode) {
            Label("List", systemImage: "list.bullet").tag(ProxyWorkspaceMode.list)
            Label("Topology", systemImage: "point.3.connected.trianglepath.dotted")
                .tag(ProxyWorkspaceMode.topology)
        }
        .pickerStyle(.segmented)
        .frame(width: width)
    }

    private func sortPicker(group: MihomoProxy, width: CGFloat) -> some View {
        Picker("Node order", selection: sortBinding(for: group.name)) {
            ForEach(ProxyNodeSortMode.allCases, id: \.rawValue) { mode in
                Label(mode.title, systemImage: mode.symbol).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .frame(width: width)
    }

    private func testAllButton(group: MihomoProxy, compact: Bool) -> some View {
        Button {
            Task { await model.measureGroupDelays(group: group.name) }
        } label: {
            if model.isPerforming(.measureGroupDelay(group.name)) {
                ProgressView()
                    .controlSize(.small)
            } else if compact {
                Image(systemName: "speedometer")
            } else {
                Label("Test All", systemImage: "speedometer")
            }
        }
        .disabled(!model.canPerform(.measureGroupDelay(group.name)))
        .help("Test every member in \(group.name)")
    }

    private func compactProxyActions(group: MihomoProxy) -> some View {
        Menu {
            Picker("View", selection: $workspaceMode) {
                Label("List", systemImage: "list.bullet").tag(ProxyWorkspaceMode.list)
                Label("Topology", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(ProxyWorkspaceMode.topology)
            }

            if workspaceMode == .list {
                Picker("Node Order", selection: sortBinding(for: group.name)) {
                    ForEach(ProxyNodeSortMode.allCases, id: \.rawValue) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
            }

            Divider()

            Button("Test All", systemImage: "speedometer") {
                Task { await model.measureGroupDelays(group: group.name) }
            }
            .disabled(!model.canPerform(.measureGroupDelay(group.name)))
        } label: {
            Label("Proxy View Actions", systemImage: "ellipsis.circle")
        }
        .help("Change proxy view, sorting, or test every node")
    }

    private func automaticOverrideBanner(group: MihomoProxy, fixed: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            automaticOverrideMessage(fixed: fixed)
            Button("Resume Automatic") {
                Task { _ = await model.clearProxyOverride(group: group.name) }
            }
            .disabled(!model.canPerform(.clearProxyOverride(group.name)))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.09))
        .accessibilityElement(children: .contain)
    }

    private func automaticOverrideMessage(fixed: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "pin.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Automatic selection is pinned")
                    .font(.callout.weight(.medium))
                Text("Preferred node: \(fixed). The active node still follows mihomo health checks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func proxyNodeList(_ group: MihomoProxy) -> some View {
        let nodeNames = displayedNodeNames(in: group)

        if nodeNames.isEmpty {
            ContentUnavailableView.search(text: searchText(for: group.name))
        } else {
            ProxyNodeListContent(
                model: model,
                group: group,
                nodeNames: nodeNames,
                focusedNodeName: $focusedNodeName,
                openGroup: openGroup
            )
        }
    }

    private func selectedGroup(in groups: ProxyGroupPartitionSnapshot) -> MihomoProxy? {
        guard let selectedGroupName else { return groups.available.first }
        return model.proxiesByName[selectedGroupName] ?? groups.available.first
    }

    private var routingMode: String {
        model.runtimeConfig?.mode.lowercased() ?? "rule"
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { routingMode },
            set: { mode in Task { await model.setMode(mode) } }
        )
    }

    private var systemProxyBinding: Binding<Bool> {
        Binding(
            get: { model.systemProxyEnabled },
            set: { enabled in Task { await model.setSystemProxyEnabled(enabled) } }
        )
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { searchText(for: selectedGroupName ?? routingMode) },
            set: { searchTextByGroup[selectedGroupName ?? routingMode] = $0 }
        )
    }

    private func sortBinding(for group: String) -> Binding<ProxyNodeSortMode> {
        Binding(
            get: { sortModesByGroup[group] ?? persistedSortMode(for: group) },
            set: { mode in
                sortModesByGroup[group] = mode
                UserDefaults.standard.set(mode.rawValue, forKey: sortPreferenceKey(for: group))
            }
        )
    }

    private func displayedNodeNames(in group: MihomoProxy) -> [String] {
        let query = searchText(for: group.name).trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? group.all
            : group.all.filter { name in
                if name.localizedCaseInsensitiveContains(query) { return true }
                guard let proxy = model.proxiesByName[name] else { return false }
                return proxy.type.localizedCaseInsensitiveContains(query)
                    || proxy.providerName?.localizedCaseInsensitiveContains(query) == true
            }

        let mode = sortModesByGroup[group.name] ?? persistedSortMode(for: group.name)
        if mode == .profile { return filtered }

        return ProxyNodeSorter().sortedNodeNames(
            filtered,
            in: group.name,
            topology: model.proxyTopology,
            delays: mode == .latency ? model.proxyDelayMap(for: group.name) : [:],
            mode: mode
        )
    }

    private func searchText(for group: String) -> String {
        searchTextByGroup[group] ?? ""
    }

    private func restoreSearchStateIfNeeded() {
        guard !hasRestoredSearchState else { return }
        hasRestoredSearchState = true
        guard !serializedSearchTextByGroup.isEmpty,
              let data = serializedSearchTextByGroup.data(using: .utf8),
              let searches = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        searchTextByGroup = searches.filter { !$0.value.isEmpty }
    }

    private func persistSearchState(_ searches: [String: String]) {
        guard hasRestoredSearchState else { return }
        let nonemptySearches = searches.filter { !$0.value.isEmpty }
        guard !nonemptySearches.isEmpty else {
            serializedSearchTextByGroup = ""
            return
        }
        guard let data = try? JSONEncoder().encode(nonemptySearches),
              let encoded = String(data: data, encoding: .utf8) else {
            return
        }
        serializedSearchTextByGroup = encoded
    }

    private func persistedSortMode(for group: String) -> ProxyNodeSortMode {
        guard let rawValue = UserDefaults.standard.string(forKey: sortPreferenceKey(for: group)),
              let mode = ProxyNodeSortMode(rawValue: rawValue) else {
            return .profile
        }
        return mode
    }

    private func sortPreferenceKey(for group: String) -> String {
        let profile = model.activeProfileID?.description ?? "runtime"
        return "proxies.sort.\(profile).\(group)"
    }

    private func normalizeSelection(groups: ProxyGroupPartitionSnapshot) {
        if routingMode == "direct" {
            return
        }

        guard !groups.available.isEmpty else { return }

        if let selectedGroupName,
           let selectedGroup = groups.available.first(where: { $0.name == selectedGroupName }) {
            if focusedNodeName.map({ selectedGroup.all.contains($0) }) != true
                || focusedNodeName.flatMap({ model.proxiesByName[$0] }) == nil {
                focusedNodeName = selectedGroup.now ?? selectedGroup.all.first
            }
            return
        }

        let defaultGroup = groups.nested.first
            ?? groups.roots.first
            ?? groups.special.first
            ?? groups.available.first
        selectedGroupName = defaultGroup?.name
        focusedNodeName = defaultGroup?.now ?? defaultGroup?.all.first
    }

    private func openGroup(_ name: String) {
        guard model.proxyTopology.vertices[name]?.isGroup == true else { return }
        selectedGroupName = name
        focusedNodeName = model.proxiesByName[name]?.now
    }

    private func updateWorkspaceLayout(_ width: CGFloat) {
        guard width > 0 else { return }

        let next = ProxyWorkspaceLayout(width: width)
        let nextInspectorPresentation = ProxyInspectorPresentation(width: width)
        if !workspaceLayoutIsResolved {
            workspaceLayout = next
            inspectorPresentation = nextInspectorPresentation
            workspaceLayoutIsResolved = true
            return
        }

        if workspaceLayout != next || inspectorPresentation != nextInspectorPresentation {
            let presentationChanged = inspectorPresentation != nextInspectorPresentation
            workspaceLayout = next
            inspectorPresentation = nextInspectorPresentation
            if inspectorPresented, presentationChanged {
                inspectorPresented = false
            }
        }
    }

    private func groupBehaviorTitle(_ group: MihomoProxy) -> String {
        switch group.groupBehavior {
        case .selector: "Manual Selector"
        case .urlTest: "Automatic URL Test"
        case .fallback: "Automatic Fallback"
        case .loadBalance: "Per-Connection Load Balance"
        case nil: group.type
        }
    }

    private func groupStatusText(_ group: MihomoProxy) -> String {
        if group.groupBehavior == .loadBalance {
            return "The final node is selected independently for each connection."
        }
        if group.fixedOverride != nil {
            return "Pinned preference · active \(group.now ?? "not available")"
        }
        switch group.groupBehavior {
        case .urlTest, .fallback:
            return "Current automatic choice: \(group.now ?? "not available")"
        default:
            return group.now.map { "Using \($0)" } ?? "Choose a proxy node"
        }
    }

}

private enum ProxyWorkspaceLayout: Equatable {
    case compact
    case split

    init(width: CGFloat) {
        self = width < 860 ? .compact : .split
    }
}

private enum ProxyInspectorPresentation: Equatable {
    case popover
    case attached

    init(width: CGFloat) {
        self = width < 940 ? .popover : .attached
    }
}

private enum ProxyWorkspaceMode: String, CaseIterable, Identifiable {
    case list
    case topology

    var id: Self { self }
}

private struct ProxyGroupPartitionSnapshot {
    let available: [MihomoProxy]
    let roots: [MihomoProxy]
    let nested: [MihomoProxy]
    let special: [MihomoProxy]

    @MainActor
    init(model: AppModel, routingMode: String) {
        let available = model.proxyGroups(forRoutingMode: routingMode)
        self.available = available

        if routingMode == "global" {
            roots = available
            nested = []
            special = []
            return
        }

        var nestedNames = Set<String>()
        for edge in model.proxyTopology.edges
        where edge.kind == .member
            && edge.source != "GLOBAL"
            && model.proxyTopology.vertices[edge.source]?.isGroup == true {
            nestedNames.insert(edge.target)
        }

        roots = available.filter { group in
            group.name != "GLOBAL" && !nestedNames.contains(group.name)
        }
        nested = available.filter { group in
            group.name != "GLOBAL" && nestedNames.contains(group.name)
        }
        special = routingMode == "rule"
            ? available.filter { $0.name == "GLOBAL" }
            : []
    }
}

private struct ProxyDataWarningBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        let messages = warningMessages

        if !messages.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(messages, id: \.self) { message in
                        Text(message)
                            .font(.callout)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var warningMessages: [String] {
        guard model.errorMessage == nil else { return [] }
        var messages: [String] = []
        if model.degradedStreams.contains(.proxies) {
            messages.append("Proxy choices may be stale while MClash reconnects to the Alpha API.")
        }
        if model.degradedStreams.contains(.connections) {
            messages.append("Connection counts and observed route traffic are temporarily stale.")
        }
        return messages
    }
}

private struct ProxyGroupSidebarRow: View {
    let group: MihomoProxy
    let path: ProxySelectionPath?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .foregroundStyle(
                        group.alive ? Color(nsColor: .secondaryLabelColor) : Color.red
                    )
                    .frame(width: 15)
                    .accessibilityHidden(true)
                Text(group.name)
                    .lineLimit(1)
                    .help(group.name)
                Spacer(minLength: 4)
                if group.fixedOverride != nil {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Pinned automatic selection")
                }
                Text(formattedCount(group.all.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(routeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 22)
                .help(routeSummary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(group.name), \(group.type), \(group.alive ? "available" : "unavailable"), "
                + "\(formattedCount(group.all.count)) members, \(routeSummary)"
        )
    }

    private var symbol: String {
        switch group.groupBehavior {
        case .selector: "slider.horizontal.3"
        case .urlTest: "speedometer"
        case .fallback: "arrow.triangle.branch"
        case .loadBalance: "scale.3d"
        case nil: "point.3.connected.trianglepath.dotted"
        }
    }

    private var routeSummary: String {
        let summary: String
        if let path, case .loadBalance = path.issue {
            summary = "Per-connection route"
        } else if let path, let terminal = path.terminal {
            summary = path.route.count > 2 ? "… → \(terminal)" : terminal
        } else {
            summary = group.now ?? "Route unavailable"
        }
        return group.alive ? summary : "Unavailable · \(summary)"
    }
}

private struct ProxyNodeListContent: View {
    @Bindable var model: AppModel
    let group: MihomoProxy
    let nodeNames: [String]
    @Binding var focusedNodeName: String?
    let openGroup: (String) -> Void

    var body: some View {
        List(nodeNames, id: \.self, selection: $focusedNodeName) { nodeName in
            ProxyNodeListRow(
                node: model.proxiesByName[nodeName],
                nodeName: nodeName,
                isSelected: group.now == nodeName,
                isFixed: group.fixedOverride == nodeName,
                isAlive: model.proxyAlive(for: nodeName, in: group.name),
                delay: model.proxyDelay(for: nodeName, in: group.name),
                supportsSelection: group.groupBehavior?.supportsSelectionUpdate == true,
                canSelect: model.canPerform(.selectProxy(group.name)),
                selectionInProgress: model.isPerforming(.selectProxy(group.name)),
                onSelect: {
                    focusedNodeName = nodeName
                    Task {
                        _ = await model.selectProxy(group: group.name, proxy: nodeName)
                    }
                },
                onOpenGroup: model.proxyTopology.vertices[nodeName]?.isGroup == true
                    ? { openGroup(nodeName) }
                    : nil,
                onTest: {
                    Task {
                        _ = await model.measureDelay(proxy: nodeName, group: group.name)
                    }
                }
            )
            .tag(nodeName)
        }
        .listStyle(.inset)
        .mclashListSurface(horizontalMargin: 14, verticalMargin: 10)
        .accessibilityLabel("Nodes in \(group.name)")
    }
}

private struct ProxyNodeListRow: View {
    let node: MihomoProxy?
    let nodeName: String
    let isSelected: Bool
    let isFixed: Bool
    let isAlive: Bool?
    let delay: Int?
    let supportsSelection: Bool
    let canSelect: Bool
    let selectionInProgress: Bool
    let onSelect: () -> Void
    let onOpenGroup: (() -> Void)?
    let onTest: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            selectionButton
            nodeInformation
                .layoutPriority(1)
            delayIndicator
            openGroupButton
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contextMenu {
            if supportsSelection {
                Button(isSelected ? "Current Route" : "Use Node", action: onSelect)
                    .disabled(!canSelect || selectionInProgress || isSelected)
            }
            Button("Test Latency", action: onTest)
            if let onOpenGroup {
                Button("Open Group", action: onOpenGroup)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var selectionButton: some View {
        Button(action: onSelect) {
            if selectionInProgress, isSelected {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: selectionSymbol)
                    .foregroundStyle(selectionColor)
                    .frame(width: 18, height: 18)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .disabled(!supportsSelection || !canSelect || selectionInProgress)
        .help(selectionHelp)
        .accessibilityLabel(selectionHelp)
    }

    private var nodeInformation: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(nodeName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if isFixed {
                    Label("Pinned", systemImage: "pin.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.orange)
                        .help("Pinned automatic preference")
                }
            }

            HStack(spacing: 8) {
                Text(node?.type ?? "Unresolved")
                Text(statusText)
                if node?.udp == true { Text("UDP") }
                if node?.tcpFastOpen == true { Text("TFO") }
                if let provider = normalized(node?.providerName) { Text(provider) }
            }
            .font(.caption)
            .foregroundStyle(isAlive == false ? Color.red : Color.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(nodeName)
        .accessibilityLabel("\(nodeName), \(statusText), \(delayText)")
    }

    private var delayIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(delayText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(delayColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 68, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var openGroupButton: some View {
        if let onOpenGroup {
            Button(action: onOpenGroup) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .help("Open nested group \(nodeName)")
            .accessibilityLabel("Open nested group \(nodeName)")
        }
    }

    private var selectionSymbol: String {
        if isFixed { return "pin.circle.fill" }
        return isSelected ? "checkmark.circle.fill" : "circle"
    }

    private var selectionColor: Color {
        if isFixed { return .orange }
        return isSelected ? .accentColor : .secondary
    }

    private var selectionHelp: String {
        if !supportsSelection { return "This group does not support manual node selection" }
        if !canSelect { return "Proxy selection is temporarily unavailable" }
        if isFixed { return "Pinned automatic preference" }
        return isSelected ? "Currently selected" : "Select \(nodeName)"
    }

    private var statusText: String {
        if node == nil { return "Missing" }
        if isAlive == false { return "Unavailable" }
        if delay != nil || node?.history.isEmpty == false { return "Available" }
        return "Not tested"
    }

    private var statusColor: Color {
        if isAlive == false { return .red }
        if delay != nil || node?.history.isEmpty == false { return .green }
        return Color(nsColor: .tertiaryLabelColor)
    }

    private var delayText: String {
        delay.map { "\($0) ms" } ?? "Not tested"
    }

    private var delayColor: Color {
        guard let delay else { return .secondary }
        if delay < 150 { return .green }
        if delay < 350 { return .orange }
        return .red
    }
}

struct ProxyPathStrip: View {
    let path: ProxySelectionPath

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(path.route.enumerated()), id: \.offset) { index, name in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            index == path.route.count - 1
                                ? Color.accentColor.opacity(0.13)
                                : Color(nsColor: .controlBackgroundColor),
                            in: Capsule()
                        )
                }

                if case .loadBalance = path.issue {
                    Label("Per connection", systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel("Current route: \(path.route.joined(separator: ", then "))")
    }
}

private extension ProxyNodeSortMode {
    var title: String {
        switch self {
        case .profile: "Profile"
        case .latency: "Latency"
        case .name: "Name"
        }
    }

    var symbol: String {
        switch self {
        case .profile: "list.bullet"
        case .latency: "speedometer"
        case .name: "textformat"
        }
    }
}

func normalized(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return value
}
