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
        .frame(width: 360, height: 440)
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
