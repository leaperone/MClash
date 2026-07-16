import SwiftUI

struct ProxiesView: View {
    @Bindable var model: AppModel
    @State private var selectedGroupName: String?
    @State private var focusedNodeName: String?
    @State private var workspaceMode: ProxyWorkspaceMode = .list
    @State private var sortModesByGroup: [String: ProxyNodeSortMode] = [:]
    @State private var searchTextByGroup: [String: String] = [:]
    @State private var inspectorPresented = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
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
                VStack(spacing: 0) {
                    routingToolbar
                    Divider()
                    ContentUnavailableView(
                        "Direct routing is active",
                        systemImage: "arrow.right",
                        description: Text(
                            "Connections bypass proxy groups until Rule or Global mode is selected."
                        )
                    )
                }
            } else if availableGroups.isEmpty {
                VStack(spacing: 0) {
                    routingToolbar
                    Divider()
                    ContentUnavailableView(
                        "No selectable groups",
                        systemImage: "tray",
                        description: Text(
                            routingMode == "global"
                                ? "The active core did not expose the GLOBAL group."
                                : "The active configuration did not expose a selectable proxy group."
                        )
                    )
                }
            } else {
                proxyWorkspace
            }
        }
        .navigationTitle("Proxies")
        .mclashPageSurface()
        .searchable(text: searchBinding, prompt: "Search nodes in the current group")
        .onAppear(perform: normalizeSelection)
        .onChange(of: model.proxyTopology.groupOrder) { _, _ in normalizeSelection() }
        .onChange(of: model.runtimeConfig?.mode) { _, _ in normalizeSelection() }
        .onChange(of: selectedGroupName) { _, name in
            focusedNodeName = name.flatMap { model.proxiesByName[$0]?.now }
        }
        .toolbar {
            if model.controllerIsReady, routingMode != "direct" {
                ToolbarItem {
                    Button {
                        inspectorPresented.toggle()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.right")
                    }
                    .help(inspectorPresented ? "Hide Inspector" : "Show Inspector")
                }
            }
        }
    }

    private var proxyWorkspace: some View {
        VStack(spacing: 0) {
            routingToolbar
            if !proxyDataWarningMessages.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(proxyDataWarningMessages, id: \.self) { message in
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
            Divider()

            HSplitView {
                groupSidebar
                    .frame(minWidth: 160, idealWidth: 210, maxWidth: 250)

                groupDetail
                    .frame(minWidth: 300, maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .inspector(isPresented: $inspectorPresented) {
            ProxyInspectorView(
                model: model,
                group: selectedGroup,
                focusedNodeName: focusedNodeName,
                openGroup: openGroup
            )
            .inspectorColumnWidth(min: 220, ideal: 280, max: 340)
        }
    }

    private var routingToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                routingModePicker

                Divider()
                    .frame(height: 20)

                systemProxyToggle
                Spacer()
                localEndpointLabels
            }

            HStack(spacing: 12) {
                routingModePicker
                Spacer()
                systemProxyToggle
            }

            VStack(alignment: .leading, spacing: 10) {
                routingModePicker
                    .frame(maxWidth: .infinity)
                systemProxyToggle
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var routingModePicker: some View {
        Picker("Routing mode", selection: modeBinding) {
            Text("Rule").tag("rule")
            Text("Global").tag("global")
            Text("Direct").tag("direct")
        }
        .pickerStyle(.segmented)
        .frame(minWidth: 190, idealWidth: 250, maxWidth: 250)
        .disabled(!model.canPerform(.changeMode))
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

    private var groupSidebar: some View {
        List(selection: $selectedGroupName) {
            if !nestedGroups.isEmpty {
                Section("Nested Groups") {
                    ForEach(nestedGroups, id: \.name) { group in
                        ProxyGroupSidebarRow(
                            group: group,
                            path: model.proxySelectionPaths[group.name]
                        )
                        .tag(group.name)
                    }
                }
            }

            if !rootGroups.isEmpty {
                Section("Entry Groups") {
                    ForEach(rootGroups, id: \.name) { group in
                        ProxyGroupSidebarRow(
                            group: group,
                            path: model.proxySelectionPaths[group.name]
                        )
                        .tag(group.name)
                    }
                }
            }

            if !specialGroups.isEmpty {
                Section("Special Groups") {
                    ForEach(specialGroups, id: \.name) { group in
                        ProxyGroupSidebarRow(
                            group: group,
                            path: model.proxySelectionPaths[group.name]
                        )
                        .tag(group.name)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contentMargins(.vertical, 8, for: .scrollContent)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityLabel("Proxy groups with nested groups first")
    }

    @ViewBuilder
    private var groupDetail: some View {
        if let group = selectedGroup {
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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    groupTitle(group)
                    Spacer(minLength: 16)
                    groupControls(group)
                }

                VStack(alignment: .leading, spacing: 10) {
                    groupTitle(group)
                    groupControls(group)
                }
            }

            if let path = model.proxySelectionPaths[group.name] {
                ProxyPathStrip(path: path)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func groupTitle(_ group: MihomoProxy) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    Text(group.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(groupBehaviorTitle(group))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(groupBehaviorTitle(group))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(groupStatusText(group))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func groupControls(_ group: MihomoProxy) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                workspacePicker(width: 190)
                if workspaceMode == .list {
                    sortPicker(group: group, width: 132)
                }
                testAllButton(group: group, compact: false)
            }

            HStack(spacing: 8) {
                workspacePicker(width: 160)
                if workspaceMode == .list {
                    sortPicker(group: group, width: 104)
                }
                testAllButton(group: group, compact: true)
            }

            HStack(spacing: 8) {
                workspacePicker(width: 142)
                Menu {
                    if workspaceMode == .list {
                        Picker("Node order", selection: sortBinding(for: group.name)) {
                            ForEach(ProxyNodeSortMode.allCases, id: \.rawValue) { mode in
                                Label(mode.title, systemImage: mode.symbol).tag(mode)
                            }
                        }
                    }
                    Button("Test All") {
                        Task { await model.measureGroupDelays(group: group.name) }
                    }
                    .disabled(!model.canPerform(.measureGroupDelay(group.name)))
                } label: {
                    if model.isPerforming(.measureGroupDelay(group.name)) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("More group actions", systemImage: "ellipsis.circle")
                    }
                }
                .menuStyle(.borderlessButton)
                .labelStyle(.iconOnly)
            }
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

    private func automaticOverrideBanner(group: MihomoProxy, fixed: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pin.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Automatic selection is pinned")
                    .font(.callout.weight(.medium))
                Text("Preferred node: \(fixed). The active node still follows mihomo health checks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resume Automatic") {
                Task { _ = await model.clearProxyOverride(group: group.name) }
            }
            .disabled(!model.canPerform(.clearProxyOverride(group.name)))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.09))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func proxyNodeList(_ group: MihomoProxy) -> some View {
        if displayedNodeNames(in: group).isEmpty {
            ContentUnavailableView.search(text: searchText(for: group.name))
        } else {
            List(displayedNodeNames(in: group), id: \.self) { nodeName in
                ProxyNodeListRow(
                    node: model.proxiesByName[nodeName],
                    nodeName: nodeName,
                    isSelected: group.now == nodeName,
                    isFixed: group.fixedOverride == nodeName,
                    isFocused: focusedNodeName == nodeName,
                    isAlive: model.proxyAlive(for: nodeName, in: group.name),
                    delay: model.proxyDelay(for: nodeName, in: group.name),
                    activeConnections: activeConnectionCount(through: nodeName),
                    observedBytes: observedTraffic(through: nodeName),
                    supportsSelection: group.groupBehavior?.supportsSelectionUpdate == true,
                    canSelect: model.canPerform(.selectProxy(group.name)),
                    selectionInProgress: model.isPerforming(.selectProxy(group.name)),
                    onFocus: { focusedNodeName = nodeName },
                    onSelect: {
                        focusedNodeName = nodeName
                        Task { _ = await model.selectProxy(group: group.name, proxy: nodeName) }
                    },
                    onOpenGroup: model.proxyTopology.vertices[nodeName]?.isGroup == true
                        ? { openGroup(nodeName) }
                        : nil,
                    onTest: {
                        Task { _ = await model.measureDelay(proxy: nodeName, group: group.name) }
                    }
                )
            }
            .listStyle(.inset)
            .mclashListSurface(horizontalMargin: 10, verticalMargin: 8)
            .accessibilityLabel("Nodes in \(group.name)")
        }
    }

    private var selectedGroup: MihomoProxy? {
        guard let selectedGroupName else { return availableGroups.first }
        return model.proxiesByName[selectedGroupName] ?? availableGroups.first
    }

    private var availableGroups: [MihomoProxy] {
        model.proxyGroups(forRoutingMode: routingMode)
    }

    private var rootGroups: [MihomoProxy] {
        if routingMode == "global" { return availableGroups }
        return availableGroups.filter { group in
            guard group.name != "GLOBAL" else { return false }
            return !model.proxyTopology.edges.contains { edge in
                edge.kind == .member
                    && edge.target == group.name
                    && edge.source != "GLOBAL"
                    && model.proxyTopology.vertices[edge.source]?.isGroup == true
            }
        }
    }

    private var nestedGroups: [MihomoProxy] {
        if routingMode == "global" { return [] }
        let roots = Set(rootGroups.map(\.name))
        return availableGroups.filter { $0.name != "GLOBAL" && !roots.contains($0.name) }
    }

    private var specialGroups: [MihomoProxy] {
        routingMode == "rule" ? availableGroups.filter { $0.name == "GLOBAL" } : []
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

        return ProxyNodeSorter().sortedNodeNames(
            filtered,
            in: group.name,
            topology: model.proxyTopology,
            delays: model.proxyDelayMap(for: group.name),
            mode: sortModesByGroup[group.name] ?? persistedSortMode(for: group.name)
        )
    }

    private func searchText(for group: String) -> String {
        searchTextByGroup[group] ?? ""
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

    private func normalizeSelection() {
        if routingMode == "direct" {
            selectedGroupName = nil
            focusedNodeName = nil
            return
        }

        let names = Set(availableGroups.map(\.name))
        if let selectedGroupName, names.contains(selectedGroupName) {
            return
        }
        selectedGroupName = rootGroups.first?.name ?? availableGroups.first?.name
        focusedNodeName = selectedGroupName.flatMap { model.proxiesByName[$0]?.now }
    }

    private func openGroup(_ name: String) {
        guard model.proxyTopology.vertices[name]?.isGroup == true else { return }
        selectedGroupName = name
        focusedNodeName = model.proxiesByName[name]?.now
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

    private func activeConnectionCount(through node: String) -> Int {
        guard !model.degradedStreams.contains(.connections) else { return 0 }
        return model.connections?.connections.reduce(into: 0) { count, connection in
            if connection.chains.contains(node) { count += 1 }
        } ?? 0
    }

    private func observedTraffic(through node: String) -> Int64 {
        guard !model.degradedStreams.contains(.connections) else { return 0 }
        return model.routeTrafficEntries.reduce(into: Int64(0)) { total, entry in
            guard entry.routing.chains.contains(node) else { return }
            let (next, overflow) = total.addingReportingOverflow(entry.totalDelta)
            total = overflow ? Int64.max : next
        }
    }

    private var proxyDataWarningMessages: [String] {
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

private enum ProxyWorkspaceMode: String, CaseIterable, Identifiable {
    case list
    case topology

    var id: Self { self }
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

private struct ProxyNodeListRow: View {
    let node: MihomoProxy?
    let nodeName: String
    let isSelected: Bool
    let isFixed: Bool
    let isFocused: Bool
    let isAlive: Bool?
    let delay: Int?
    let activeConnections: Int
    let observedBytes: Int64
    let supportsSelection: Bool
    let canSelect: Bool
    let selectionInProgress: Bool
    let onFocus: () -> Void
    let onSelect: () -> Void
    let onOpenGroup: (() -> Void)?
    let onTest: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 11) {
                selectionButton
                nodeInformationButton
                    .layoutPriority(1)
                Spacer(minLength: 12)
                activityIndicators
                delayIndicator
                openGroupButton
            }
            .frame(minWidth: 520)

            HStack(spacing: 9) {
                selectionButton
                nodeInformationButton
                    .layoutPriority(1)
                delayIndicator
                openGroupButton
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            isFocused ? Color.accentColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contextMenu {
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
        .disabled(!supportsSelection || !canSelect || selectionInProgress)
        .help(selectionHelp)
        .accessibilityLabel(selectionHelp)
    }

    private var nodeInformationButton: some View {
        Button(action: onFocus) {
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
        }
        .buttonStyle(.plain)
        .help(nodeName)
        .accessibilityLabel("Inspect \(nodeName), \(statusText), \(delayText)")
    }

    @ViewBuilder
    private var activityIndicators: some View {
        if activeConnections > 0 {
            Label(formattedCount(activeConnections), systemImage: "bolt.horizontal.fill")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("\(formattedCount(activeConnections)) active connections")
        }

        if observedBytes > 0 {
            Text(formattedByteCount(observedBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Observed traffic during the last five minutes")
        }
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
                .frame(minWidth: 58, alignment: .trailing)
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
