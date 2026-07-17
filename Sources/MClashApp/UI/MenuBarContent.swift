import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var pickerGroupName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusHeader
                    if model.isConnected {
                        liveMetrics
                    }
                    primaryAction

                    Divider()

                    profileControl

                    if model.isConnected {
                        connectedControls
                    }

                    if let issueMessage {
                        inlineError(issueMessage)
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
        .frame(width: 360, height: popoverHeight)
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
        }
    }

    private var liveMetrics: some View {
        HStack(spacing: 14) {
            metricLabel(
                formattedByteRate(model.traffic.download),
                symbol: "arrow.down",
                color: .blue
            )
            metricLabel(
                formattedByteRate(model.traffic.upload),
                symbol: "arrow.up",
                color: .purple
            )
            Spacer(minLength: 4)
            metricLabel(
                formattedCount(model.connections?.connections.count ?? 0),
                symbol: "arrow.left.arrow.right",
                color: .secondary
            )
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Download \(formattedByteRate(model.traffic.download)), upload \(formattedByteRate(model.traffic.upload)), "
                + "\(formattedCount(model.connections?.connections.count ?? 0)) active connections"
        )
    }

    private func metricLabel(_ value: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(value)
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
                "macOS System Proxy",
                isOn: Binding(
                    get: { model.pendingSystemProxyEnabled ?? model.systemProxyEnabled },
                    set: { enabled in Task { await model.setSystemProxyEnabled(enabled) } }
                )
            )
            .disabled(!model.controllerIsReady || !model.canPerform(.changeSystemProxy))

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

                if model.pendingMode != nil || model.pendingSystemProxyEnabled != nil {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(pendingRoutingTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !quickRouteGroups.isEmpty {
                quickRoutes
            }

            if model.controllerState == .loading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading proxy controls…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !model.systemProxyEnabled, model.controllerIsReady {
                Label(
                    "Enable System Proxy to route macOS apps through MClash.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func inlineError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label {
                Text(message)
                    .lineLimit(3)
                    .help(message)
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
                    if !model.systemProxyRecoveryRequired {
                        model.errorMessage = nil
                    }
                    showMainWindow(destination: .logs)
                }
                if !model.systemProxyRecoveryRequired, model.errorMessage != nil {
                    Button("Dismiss") { model.errorMessage = nil }
                }
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

            Button("Settings…") {
                showMainWindow(destination: .settings)
            }

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var modeBinding: Binding<String> {
        Binding(
            get: { model.pendingMode ?? model.runtimeConfig?.mode ?? "rule" },
            set: { mode in Task { await model.setMode(mode) } }
        )
    }

    private var quickRoutes: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Quick Routes")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(quickRouteGroups, id: \.name) { group in
                Button {
                    pickerGroupName = group.name
                } label: {
                    HStack(spacing: 8) {
                        Text(group.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if model.pendingProxySelections[group.name] != nil {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(group.fixedOverride ?? group.now ?? "Choose…")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .popover(isPresented: pickerBinding(for: group.name), arrowEdge: .trailing) {
                    ProxyNodePicker(
                        model: model,
                        group: group,
                        isPresented: pickerBinding(for: group.name)
                    )
                }
            }

            Button("Manage All Routes…") {
                showMainWindow(destination: .proxies)
            }
            .controlSize(.small)
        }
    }

    private var quickRouteGroups: [MihomoProxy] {
        let mode = (model.pendingMode ?? model.runtimeConfig?.mode ?? "rule").lowercased()
        guard mode != "direct" else { return [] }
        return Array(
            ProxyGroupPartitionSnapshot(model: model, routingMode: mode)
                .orderedForPresentation
                .prefix(3)
        )
    }

    private func pickerBinding(for groupName: String) -> Binding<Bool> {
        Binding(
            get: { pickerGroupName == groupName },
            set: { isPresented in
                pickerGroupName = isPresented ? groupName : nil
            }
        )
    }

    private var pendingRoutingTitle: String {
        if let mode = model.pendingMode {
            return "Switching to \(mode.capitalized)…"
        }
        if let enabled = model.pendingSystemProxyEnabled {
            return enabled ? "Turning on System Proxy…" : "Turning off System Proxy…"
        }
        return "Applying routing change…"
    }

    private var issueMessage: String? {
        if case let .failed(message) = model.systemProxyState { return message }
        if let message = model.errorMessage { return message }
        if case let .degraded(message) = model.controllerState { return message }
        return nil
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
        if model.preparationInProgress {
            return "Preparing MClash"
        }
        switch model.coreState {
        case .running:
            switch model.controllerState {
            case .ready: return model.systemProxyEnabled ? "Connected" : "Core Running"
            case .loading: return "Preparing Controls"
            case .degraded: return "Connected with an Issue"
            case .idle: return "Connected"
            }
        default:
            return model.statusTitle
        }
    }

    private var statusSubtitle: String {
        if model.preparationInProgress {
            return "Checking profiles and network state"
        }
        if let profile = model.activeProfile {
            return model.isConnected && !model.systemProxyEnabled
                ? "\(profile.name) · System Proxy off"
                : profile.name
        }
        return "No active profile"
    }

    private var statusSymbol: String {
        if model.preparationInProgress { return "arrow.triangle.2.circlepath" }
        switch model.coreState {
        case .running:
            if model.controllerIsReady, model.systemProxyEnabled {
                return "checkmark.shield.fill"
            } else if model.controllerIsReady {
                return "network"
            } else {
                return "ellipsis.circle.fill"
            }
        case .failed:
            return "exclamationmark.triangle.fill"
        case .validating, .starting, .stopping:
            return "arrow.triangle.2.circlepath"
        case .stopped:
            return "pause.circle.fill"
        }
    }

    private var statusColor: Color {
        if model.preparationInProgress { return .orange }
        switch model.coreState {
        case .running:
            return model.controllerIsReady
                ? (model.systemProxyEnabled ? .green : .secondary)
                : .orange
        case .failed:
            return .red
        case .validating, .starting, .stopping:
            return .orange
        case .stopped:
            return .secondary
        }
    }

    private func showMainWindow(destination: AppModel.Destination) {
        model.selection = destination
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var popoverHeight: CGFloat {
        if issueMessage != nil { return 440 }
        if !quickRouteGroups.isEmpty { return 440 }
        return model.isConnected ? 340 : 280
    }
}
