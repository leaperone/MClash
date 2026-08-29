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
    @State private var inspectorPopoverPresented = false
    @State private var groupNavigatorPresented = false
    @State private var measuredWorkspaceWidth: CGFloat = 0
    @State private var inspectorPresentation: ProxyInspectorPresentation = .popover
    @State private var selectedProfileID: ProfileID?
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
        let profileID = resolvedSelectedProfileID
        let workspaceState = profileID.map {
            model.profileProxyWorkspaceState(for: $0)
        }
        let snapshot = workspaceState?.snapshot
        let groups = snapshot.map {
            ProxyGroupPartitionSnapshot(
                snapshot: $0,
                routingMode: $0.runtimeConfig.mode
            )
        } ?? .empty

        Group {
            if model.profileProxyWorkspaceProfiles.isEmpty {
                ContentUnavailableView(
                    "No Profiles",
                    systemImage: "doc.badge.plus",
                    description: Text(
                        "Import a Profile before configuring proxy groups."
                    )
                )
            } else if profileID == nil {
                ContentUnavailableView(
                    "Choose a Profile",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(
                        "Select the Profile whose proxy groups you want to configure."
                    )
                )
            } else if let profileID {
                VStack(spacing: 0) {
                    proxyCommandBar(group: selectedGroup(in: groups))

                    if snapshot == nil,
                       workspaceState?.isLoadingOrIdle == true {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Loading this Profile’s proxy groups…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if snapshot == nil {
                        unavailableProfileWorkspace(
                            profileID: profileID,
                            state: workspaceState
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                    ? AppLocalization.string(
                                        "The active core did not expose the GLOBAL group."
                                    )
                                    : AppLocalization.string(
                                        "The active configuration did not expose a selectable proxy group."
                                    )
                            )
                        )
                    } else {
                        proxyWorkspace(groups: groups)
                    }
                }
            }
        }
        .navigationTitle("Proxies")
        .mclashPageSurface()
        .searchable(text: searchBinding, prompt: "Search nodes in the current group")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let profileID = resolvedSelectedProfileID,
               workspaceSnapshot != nil,
               profileID != model.activeProfileID || selectedProfileMixedPort == nil {
                HStack(spacing: 14) {
                    if let port = selectedProfileMixedPort {
                        CopyableValueButton(
                            value: "127.0.0.1:\(port)",
                            accessibilityName: "Profile Mixed proxy address",
                            title: "Profile Mixed",
                            systemImage: "point.3.connected.trianglepath.dotted",
                            font: .caption,
                            usesSecondaryStyle: true
                        )
                    } else {
                        Label("Profile Mixed port closed", systemImage: "powerplug")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if profileID == model.activeProfileID {
                        Text("Default Source")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(
                        selectedProfileMixedPort == nil
                            ? AppLocalization.string("Open Port")
                            : AppLocalization.string("Close Port")
                    ) {
                        Task {
                            do {
                                try await model.setProfileMixedPortEnabled(
                                    profileID: profileID,
                                    enabled: selectedProfileMixedPort == nil
                                )
                                _ = await model.refreshProxyWorkspace(for: profileID)
                            } catch {
                                model.errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .controlSize(.small)
                    .disabled(!model.canPerform(.updateProfile(profileID)))
                    Button("Manage…") { model.selection = .profiles }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
        .onAppear {
            normalizeSelectedProfile()
            restoreSearchStateIfNeeded()
            normalizeSelection(groups: groups)
        }
        .task(id: profileID) {
            guard let profileID else { return }
            _ = await model.refreshProxyWorkspace(for: profileID)
        }
        .onChange(of: model.profileProxyWorkspaceProfiles.map(\.id)) { _, _ in
            normalizeSelectedProfile()
        }
        .onChange(of: searchTextByGroup) { _, searches in
            persistSearchState(searches)
        }
        .onChange(of: snapshot?.topology.groupOrder) { _, _ in
            normalizeSelection(groups: groups)
        }
        .onChange(of: snapshot?.runtimeConfig.mode) { _, _ in
            normalizeSelection(groups: groups)
        }
        .onChange(of: workspaceMode) { _, _ in
            updateWorkspaceWidth(measuredWorkspaceWidth)
        }
        .onChange(of: inspectorPresentation) { _, presentation in
            if presentation == .attached {
                inspectorPopoverPresented = false
            }
        }
        .onChange(of: selectedGroupName) { _, name in
            guard let name, let group = snapshot?.proxiesByName[name] else { return }
            focusedNodeName = group.now ?? group.all.first
        }
        .onChange(of: profileID) { _, _ in
            selectedGroupName = nil
            focusedNodeName = nil
            inspectorPopoverPresented = false
            inspectorPresented = false
        }
    }

    private func proxyWorkspace(groups: ProxyGroupPartitionSnapshot) -> some View {
        VStack(spacing: 0) {
            if resolvedSelectedProfileID == model.activeProfileID {
                ProxyDataWarningBanner(model: model)
            }
            if resolvedSelectedProfileID == model.activeProfileID,
               !model.degradedStreams.isEmpty {
                Divider()
            }

            Group {
                switch workspaceMode {
                case .list:
                    proxyListWorkspace(groups: groups)
                case .topology:
                    proxyTopologyWorkspace(groups: groups)
                }
            }
            .transition(.opacity)
            .animation(
                .easeOut(duration: reduceMotion ? 0.12 : 0.18),
                value: workspaceMode
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { updateWorkspaceWidth(geometry.size.width) }
                    .onChange(of: geometry.size.width) { _, width in
                        updateWorkspaceWidth(width)
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
            .inspectorColumnWidth(min: 280, ideal: 340, max: 420)
        }
    }

    private func proxyListWorkspace(groups: ProxyGroupPartitionSnapshot) -> some View {
        GeometryReader { geometry in
            let sidebarWidth = ProxyWorkspaceSizing.groupSidebarWidth(
                for: geometry.size.width
            )
            let nodeWidth = ProxyWorkspaceSizing.detailWidth(
                for: geometry.size.width,
                sidebarWidth: sidebarWidth
            )

            HStack(spacing: 0) {
                groupSidebar(groups: groups)
                    .frame(width: sidebarWidth)

                Divider()

                listGroupDetail(groups: groups)
                    .frame(width: nodeWidth)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Proxy groups and nodes")
    }

    @ViewBuilder
    private func proxyTopologyWorkspace(groups: ProxyGroupPartitionSnapshot) -> some View {
        if usesCompactTopologyNavigation {
            VStack(spacing: 0) {
                compactGroupPicker(groups: groups)
                Divider()
                topologyGroupDetail(groups: groups)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            GeometryReader { geometry in
                let sidebarWidth = ProxyWorkspaceSizing.groupSidebarWidth(
                    for: geometry.size.width
                )
                let canvasWidth = ProxyWorkspaceSizing.detailWidth(
                    for: geometry.size.width,
                    sidebarWidth: sidebarWidth
                )

                HStack(spacing: 0) {
                    groupSidebar(groups: groups)
                        .frame(width: sidebarWidth)

                    Divider()

                    topologyGroupDetail(groups: groups)
                        .frame(width: canvasWidth)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private func proxyCommandBar(group: MihomoProxy?) -> some View {
        HStack(spacing: 10) {
            if model.profileProxyWorkspaceProfiles.count > 1 {
                profilePicker(width: usesCompactChrome ? 170 : 220)
            } else {
                Label(
                    model.profileProxyWorkspaceProfiles.first?.name
                        ?? AppLocalization.string("Profile"),
                    systemImage: "doc.text"
                )
                .font(.callout.weight(.medium))
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let group {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(group.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(groupStatusText(group))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            proxyOptionsMenu(group: group)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private func proxyOptionsMenu(group: MihomoProxy?) -> some View {
        Menu {
            Picker("Routing Mode", selection: modeBinding) {
                Text("Rule").tag("rule")
                Text("Global").tag("global")
                Text("Direct").tag("direct")
            }
            .disabled(
                workspaceSnapshot == nil
                    || (resolvedSelectedProfileID.map {
                        !model.canPerform(.changeProfileMode($0))
                    } ?? true)
            )

            Toggle("macOS System Proxy", isOn: systemProxyBinding)
                .disabled(!model.controllerIsReady || !model.canPerform(.changeSystemProxy))

            Divider()

            Picker("View", selection: $workspaceMode) {
                Label("List", systemImage: "list.bullet").tag(ProxyWorkspaceMode.list)
                Label("Topology", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(ProxyWorkspaceMode.topology)
            }

            if let group, workspaceMode == .list {
                Picker("Node Order", selection: sortBinding(for: group.name)) {
                    ForEach(ProxyNodeSortMode.allCases, id: \.rawValue) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }

                Button {
                    guard let profileID = resolvedSelectedProfileID else { return }
                    Task {
                        await model.measureGroupDelays(
                            profileID: profileID,
                            group: group.name
                        )
                    }
                } label: {
                    Label("Test Latencies", systemImage: "speedometer")
                }
                .disabled(
                    resolvedSelectedProfileID.map {
                        !model.canPerform(.measureProfileGroupDelay($0, group.name))
                    } ?? true
                )
            }

            if group != nil, resolvedSelectedProfileID == model.activeProfileID {
                Button {
                    if inspectorPresentation == .popover {
                        inspectorPopoverPresented.toggle()
                    } else {
                        inspectorPresented.toggle()
                    }
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
            }

            Divider()
            Button("Manage Profile…") { model.selection = .profiles }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .help("Proxy view and routing options")
        .popover(isPresented: $inspectorPopoverPresented, arrowEdge: .top) {
            if let group {
                ProxyInspectorView(
                    model: model,
                    group: group,
                    focusedNodeName: focusedNodeName,
                    openGroup: openGroup
                )
                .frame(width: 360, height: 480)
            }
        }
    }

    private func profilePicker(width: CGFloat) -> some View {
        Picker("Profile", selection: selectedProfileBinding) {
            ForEach(model.profileProxyWorkspaceProfiles) { profile in
                Text(
                    profile.id == model.activeProfileID
                        ? AppLocalization.format("%@ — Default Source", profile.name)
                        : profile.name
                )
                .tag(profile.id)
            }
        }
        .labelsHidden()
        .frame(width: width)
        .help("Choose the Profile whose proxy groups you want to configure")
    }

    private var attachedInspectorBinding: Binding<Bool> {
        Binding(
            get: {
                inspectorPresented
                    && inspectorPresentation == .attached
                    && resolvedSelectedProfileID == model.activeProfileID
            },
            set: { presented in
                guard inspectorPresentation == .attached else { return }
                inspectorPresented = presented
            }
        )
    }

    private func groupSidebar(groups: ProxyGroupPartitionSnapshot) -> some View {
        List(selection: $selectedGroupName) {
            groupSections(groups: groups)
        }
        .listStyle(.sidebar)
        .contentMargins(.vertical, 8, for: .scrollContent)
        .accessibilityLabel("Proxy groups in routing presentation order")
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
                    Text(current?.name ?? AppLocalization.string("Choose a group"))
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
        .help(current?.name ?? AppLocalization.string("Choose a proxy group"))
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
                        path: workspaceSnapshot?.selectionPaths[group.name]
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
                        path: workspaceSnapshot?.selectionPaths[group.name]
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
                        path: workspaceSnapshot?.selectionPaths[group.name]
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
    private func listGroupDetail(groups: ProxyGroupPartitionSnapshot) -> some View {
        if let group = selectedGroup(in: groups) {
            VStack(spacing: 0) {
                groupDetailHeader(group)
                proxyNodeList(group)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            ContentUnavailableView(
                "Choose a proxy group",
                systemImage: "sidebar.left",
                description: Text("Select a group to inspect its route and nodes.")
            )
        }
    }

    @ViewBuilder
    private func topologyGroupDetail(groups: ProxyGroupPartitionSnapshot) -> some View {
        if let group = selectedGroup(in: groups) {
            VStack(spacing: 0) {
                groupDetailHeader(group)
                ProxyTopologyCanvas(
                    topology: workspaceSnapshot?.topology ?? .empty,
                    rootGroup: group.name,
                    selectedPath: workspaceSnapshot?.selectionPaths[group.name],
                    delays: workspaceSnapshot?.delays ?? [:],
                    stateScope: selectedProfileStateScope,
                    focusedNodeName: $focusedNodeName,
                    openGroup: openGroup,
                    showGroupList: { name in
                        openGroup(name)
                        workspaceMode = .list
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            ContentUnavailableView(
                "Choose a proxy group",
                systemImage: "sidebar.left",
                description: Text("Select a group to inspect its route topology.")
            )
        }
    }

    @ViewBuilder
    private func groupDetailHeader(_ group: MihomoProxy) -> some View {
        groupHeader(group)

        if let fixed = group.fixedOverride,
           group.groupBehavior?.supportsClearingOverride == true {
            automaticOverrideBanner(group: group, fixed: fixed)
        }

        Divider()
    }

    private func groupHeader(_ group: MihomoProxy) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            groupTitle(group, stacked: true)

            if let path = workspaceSnapshot?.selectionPaths[group.name] {
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

    private func automaticOverrideBanner(group: MihomoProxy, fixed: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            automaticOverrideMessage(fixed: fixed)
            Button("Resume Automatic") {
                guard let profileID = resolvedSelectedProfileID else { return }
                Task {
                    _ = await model.clearProxyOverride(
                        profileID: profileID,
                        group: group.name
                    )
                }
            }
            .disabled(
                resolvedSelectedProfileID.map {
                    !model.canPerform(
                        .clearProfileProxyOverride($0, group.name)
                    )
                } ?? true
            )
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
        } else if let profileID = resolvedSelectedProfileID,
                  let snapshot = workspaceSnapshot {
            ProxyNodeListContent(
                model: model,
                profileID: profileID,
                snapshot: snapshot,
                group: group,
                nodeNames: nodeNames,
                focusedNodeName: $focusedNodeName,
                openGroup: openGroup
            )
        }
    }

    private func selectedGroup(in groups: ProxyGroupPartitionSnapshot) -> MihomoProxy? {
        guard let selectedGroupName else { return groups.available.first }
        return workspaceSnapshot?.proxiesByName[selectedGroupName]
            ?? groups.available.first
    }

    private var routingMode: String {
        workspaceSnapshot?.runtimeConfig.mode.lowercased() ?? "rule"
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { routingMode },
            set: { mode in
                guard let profileID = resolvedSelectedProfileID else { return }
                Task { await model.setMode(mode, profileID: profileID) }
            }
        )
    }

    private var systemProxyBinding: Binding<Bool> {
        Binding(
            get: { model.pendingSystemProxyEnabled ?? model.systemProxyEnabled },
            set: { enabled in Task { await model.setSystemProxyEnabled(enabled) } }
        )
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { searchText(for: selectedGroupName ?? routingMode) },
            set: {
                searchTextByGroup[
                    searchStateKey(for: selectedGroupName ?? routingMode)
                ] = $0
            }
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
                guard let proxy = workspaceSnapshot?.proxiesByName[name] else {
                    return false
                }
                return proxy.type.localizedCaseInsensitiveContains(query)
                    || proxy.providerName?.localizedCaseInsensitiveContains(query) == true
            }

        let mode = sortModesByGroup[group.name] ?? persistedSortMode(for: group.name)
        if mode == .profile { return filtered }

        return ProxyNodeSorter().sortedNodeNames(
            filtered,
            in: group.name,
            topology: workspaceSnapshot?.topology ?? .empty,
            delays: mode == .latency ? workspaceSnapshot?.delays ?? [:] : [:],
            mode: mode
        )
    }

    private func searchText(for group: String) -> String {
        searchTextByGroup[searchStateKey(for: group)] ?? ""
    }

    private func searchStateKey(for group: String) -> String {
        "\(selectedProfileStateScope)|\(group)"
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
        let profile = resolvedSelectedProfileID?.description ?? "runtime"
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
                || focusedNodeName.flatMap({
                    workspaceSnapshot?.proxiesByName[$0]
                }) == nil {
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
        guard workspaceSnapshot?.topology.vertices[name]?.isGroup == true else {
            return
        }
        selectedGroupName = name
        focusedNodeName = workspaceSnapshot?.proxiesByName[name]?.now
    }

    private var resolvedSelectedProfileID: ProfileID? {
        if let selectedProfileID,
           model.profileProxyWorkspaceProfiles.contains(where: {
               $0.id == selectedProfileID
           }) {
            return selectedProfileID
        }
        if let activeProfileID = model.activeProfileID,
           model.profileProxyWorkspaceProfiles.contains(where: {
               $0.id == activeProfileID
           }) {
            return activeProfileID
        }
        return model.profileProxyWorkspaceProfiles.first?.id
    }

    private var selectedProfileBinding: Binding<ProfileID> {
        Binding(
            get: {
                resolvedSelectedProfileID
                    ?? model.profileProxyWorkspaceProfiles.first?.id
                    ?? ProfileID()
            },
            set: { selectedProfileID = $0 }
        )
    }

    private var workspaceSnapshot: ProfileProxyWorkspaceSnapshot? {
        guard let profileID = resolvedSelectedProfileID else { return nil }
        return model.profileProxyWorkspaceState(for: profileID).snapshot
    }

    private var selectedProfileMixedPort: Int? {
        guard let profileID = resolvedSelectedProfileID,
              let session = model.profileSessionSpec(for: profileID),
              session.enabled else {
            return nil
        }
        return session.mixedPort
    }

    private var selectedProfileStateScope: String {
        resolvedSelectedProfileID?.description ?? stateScope
    }

    private func normalizeSelectedProfile() {
        let resolved = resolvedSelectedProfileID
        if selectedProfileID != resolved {
            selectedProfileID = resolved
        }
    }

    @ViewBuilder
    private func unavailableProfileWorkspace(
        profileID: ProfileID,
        state: ProfileProxyWorkspaceState?
    ) -> some View {
        let presentation = unavailablePresentation(state)

        ContentUnavailableView {
            Label(presentation.title, systemImage: presentation.symbol)
        } description: {
            Text(presentation.message)
        } actions: {
            if case .unavailable(.dedicatedPortDisabled(port: _)) = state {
                Button("Open Mixed Port") {
                    Task {
                        do {
                            try await model.setProfileMixedPortEnabled(
                                profileID: profileID,
                                enabled: true
                            )
                            _ = await model.refreshProxyWorkspace(for: profileID)
                        } catch {
                            model.errorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPerform(.updateProfile(profileID)))
            } else if state != .unavailable(.profileNotFound) {
                Button(
                    model.isConnected
                        ? AppLocalization.string("Reconnect")
                        : AppLocalization.string("Connect")
                ) {
                    Task {
                        if model.isConnected {
                            await model.restartConnection()
                        } else {
                            await model.connect()
                        }
                        _ = await model.refreshProxyWorkspace(for: profileID)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPerform(.connection))

                Button("Retry") {
                    Task {
                        _ = await model.refreshProxyWorkspace(for: profileID)
                    }
                }
                .disabled(
                    !model.canPerform(.refreshProfileProxyWorkspace(profileID))
                )
            }

            Button("View Logs") { model.selection = .logs }
        }
    }

    private func unavailablePresentation(
        _ state: ProfileProxyWorkspaceState?
    ) -> (title: String, symbol: String, message: String) {
        switch state {
        case let .unavailable(.dedicatedPortDisabled(port)):
            let message = port.map {
                AppLocalization.format(
                    "Open this Profile’s dedicated Mixed port to inspect and change its proxy groups. Its reserved Mixed port is %@.",
                    String($0)
                )
            } ?? AppLocalization.string(
                "Open this Profile’s dedicated Mixed port to inspect and change its proxy groups."
            )
            return (
                AppLocalization.string("Profile Port Is Closed"),
                "powerplug",
                message
            )
        case .unavailable(.primaryControllerNotReady):
            return (
                AppLocalization.string("Default Source Is Not Connected"),
                "point.3.connected.trianglepath.dotted",
                AppLocalization.string(
                    "Connect MClash to load this Profile’s live proxy groups."
                )
            )
        case .unavailable(.controllerStopped):
            return (
                AppLocalization.string("Profile Core Is Stopped"),
                "stop.circle",
                AppLocalization.string(
                    "Reconnect MClash to restore this Profile’s controller."
                )
            )
        case .unavailable(.controllerTransitioning):
            return (
                AppLocalization.string("Profile Core Is Changing State"),
                "arrow.triangle.2.circlepath",
                AppLocalization.string("Wait a moment, then retry loading this Profile.")
            )
        case let .unavailable(.controllerFailed(message)):
            return (
                AppLocalization.string("Profile Controller Failed"),
                "exclamationmark.triangle",
                message
            )
        case .unavailable(.profileNotFound):
            return (
                AppLocalization.string("Profile Not Found"),
                "doc.badge.questionmark",
                AppLocalization.string("This Profile is no longer available.")
            )
        case let .failed(message, _):
            return (
                AppLocalization.string("Proxy Groups Could Not Refresh"),
                "exclamationmark.arrow.triangle.2.circlepath",
                message
            )
        case .idle, .loading, .ready, nil:
            return (
                AppLocalization.string("Proxy Controls Unavailable"),
                "exclamationmark.triangle",
                AppLocalization.string(
                    "This Profile’s live controller data is not available."
                )
            )
        }
    }

    private var usesCompactChrome: Bool {
        measuredWorkspaceWidth > 0 && measuredWorkspaceWidth < 640
    }

    private var usesCompactTopologyNavigation: Bool {
        measuredWorkspaceWidth == 0 || measuredWorkspaceWidth < 920
    }

    private func updateWorkspaceWidth(_ width: CGFloat) {
        guard width > 0 else { return }

        measuredWorkspaceWidth = width
        let reconstructedFullWidth = width
            + (inspectorPresented && inspectorPresentation == .attached ? 340 : 0)
        let nextInspectorPresentation = inspectorPresentation.presentation(
            forFullWidth: reconstructedFullWidth,
            workspaceMode: workspaceMode
        )

        if inspectorPresentation != nextInspectorPresentation {
            inspectorPresentation = nextInspectorPresentation
        }
    }

    private func groupBehaviorTitle(_ group: MihomoProxy) -> String {
        switch group.groupBehavior {
        case .selector: AppLocalization.string("Manual Selector")
        case .urlTest: AppLocalization.string("Automatic URL Test")
        case .fallback: AppLocalization.string("Automatic Fallback")
        case .loadBalance: AppLocalization.string("Per-Connection Load Balance")
        case nil: group.type
        }
    }

    private func groupStatusText(_ group: MihomoProxy) -> String {
        if group.groupBehavior == .loadBalance {
            return AppLocalization.string(
                "The final node is selected independently for each connection."
            )
        }
        if group.fixedOverride != nil {
            return AppLocalization.format(
                "Pinned preference · active %@",
                group.now ?? AppLocalization.string("Not available")
            )
        }
        switch group.groupBehavior {
        case .urlTest, .fallback:
            return AppLocalization.format(
                "Current automatic choice: %@",
                group.now ?? AppLocalization.string("Not available")
            )
        default:
            return group.now.map {
                AppLocalization.format("Using %@", $0)
            } ?? AppLocalization.string("Choose a proxy node")
        }
    }

}

struct ProxyWorkspaceSizing {
    static let dividerWidth: CGFloat = 1

    static func groupSidebarWidth(for workspaceWidth: CGFloat) -> CGFloat {
        min(240, max(190, workspaceWidth * 0.22))
    }

    static func detailWidth(for workspaceWidth: CGFloat, sidebarWidth: CGFloat) -> CGFloat {
        max(0, workspaceWidth - sidebarWidth - dividerWidth)
    }
}

private enum ProxyInspectorPresentation: Equatable {
    case popover
    case attached

    func presentation(forFullWidth width: CGFloat, workspaceMode: ProxyWorkspaceMode) -> Self {
        let attachWidth: CGFloat = workspaceMode == .list ? 1_180 : 1_360
        let detachWidth: CGFloat = workspaceMode == .list ? 1_060 : 1_240

        switch self {
        case .popover:
            return width >= attachWidth ? Self.attached : Self.popover
        case .attached:
            return width < detachWidth ? Self.popover : Self.attached
        }
    }
}

private enum ProxyWorkspaceMode: String, CaseIterable, Identifiable {
    case list
    case topology

    var id: Self { self }
}

private extension ProfileProxyWorkspaceState {
    var isLoadingOrIdle: Bool {
        switch self {
        case .idle, .loading:
            true
        case .ready, .unavailable, .failed:
            false
        }
    }
}

struct ProxyGroupPartitionSnapshot {
    static let empty = ProxyGroupPartitionSnapshot(
        available: [],
        roots: [],
        nested: [],
        special: []
    )

    let available: [MihomoProxy]
    let roots: [MihomoProxy]
    let nested: [MihomoProxy]
    let special: [MihomoProxy]

    var orderedForPresentation: [MihomoProxy] {
        nested + roots + special
    }

    init(
        available: [MihomoProxy],
        roots: [MihomoProxy],
        nested: [MihomoProxy],
        special: [MihomoProxy]
    ) {
        self.available = available
        self.roots = roots
        self.nested = nested
        self.special = special
    }

    init(
        snapshot: ProfileProxyWorkspaceSnapshot,
        routingMode: String
    ) {
        let available = snapshot.proxyGroups(forRoutingMode: routingMode)
        self.available = available

        if routingMode == "global" {
            roots = available
            nested = []
            special = []
            return
        }

        var nestedNames = Set<String>()
        for edge in snapshot.topology.edges
        where edge.kind == .member
            && edge.source != "GLOBAL"
            && snapshot.topology.vertices[edge.source]?.isGroup == true {
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
            messages.append(AppLocalization.string(
                "Proxy choices may be stale while MClash reconnects to the Alpha API."
            ))
        }
        if model.degradedStreams.contains(.connections) {
            messages.append(AppLocalization.string(
                "Connection counts and observed route traffic are temporarily stale."
            ))
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
            AppLocalization.format(
                "%@, %@, %@, %@ members, %@",
                group.name,
                group.type,
                group.alive
                    ? AppLocalization.string("Available")
                    : AppLocalization.string("Unavailable"),
                formattedCount(group.all.count),
                routeSummary
            )
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
            summary = AppLocalization.string("Per-connection route")
        } else if let path, let terminal = path.terminal {
            summary = path.route.count > 2 ? "… → \(terminal)" : terminal
        } else {
            summary = group.now ?? AppLocalization.string("Route unavailable")
        }
        return group.alive
            ? summary
            : AppLocalization.format("Unavailable · %@", summary)
    }
}

private struct ProxyNodeListContent: View {
    @Bindable var model: AppModel
    let profileID: ProfileID
    let snapshot: ProfileProxyWorkspaceSnapshot
    let group: MihomoProxy
    let nodeNames: [String]
    @Binding var focusedNodeName: String?
    let openGroup: (String) -> Void

    var body: some View {
        List(nodeNames, id: \.self, selection: $focusedNodeName) { nodeName in
            ProxyNodeListRow(
                node: snapshot.proxiesByName[nodeName],
                nodeName: nodeName,
                isSelected: group.now == nodeName,
                isFixed: group.fixedOverride == nodeName,
                isPending: model.pendingProxySelection(
                    profileID: profileID,
                    group: group.name
                ) == nodeName,
                isAlive: snapshot.proxiesByName[nodeName]?.alive,
                delay: snapshot.delay(for: nodeName),
                supportsSelection: group.groupBehavior?.supportsSelectionUpdate == true,
                canSelect: model.canPerform(
                    .selectProfileProxy(profileID, group.name)
                ),
                selectionInProgress: model.isPerforming(
                    .selectProfileProxy(profileID, group.name)
                ),
                onSelect: {
                    focusedNodeName = nodeName
                    Task {
                        _ = await model.selectProxy(
                            profileID: profileID,
                            group: group.name,
                            proxy: nodeName
                        )
                    }
                },
                onOpenGroup: snapshot.topology.vertices[nodeName]?.isGroup == true
                    ? { openGroup(nodeName) }
                    : nil,
                onTest: {
                    Task {
                        _ = await model.measureDelay(
                            profileID: profileID,
                            proxy: nodeName,
                            group: group.name
                        )
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
    let isPending: Bool
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
                Button(
                    isSelected
                        ? AppLocalization.string("Current Route")
                        : AppLocalization.string("Use Node"),
                    action: onSelect
                )
                    .disabled(!canSelect || selectionInProgress || isSelected)
            }
            Button("Test Latency", action: onTest)
            if let onOpenGroup {
                Button("Open Group", action: onOpenGroup)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var selectionButton: some View {
        if supportsSelection {
            Button(action: onSelect) {
                if isPending {
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
            .disabled(!canSelect || selectionInProgress)
            .help(selectionHelp)
            .accessibilityLabel(selectionHelp)
        } else if isSelected || isFixed {
            Image(systemName: isFixed ? "pin.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isFixed ? Color.orange : Color.accentColor)
                .frame(width: 28, height: 28)
                .accessibilityLabel(
                    isFixed
                        ? AppLocalization.string("Pinned preference")
                        : AppLocalization.string("Current automatic route")
                )
        } else {
            Color.clear
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
        }
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

            Text(statusText)
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
        if !supportsSelection {
            return AppLocalization.string(
                "This group does not support manual node selection"
            )
        }
        if isPending { return AppLocalization.format("Switching to %@", nodeName) }
        if !canSelect {
            return AppLocalization.string("Proxy selection is temporarily unavailable")
        }
        if isFixed { return AppLocalization.string("Pinned automatic preference") }
        return isSelected
            ? AppLocalization.string("Currently selected")
            : AppLocalization.format("Select %@", nodeName)
    }

    private var statusText: String {
        if node == nil { return AppLocalization.string("Missing") }
        if isAlive == false { return AppLocalization.string("Unavailable") }
        if delay != nil || node?.history.isEmpty == false {
            return AppLocalization.string("Available")
        }
        return AppLocalization.string("Not tested")
    }

    private var statusColor: Color {
        if isAlive == false { return .red }
        if delay != nil || node?.history.isEmpty == false { return .green }
        return Color(nsColor: .tertiaryLabelColor)
    }

    private var delayText: String {
        delay.map {
            AppLocalization.format("%@ ms", formattedCount($0))
        } ?? AppLocalization.string("Not tested")
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
    @Environment(\.colorSchemeContrast) private var contrast

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
                                ? Color.accentColor.opacity(contrast == .increased ? 0.22 : 0.13)
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
        .accessibilityLabel(
            AppLocalization.format(
                "Current route: %@",
                path.route.joined(
                    separator: ", \(AppLocalization.string("then")) "
                )
            )
        )
    }
}

private extension ProxyNodeSortMode {
    var title: String {
        switch self {
        case .profile: AppLocalization.string("Profile")
        case .latency: AppLocalization.string("Latency")
        case .name: AppLocalization.string("Name")
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
