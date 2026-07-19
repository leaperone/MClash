import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Bindable var model: AppModel
    let presentMainWindow: @MainActor (AppModel.Destination) -> Void
    @State private var pickerGroupName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    statusHeader
                    if model.isConnected {
                        liveMetrics
                    }
                    appRoutingStatus
                    profileControl
                    primaryAction

                    if !model.operationalIssues.isEmpty {
                        operationalEvidence
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
        .background {
            MenuBarWindowVisibilityView { isVisible in
                model.setMenuBarContentVisible(isVisible)
            }
        }
        .onAppear { model.setMenuBarContentVisible(true) }
        .onDisappear { model.setMenuBarContentVisible(false) }
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                Text(compactStatusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
    }

    private var operatingState: some View {
        VStack(alignment: .leading, spacing: 7) {
            operationalStateRow(
                title: "Mihomo Core",
                value: coreStatusTitle,
                symbol: coreStatusSymbol,
                color: coreStatusColor
            )
            operationalStateRow(
                title: "System Proxy",
                value: captureStatusTitle,
                symbol: captureStatusSymbol,
                color: captureStatusColor
            )
        }
        .padding(10)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Mihomo Core: \(coreStatusTitle). System Proxy: \(captureStatusTitle)."
        )
    }

    private func operationalStateRow(
        title: String,
        value: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .font(.caption)
    }

    private var liveMetrics: some View {
        HStack(alignment: .top, spacing: 8) {
            metricLabel(
                title: "Download",
                value: liveTrafficValue(model.traffic.download),
                symbol: "arrow.down",
                color: .blue
            )
            metricLabel(
                title: "Upload",
                value: liveTrafficValue(model.traffic.upload),
                symbol: "arrow.up",
                color: .purple
            )
            metricLabel(
                title: "Connections",
                value: liveConnectionCount,
                symbol: "arrow.left.arrow.right",
                color: .secondary
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Download \(liveTrafficValue(model.traffic.download)), "
                + "upload \(liveTrafficValue(model.traffic.upload)), "
                + "connections \(liveConnectionCount)"
        )
    }

    private func metricLabel(
        title: String,
        value: String,
        symbol: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(value == "Stale" ? Color.orange : Color.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var appRoutingStatus: some View {
        Button {
            showMainWindow(destination: .appRouting)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: appRoutingStatusSymbol)
                    .foregroundStyle(appRoutingStatusColor)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text("App Routing")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(appRoutingRuleSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text(appRoutingStatusTitle)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(appRoutingStatusColor)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(appRoutingStatusHelp)
        .accessibilityLabel(
            "App Routing, \(appRoutingStatusTitle), \(appRoutingRuleSummary)"
        )
    }

    @ViewBuilder
    private var operationalEvidence: some View {
        if !model.operationalIssues.isEmpty {
            Button {
                showMainWindow(destination: .attention)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(attentionColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attentionTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(model.operationalIssues[0].consequence)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(attentionTitle). \(model.operationalIssues[0].consequence)"
            )
        } else {
            Button {
                showMainWindow(destination: .connections)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: evidenceSymbol)
                        .foregroundStyle(evidenceColor)
                    Text(evidenceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(evidenceTitle)
        }
    }

    private var managementLinks: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Open")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Grid(horizontalSpacing: 7, verticalSpacing: 7) {
                GridRow {
                    destinationButton(.overview)
                    destinationButton(.connections)
                }
                GridRow {
                    destinationButton(.appRouting)
                    destinationButton(.attention)
                }
            }
        }
    }

    private func destinationButton(_ destination: AppModel.Destination) -> some View {
        Button {
            showMainWindow(destination: destination)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: destination.symbol)
                    .frame(width: 13)
                Text(destination.title)
                    .lineLimit(1)
                if destination == .attention, !model.operationalIssues.isEmpty {
                    Spacer(minLength: 2)
                    Text(formattedCount(model.operationalIssues.count))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.16), in: Capsule())
                } else {
                    Spacer(minLength: 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
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

            if !model.localListenerEndpoints.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Local Proxy")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(model.localListenerEndpoints) { endpoint in
                        CopyableValueButton(
                            value: endpoint.address,
                            accessibilityName: "\(endpoint.kind.presentationTitle) proxy address",
                            title: endpoint.kind.presentationTitle,
                            systemImage: endpoint.kind.presentationSystemImage,
                            font: .caption,
                            usesSecondaryStyle: true
                        )
                        .help(
                            "Copy \(endpoint.kind.presentationTitle) proxy address · "
                                + endpoint.source.presentationTitle
                        )
                    }
                }
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
        guard let message = model.errorMessage else { return nil }
        let duplicatesOperationalIssue = model.operationalIssues.contains {
            $0.technicalDetail == message || $0.consequence == message
        }
        return duplicatesOperationalIssue ? nil : message
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
        model.operationalSnapshot.title
    }

    private var statusSubtitle: String {
        model.operationalSnapshot.detail
    }

    private var statusSymbol: String {
        switch model.operationalSnapshot.level {
        case .active: "checkmark.shield.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .transitioning: "arrow.triangle.2.circlepath"
        case .localOnly: "network"
        case .disconnected: "pause.circle.fill"
        }
    }

    private var statusColor: Color {
        switch model.operationalSnapshot.level {
        case .active: .green
        case .attention: model.operationalIssues.first?.severity == .error ? .red : .orange
        case .transitioning: .orange
        case .localOnly, .disconnected: .secondary
        }
    }

    private var coreStatusTitle: String {
        switch model.coreState {
        case .running: model.controllerIsReady ? "Running" : "Running · Controls unavailable"
        case .validating: "Validating"
        case .starting: "Starting"
        case .stopping: "Stopping"
        case .stopped: "Off"
        case .failed: "Failed"
        }
    }

    private var coreStatusSymbol: String {
        switch model.coreState {
        case .running: model.controllerIsReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        case .validating, .starting, .stopping: "arrow.clockwise"
        case .stopped: "circle"
        case .failed: "xmark.circle.fill"
        }
    }

    private var coreStatusColor: Color {
        switch model.coreState {
        case .running: model.controllerIsReady ? .green : .orange
        case .validating, .starting, .stopping: .orange
        case .stopped: .secondary
        case .failed: .red
        }
    }

    private var captureStatusTitle: String {
        switch model.systemProxyState {
        case .on:
            if model.systemProxyGuardFailure != nil { return "On · unverified" }
            if !model.systemProxyPreferences.guardEnabled { return "On · guard paused" }
            return "On"
        case .enabling: return "Turning on…"
        case .disabling: return "Restoring…"
        case .failed: return "Unavailable"
        case .off: return model.isConnected ? "Off · listeners only" : "Off"
        }
    }

    private var captureStatusSymbol: String {
        switch model.systemProxyState {
        case .on:
            if model.systemProxyGuardFailure != nil {
                return "exclamationmark.circle.fill"
            }
            return model.systemProxyPreferences.guardEnabled
                ? "checkmark.circle.fill"
                : "pause.circle.fill"
        case .enabling, .disabling: return "arrow.clockwise"
        case .failed: return "exclamationmark.triangle.fill"
        case .off: return "circle"
        }
    }

    private var captureStatusColor: Color {
        switch model.systemProxyState {
        case .on:
            return model.systemProxyGuardFailure == nil
                && model.systemProxyPreferences.guardEnabled ? .green : .orange
        case .enabling, .disabling: return .orange
        case .failed: return .red
        case .off: return .secondary
        }
    }

    private var systemProxyCaptureIsOn: Bool {
        if case .on = model.systemProxyState { return true }
        return false
    }

    private var appRoutingCaptureIsOn: Bool {
        if case .on = model.networkCaptureState { return true }
        return false
    }

    private func liveTrafficValue(_ value: Int64) -> String {
        guard model.isConnected else { return "—" }
        switch model.liveStreamHealth[.traffic]?.phase ?? .inactive {
        case .live: return formattedByteRate(value)
        case .connecting: return "Waiting"
        case .reconnecting, .stale: return "Stale"
        case .inactive: return "Unavailable"
        }
    }

    private var liveConnectionCount: String {
        guard model.isConnected else { return "—" }
        switch model.liveStreamHealth[.connections]?.phase ?? .inactive {
        case .live: return formattedCount(model.connections?.connections.count ?? 0)
        case .connecting: return "Waiting"
        case .reconnecting, .stale: return "Stale"
        case .inactive: return "Unavailable"
        }
    }

    private var enabledAppRoutingRuleCount: Int {
        model.networkCapturePreferences.snapshot.rules.lazy.filter(\.enabled).count
    }

    private var appRoutingRuleSummary: String {
        "\(formattedCount(enabledAppRoutingRuleCount)) enabled "
            + (enabledAppRoutingRuleCount == 1 ? "rule" : "rules")
    }

    private var appRoutingStatusTitle: String {
        switch model.networkCaptureState {
        case .off: return "Off"
        case .waitingForConnection: return "Waiting for Core"
        case .enabling: return "Starting"
        case .awaitingUserApproval: return "Needs Approval"
        case .on:
            if model.appRoutingProviderStatusFailureCount > 0 {
                return "Verification retrying"
            }
            return model.appRoutingProviderLastVerifiedAt == nil ? "Verifying" : "Running"
        case .disabling: return "Stopping"
        case .requiresReboot: return "Restart Required"
        case .failed: return "Failed"
        }
    }

    private var appRoutingStatusSymbol: String {
        switch model.networkCaptureState {
        case .on:
            return appRoutingProviderIsVerified
                ? "checkmark.circle.fill"
                : "exclamationmark.circle.fill"
        case .enabling, .disabling, .waitingForConnection: return "arrow.clockwise"
        case .awaitingUserApproval, .requiresReboot: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .off: return "circle"
        }
    }

    private var appRoutingStatusColor: Color {
        switch model.networkCaptureState {
        case .on:
            return appRoutingProviderIsVerified ? .green : .orange
        case .enabling, .disabling, .waitingForConnection, .awaitingUserApproval, .requiresReboot:
            return .orange
        case .failed: return .red
        case .off: return .secondary
        }
    }

    private var appRoutingStatusHelp: String {
        switch model.networkCaptureState {
        case .on where appRoutingProviderIsVerified:
            let verifiedAt = model.appRoutingProviderLastVerifiedAt?.formatted(
                .relative(presentation: .named)
            ) ?? "recently"
            return "The provider runtime was verified \(verifiedAt). "
                + "\(enabledAppRoutingRuleCount) enabled "
                + (enabledAppRoutingRuleCount == 1 ? "rule." : "rules.")
        case .on:
            if model.appRoutingProviderStatusFailureCount > 0 {
                return "The provider runtime check is retrying. Open App Routing for details."
            }
            return "The provider runtime is being verified."
        case .off:
            return "App Routing is off. Saved rules are not intercepting traffic."
        default:
            return "Open App Routing for provider status and recovery actions."
        }
    }

    private var appRoutingProviderIsVerified: Bool {
        model.appRoutingProviderStatusFailureCount == 0
            && model.appRoutingProviderLastVerifiedAt != nil
    }

    private var attentionTitle: String {
        "\(formattedCount(model.operationalIssues.count)) "
            + (model.operationalIssues.count == 1 ? "item needs attention" : "items need attention")
    }

    private var attentionColor: Color {
        model.operationalIssues.first?.severity == .error ? .red : .orange
    }

    private var evidenceTitle: String {
        if let date = model.operationalSnapshot.latestNonDirectRouteAt {
            return "Mihomo reported a non-direct route \(date.formatted(.relative(presentation: .named)))"
        }
        if model.operationalSnapshot.activeCaptureCount > 0 {
            return "Capture is on; no non-direct Mihomo route reported yet"
        }
        if model.isConnected {
            return "Core is ready; macOS traffic capture is off"
        }
        return "Traffic capture is off"
    }

    private var evidenceSymbol: String {
        model.operationalSnapshot.latestNonDirectRouteAt == nil
            ? "eye.slash"
            : "checkmark.shield.fill"
    }

    private var evidenceColor: Color {
        model.operationalSnapshot.latestNonDirectRouteAt == nil ? .secondary : .green
    }

    private func showMainWindow(destination: AppModel.Destination) {
        presentMainWindow(destination)
    }

    private var popoverHeight: CGFloat {
        if !model.operationalIssues.isEmpty || issueMessage != nil { return 440 }
        return model.isConnected ? 400 : 340
    }

    private var compactStatusSubtitle: String {
        if let profile = model.activeProfile?.name {
            return profile
        }
        return "Choose a profile to connect"
    }
}

