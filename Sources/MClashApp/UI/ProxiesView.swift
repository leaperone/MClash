import SwiftUI

struct ProxiesView: View {
    @Bindable var model: AppModel

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
                    Text("Loading proxy controls…")
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
                List {
                    Section("Routing") {
                        Picker("Mode", selection: modeBinding) {
                            Text("Rule").tag("rule")
                            Text("Global").tag("global")
                            Text("Direct").tag("direct")
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.networkStateTransitionInProgress || model.isPerforming(.changeMode))

                        Toggle("Use macOS system proxy", isOn: systemProxyBinding)
                            .disabled(model.networkStateTransitionInProgress)
                    }

                    ForEach(model.proxyGroups, id: \.name) { group in
                        ProxyGroupSection(model: model, group: group)
                    }
                }
            }
        }
        .navigationTitle("Proxies")
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
}

private struct ProxyGroupSection: View {
    @Bindable var model: AppModel
    let group: MihomoProxy
    @State private var showingNodePicker = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Button {
                    showingNodePicker = true
                } label: {
                    HStack {
                        Text(group.now ?? "Choose a node")
                            .lineLimit(1)
                            .help(group.now ?? "Choose a node")
                        Spacer()
                        if model.isPerforming(.selectProxy(group.name)) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "chevron.up.chevron.down")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(
                    model.networkStateTransitionInProgress
                        || model.isPerforming(.selectProxy(group.name))
                )
                .popover(isPresented: $showingNodePicker, arrowEdge: .trailing) {
                    ProxyNodePicker(
                        model: model,
                        group: group,
                        isPresented: $showingNodePicker
                    )
                }

                if let selected = group.now, let delay = model.proxyDelays[selected] {
                    Text("\(delay) ms")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(delayColor(delay))
                        .fixedSize()
                }

                Button {
                    Task { await model.measureGroupDelays(group: group.name) }
                } label: {
                    if model.isPerforming(.measureGroupDelay(group.name)) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Test", systemImage: "speedometer")
                    }
                }
                .disabled(
                    model.networkStateTransitionInProgress
                        || model.isPerforming(.measureGroupDelay(group.name))
                )
                .help("Test latency for every node in \(group.name)")
            }

            Text("\(group.all.count) available nodes")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            HStack {
                Text(group.name)
                Spacer()
                Text(group.type)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay <= 0 { return .secondary }
        if delay < 150 { return .green }
        if delay < 350 { return .orange }
        return .red
    }
}
