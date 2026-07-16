import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusHeader
                    primaryAction

                    Divider()

                    profileControl

                    if model.isConnected {
                        connectedControls
                    }

                    if let errorMessage = model.errorMessage {
                        inlineError(errorMessage)
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: .infinity)

            Divider()

            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        // MenuBarExtra windows cannot infer a useful intrinsic height from ScrollView content.
        // An explicit popover size keeps the entire quick-control surface visible on every launch.
        .frame(width: 360, height: 600)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MClash quick controls")
    }

    private var statusHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if model.isConnected {
                VStack(alignment: .trailing, spacing: 2) {
                    Label(formattedByteRate(model.traffic.download), systemImage: "arrow.down")
                    Label(formattedByteRate(model.traffic.upload), systemImage: "arrow.up")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Download \(formattedByteRate(model.traffic.download)), upload \(formattedByteRate(model.traffic.upload))"
                )
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if model.activeProfile == nil, !model.isConnected {
            Button {
                showMainWindow(destination: .profiles)
            } label: {
                Label("Choose a Profile", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            Button {
                Task { await model.toggleConnection() }
            } label: {
                HStack(spacing: 8) {
                    if connectionOperationInProgress {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: connectionButtonSymbol)
                    }
                    Text(connectionButtonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!connectionActionAvailable)
        }
    }

    private var profileControl: some View {
        LabeledContent("Profile") {
            Menu {
                if model.profiles.isEmpty {
                    Text("No profiles")
                } else {
                    ForEach(model.profiles) { profile in
                        Button {
                            Task {
                                do {
                                    try await model.activateProfile(profile.id)
                                } catch {
                                    model.errorMessage = error.localizedDescription
                                }
                            }
                        } label: {
                            if profile.id == model.activeProfileID {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                        .disabled(
                            profile.id == model.activeProfileID
                                || !model.canPerform(.activateProfile(profile.id))
                        )
                    }
                }

                Divider()

                Button("Manage Profiles…") {
                    showMainWindow(destination: .profiles)
                }
            } label: {
                HStack(spacing: 5) {
                    Text(model.activeProfile?.name ?? "None")
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectedControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            Toggle(
                "Use macOS System Proxy",
                isOn: Binding(
                    get: { model.systemProxyEnabled },
                    set: { enabled in Task { await model.setSystemProxyEnabled(enabled) } }
                )
            )
            .disabled(!model.controllerIsReady || !model.canPerform(.changeSystemProxy))

            if !model.systemProxyEnabled {
                Label(
                    "Core is running; other apps will use MClash after System Proxy is enabled.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Routing Mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Routing Mode", selection: modeBinding) {
                    Text("Rule").tag("rule")
                    Text("Global").tag("global")
                    Text("Direct").tag("direct")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(
                    !model.controllerIsReady
                        || !model.canPerform(.changeMode)
                )
            }

            if model.controllerIsReady {
                proxyEndpointSummary
            }

            if model.controllerState == .loading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading proxy controls…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if model.controllerIsReady, !quickProxyGroups.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Proxy Groups")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if quickProxyGroups.count > 3 {
                            Button("Show All") {
                                showMainWindow(destination: .proxies)
                            }
                            .buttonStyle(.link)
                            .controlSize(.small)
                        }
                    }

                    ForEach(Array(quickProxyGroups.prefix(3)), id: \.name) { group in
                        ProxyGroupQuickControl(model: model, group: group)
                    }
                }
            }

            if model.liveMetricsAreDegraded {
                Label("Live metrics interrupted · reconnecting", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 12) {
                Button("Connections") {
                    showMainWindow(destination: .connections)
                }
                .buttonStyle(.link)

                Text("\(formattedCount(model.connections?.connections.count ?? 0)) active")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    Task { await model.restartConnection() }
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(model.networkStateTransitionInProgress)

                if model.connections?.connections.isEmpty == false {
                    Button("Close All") {
                        Task { await model.closeAllConnections() }
                    }
                    .controlSize(.small)
                    .disabled(
                        !model.canPerform(.closeAllConnections)
                    )
                }
            }
        }
    }

    private var proxyEndpointSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Local Proxy")
                .font(.caption)
                .foregroundStyle(.secondary)

            ProxyEndpointRow(
                label: "HTTP",
                address: model.localHTTPProxyAddress,
                symbol: "globe"
            )
            ProxyEndpointRow(
                label: "SOCKS5",
                address: model.localSOCKSProxyAddress,
                symbol: "point.3.connected.trianglepath.dotted"
            )
        }
    }

    private func inlineError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label {
                Text(message)
                    .lineLimit(3)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .font(.callout)

            HStack {
                if model.systemProxyRecoveryRequired {
                    Button {
                        Task { await model.disableSystemProxy() }
                    } label: {
                        if model.isPerforming(.changeSystemProxy) {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Restoring…")
                            }
                        } else {
                            Text("Try Restore Again")
                        }
                    }
                    .disabled(model.isPerforming(.changeSystemProxy))
                }
                Button("View Logs") {
                    model.errorMessage = nil
                    showMainWindow(destination: .logs)
                }
                Button("Dismiss") { model.errorMessage = nil }
            }
            .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Open MClash") {
                showMainWindow(destination: model.selection ?? .overview)
            }
            .keyboardShortcut("o")

            SettingsLink { Text("Settings…") }

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { model.runtimeConfig?.mode ?? "rule" },
            set: { mode in Task { await model.setMode(mode) } }
        )
    }

    private var quickProxyGroups: [MihomoProxy] {
        model.proxyGroups(forRoutingMode: model.runtimeConfig?.mode ?? "rule")
    }

    private var connectionOperationInProgress: Bool {
        model.isPerforming(.connection) || model.isBusy
    }

    private var connectionActionAvailable: Bool {
        if model.systemProxyRecoveryRequired { return false }
        if !model.canPerform(.connection) { return false }
        switch model.coreState {
        case .validating, .starting, .stopping:
            return false
        default:
            return true
        }
    }

    private var connectionButtonTitle: String {
        switch model.coreState {
        case .running: "Disconnect"
        case .validating: "Checking Configuration…"
        case .starting: "Connecting…"
        case .stopping: "Disconnecting…"
        case .stopped, .failed: "Connect"
        }
    }

    private var connectionButtonSymbol: String {
        model.isConnected ? "stop.fill" : "play.fill"
    }

    private var statusTitle: String {
        switch model.coreState {
        case .running:
            switch model.controllerState {
            case .ready: "Connected"
            case .loading: "Preparing Controls"
            case .degraded: "Connected with an Issue"
            case .idle: "Connected"
            }
        default:
            model.statusTitle
        }
    }

    private var statusSubtitle: String {
        if let profile = model.activeProfile {
            return profile.name
        }
        return "No active profile"
    }

    private var statusSymbol: String {
        switch model.coreState {
        case .running:
            model.controllerIsReady ? "checkmark.shield.fill" : "ellipsis.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .validating, .starting, .stopping:
            "arrow.triangle.2.circlepath"
        case .stopped:
            "pause.circle.fill"
        }
    }

    private var statusColor: Color {
        switch model.coreState {
        case .running:
            model.controllerIsReady ? .green : .orange
        case .failed:
            .red
        case .validating, .starting, .stopping:
            .orange
        case .stopped:
            .secondary
        }
    }

    private func showMainWindow(destination: AppModel.Destination) {
        model.selection = destination
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct ProxyEndpointRow: View {
    let label: String
    let address: String?
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Label(label, systemImage: symbol)
                .foregroundStyle(.secondary)
            Spacer()
            Text(address ?? "Unavailable")
                .font(.caption.monospacedDigit())
                .foregroundStyle(address == nil ? .secondary : .primary)
            if let address {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy \(label) proxy address")
                .accessibilityLabel("Copy \(label) proxy address")
            }
        }
        .font(.caption)
    }
}