/// `MenuBarExtra` may retain its SwiftUI root after ordering the panel out, so
/// `onDisappear` alone is not a sufficient presentation-demand signal. Track
/// the actual AppKit panel's key-window lifecycle to stop quick-metric streams
/// whenever the menu closes.
private struct MenuBarWindowVisibilityView: NSViewRepresentable {
    let visibilityDidChange: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        resolveWindow(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        resolveWindow(from: nsView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    private func resolveWindow(from view: NSView, coordinator: Coordinator) {
        coordinator.visibilityDidChange = visibilityDidChange
        guard !coordinator.resolutionIsPending else { return }
        coordinator.resolutionIsPending = true
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let coordinator else { return }
            coordinator.resolutionIsPending = false
            guard let window = view?.window else { return }
            coordinator.observe(window)
        }
    }

    @MainActor
    final class Coordinator {
        var visibilityDidChange: (@MainActor (Bool) -> Void)?
        var resolutionIsPending = false
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        func observe(_ window: NSWindow) {
            guard self.window !== window else { return }
            stopObserving()
            self.window = window
            let center = NotificationCenter.default
            observers.append(
                center.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.visibilityDidChange?(true) }
                }
            )
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(
                    center.addObserver(forName: name, object: window, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated { self?.visibilityDidChange?(false) }
                    }
                )
            }
            visibilityDidChange?(window.isVisible && window.isKeyWindow)
        }

        func stopObserving() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
            visibilityDidChange?(false)
            window = nil
        }
    }
}
