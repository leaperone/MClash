import SwiftUI

struct ProxiesView: View {
    @Bindable var model: AppModel
    @State private var selectedGroupName: String?
    @State private var searchText = ""
    @State private var nodeSortOrder: ProxyNodeSortOrder = .configuration

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
            } else if model.proxyGroups.isEmpty {
                ContentUnavailableView(
                    "No selectable groups",
                    systemImage: "tray",
                    description: Text("The active configuration did not expose a selectable proxy group.")
                )
            } else {
                VStack(spacing: 0) {
                    routingToolbar
                    Divider()

                    HSplitView {
                        groupList
                            .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)
                        groupDetail
                            .frame(minWidth: 430, maxWidth: .infinity)
                    }
                }
            }
        }
        .navigationTitle("Proxies")
        .searchable(text: $searchText, prompt: "Search nodes")
        .onAppear(perform: normalizeSelection)
        .onChange(of: model.proxyGroups.map(\.name)) { _, _ in normalizeSelection() }
    }

    private var routingToolbar: some View {
        HStack(spacing: 16) {
            Picker("Routing mode", selection: modeBinding) {
                Text("Rule").tag("rule")
                Text("Global").tag("global")
                Text("Direct").tag("direct")
            }
            .pickerStyle(.segmented)
            .frame(width: 250)
            .disabled(!model.canPerform(.changeMode))

            Divider()
                .frame(height: 20)

            Toggle("System Proxy", isOn: systemProxyBinding)
                .toggleStyle(.switch)
                .disabled(!model.controllerIsReady || !model.canPerform(.changeSystemProxy))

            Spacer()

            if let http = model.localHTTPProxyAddress {
                Label("HTTP \(http)", systemImage: "globe")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let socks = model.localSOCKSProxyAddress {
                Label("SOCKS5 \(socks)", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var groupList: some View {
        List(selection: $selectedGroupName) {
            ForEach(model.proxyGroups, id: \.name) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(group.name)
                            .fontWeight(group.name == selectedGroupName ? .semibold : .regular)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(group.all.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(group.alive ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        Text(group.now ?? "Not selected")
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .tag(group.name)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(group.name), \(group.alive ? "available" : "unavailable"), "
                        + "\(group.all.count) nodes, current \(group.now ?? "not selected")"
                )
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Proxy groups")
    }

    @ViewBuilder
    private var groupDetail: some View {
        if let group = selectedGroup {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name)
                            .font(.title3.weight(.semibold))
                        Text(group.now.map { "Using \($0)" } ?? "Choose a proxy node")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Picker("Node order", selection: $nodeSortOrder) {
                        ForEach(ProxyNodeSortOrder.allCases) { order in
                            Label(order.title, systemImage: order.symbol)
                                .tag(order)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 132)

                    Button {
                        Task { await model.measureGroupDelays(group: group.name) }
                    } label: {
                        if model.isPerforming(.measureGroupDelay(group.name)) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Test All", systemImage: "speedometer")
                        }
                    }
                    .disabled(!model.canPerform(.measureGroupDelay(group.name)))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                Divider()

                if filteredNodes(in: group).isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(filteredNodes(in: group), id: \.self) { nodeName in
                        ProxyNodeRow(model: model, group: group, nodeName: nodeName)
                    }
                    .listStyle(.inset)
                    .accessibilityLabel("Nodes in \(group.name)")
                }
            }
        } else {
            ContentUnavailableView(
                "Choose a proxy group",
                systemImage: "sidebar.left",
                description: Text("Select a group to inspect and switch its nodes.")
            )
        }
    }

    private var selectedGroup: MihomoProxy? {
        if let selectedGroupName,
           let group = model.proxyGroups.first(where: { $0.name == selectedGroupName }) {
            return group
        }
        return model.proxyGroups.first
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { model.runtimeConfig?.mode ?? "rule" },
            set: { mode in Task { await model.setMode(mode) } }
        )
    }

    private var systemProxyBinding: Binding<Bool> {
        Binding(
            get: { model.systemProxyEnabled },
            set: { enabled in Task { await model.setSystemProxyEnabled(enabled) } }
        )
    }

    private func filteredNodes(in group: MihomoProxy) -> [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var nodes = query.isEmpty
            ? group.all
            : group.all.filter { $0.localizedCaseInsensitiveContains(query) }

        switch nodeSortOrder {
        case .configuration:
            break
        case .name:
            nodes.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        case .latency:
            nodes.sort { lhs, rhs in
                let left = nodeDelay(lhs) ?? Int.max
                let right = nodeDelay(rhs) ?? Int.max
                if left == right {
                    return lhs.localizedStandardCompare(rhs) == .orderedAscending
                }
                return left < right
            }
        }
        return nodes
    }

    private func nodeDelay(_ name: String) -> Int? {
        model.proxyDelays[name]
            ?? model.proxiesByName[name]?.history.last(where: { $0.delay > 0 })?.delay
    }

    private func normalizeSelection() {
        guard !model.proxyGroups.isEmpty else {
            selectedGroupName = nil
            return
        }
        if let selectedGroupName,
           model.proxyGroups.contains(where: { $0.name == selectedGroupName }) {
            return
        }
        selectedGroupName = model.proxyGroups.first?.name
    }
}

private enum ProxyNodeSortOrder: String, CaseIterable, Identifiable {
    case configuration
    case latency
    case name

    var id: Self { self }

    var title: String {
        switch self {
        case .configuration: "Profile"
        case .latency: "Latency"
        case .name: "Name"
        }
    }

    var symbol: String {
        switch self {
        case .configuration: "list.bullet"
        case .latency: "speedometer"
        case .name: "textformat"
        }
    }
}

private struct ProxyNodeRow: View {
    @Bindable var model: AppModel
    let group: MihomoProxy
    let nodeName: String

    var body: some View {
        Button {
            Task { _ = await model.selectProxy(group: group.name, proxy: nodeName) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(nodeName)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(node?.type ?? "Proxy")
                        if node?.udp == true { Text("UDP") }
                        if node?.tcpFastOpen == true { Text("TFO") }
                        if node?.providerName?.isEmpty == false {
                            Text(node?.providerName ?? "")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(node?.alive == false ? Color.red : Color.green)
                        .frame(width: 7, height: 7)
                    Text(delayText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(delayColor)
                        .frame(minWidth: 58, alignment: .trailing)
                }

                if model.isPerforming(.selectProxy(group.name)), isSelected {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(!model.canPerform(.selectProxy(group.name)))
        .contextMenu {
            Button("Test Latency") {
                Task { _ = await model.measureDelay(proxy: nodeName, group: group.name) }
            }
            .disabled(!model.canPerform(.measureDelay(nodeName)))
        }
        .accessibilityLabel(
            "\(nodeName), \(node?.alive == false ? "unavailable" : "available"), "
                + "\(isSelected ? "selected" : "not selected"), \(delayText)"
        )
    }

    private var node: MihomoProxy? {
        model.proxiesByName[nodeName]
    }

    private var isSelected: Bool {
        group.now == nodeName
    }

    private var delay: Int? {
        model.proxyDelays[nodeName]
            ?? node?.history.last(where: { $0.delay > 0 })?.delay
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