private struct ProxyGroupQuickControl: View {
    @Bindable var model: AppModel
    let group: MihomoProxy
    @State private var showingNodePicker = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.callout)
                    .lineLimit(1)
                    .help(group.name)
                HStack(spacing: 5) {
                    Text(group.now ?? "Not selected")
                        .lineLimit(1)
                        .help(group.now ?? "Not selected")
                    if group.fixedOverride != nil {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(.orange)
                            .help("Automatic selection is pinned")
                    }
                    if let selected = group.now,
                       let delay = model.proxyDelay(for: selected, in: group.name)
                            ?? historyDelay(selected) {
                        Text("· \(delay) ms")
                            .monospacedDigit()
                            .foregroundStyle(delayColor(delay))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let selected = group.now {
                Button {
                    Task {
                        _ = await model.measureDelay(proxy: selected, group: group.name)
                    }
                } label: {
                    if model.isPerforming(.measureDelay(selected)) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "speedometer")
                    }
                }
                .buttonStyle(.borderless)
                .help("Test selected node latency")
                .accessibilityLabel("Test \(selected) latency")
                .disabled(
                    !model.canPerform(.measureDelay(selected))
                )
            }

            Button {
                showingNodePicker = true
            } label: {
                if model.isPerforming(.selectProxy(group.name)) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                }
            }
            .buttonStyle(.borderless)
            .help("Choose node for \(group.name)")
            .accessibilityLabel("Choose node for \(group.name)")
            .disabled(
                group.groupBehavior?.supportsSelectionUpdate != true
                    || !model.canPerform(.selectProxy(group.name))
            )
            .popover(isPresented: $showingNodePicker, arrowEdge: .trailing) {
                ProxyNodePicker(
                    model: model,
                    group: group,
                    isPresented: $showingNodePicker
                )
            }

            if group.fixedOverride != nil,
               group.groupBehavior?.supportsClearingOverride == true {
                Button {
                    Task { _ = await model.clearProxyOverride(group: group.name) }
                } label: {
                    Image(systemName: "pin.slash")
                }
                .buttonStyle(.borderless)
                .help("Resume automatic selection")
                .accessibilityLabel("Resume automatic selection for \(group.name)")
                .disabled(!model.canPerform(.clearProxyOverride(group.name)))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func historyDelay(_ selected: String) -> Int? {
        guard selected == group.now else { return nil }
        return group.history.last?.delay
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay <= 0 { return .secondary }
        if delay < 150 { return .green }
        if delay < 350 { return .orange }
        return .red
    }
}
