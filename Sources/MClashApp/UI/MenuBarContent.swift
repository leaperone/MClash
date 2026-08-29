import AppKit
import SwiftUI

struct MenuBarContent: View {
    @Bindable var model: AppModel
    let presentMainWindow: @MainActor (AppModel.Destination) -> Void
    @State private var pickerGroupName: String?
    @State private var contentIsVisible = false
    @State private var retainedPopoverHeight: CGFloat = 410
    @State private var routingOptionsExpanded = false

    var body: some View {
        Group {
            if contentIsVisible {
                fullContent
            } else {
                Color.clear
            }
        }
        .frame(minWidth: 320, idealWidth: 344, maxWidth: 420)
        .frame(height: contentIsVisible ? popoverHeight : retainedPopoverHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("MClash quick controls"))
        .background {
            MenuBarWindowVisibilityView { isVisible in
                if contentIsVisible, !isVisible {
                    retainedPopoverHeight = popoverHeight
                }
                contentIsVisible = isVisible
                model.setMenuBarContentVisible(isVisible)
            }
        }
        .onDisappear {
            contentIsVisible = false
            model.setMenuBarContentVisible(false)
        }
    }

    private var fullContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    statusHeader

                    if !model.operationalIssues.isEmpty {
                        operationalEvidence
                    }

                    profileControl
                    primaryAction

                    if model.isConnected {
                        liveMetrics
                    }

                    if showsAppRoutingStatus {
                        appRoutingStatus
                    }

                    if model.isConnected {
                        connectedControls
                    }

                    if let issueMessage {
                        inlineError(issueMessage)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: .infinity)

            Divider()

            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        // MenuBarExtra windows cannot infer a useful intrinsic height from ScrollView content.
        // An explicit popover size keeps the entire quick-control surface visible on every launch.
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: statusSymbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 21, height: 21)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.callout.weight(.semibold))
                Text(compactStatusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
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
                color: .orange
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
            Label(AppLocalization.string(title), systemImage: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(
                    value == AppLocalization.string("Stale") ? Color.orange : Color.primary
                )
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
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

                Text(AppLocalization.string(appRoutingStatusTitle))
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
                        Text(model.operationalIssues[0].localizedConsequence)
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
                "\(attentionTitle). \(model.operationalIssues[0].localizedConsequence)"
            )
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
                    Text(AppLocalization.string(connectionButtonTitle))
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
                    Text(model.activeProfile?.name ?? AppLocalization.string("None"))
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
        DisclosureGroup("Routing Options", isExpanded: $routingOptionsExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "macOS System Proxy",
                    isOn: Binding(
                        get: { model.pendingSystemProxyEnabled ?? model.systemProxyEnabled },
                        set: { enabled in Task { await model.setSystemProxyEnabled(enabled) } }
                    )
                )
                .disabled(
                    !model.controllerIsReady
                        || !model.canPerform(.changeSystemProxy)
                        || model.networkCapturePreferences.enabled
                )
                .help(
                    model.networkCapturePreferences.enabled
                        ? "App Routing is active. Turn it off before enabling the mutually exclusive macOS System Proxy."
                        : "Route compatible macOS applications through MClash's local proxy listeners."
                )

                VStack(alignment: .leading, spacing: 5) {
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

                if model.pendingMode != nil || model.pendingSystemProxyEnabled != nil {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text(pendingRoutingTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !quickRouteGroups.isEmpty {
                    quickRoutes
                }

                Button("Manage All Routes…") {
                    showMainWindow(destination: .proxies)
                }
                .controlSize(.small)
            }
            .padding(.top, 8)
        }
        .font(.callout)
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

            Menu {
                ForEach(availableQuickRouteGroups, id: \.name) { group in
                    let isPinned = model.pinnedQuickRouteNames.contains(group.name)
                    Button {
                        model.setQuickRoutePinned(
                            group.name,
                            pinned: !isPinned,
                            availableNames: availableQuickRouteGroups.map(\.name)
                        )
                    } label: {
                        Label(
                            group.name,
                            systemImage: isPinned ? "pin.fill" : "pin"
                        )
                    }
                    .disabled(!isPinned && activePinnedQuickRouteCount >= QuickRouteSelectionPolicy.maximumVisibleRoutes)
                }

                if !model.pinnedQuickRouteNames.isEmpty {
                    Divider()
                    Button("Use Automatic Order") {
                        model.clearPinnedQuickRoutes()
                    }
                }
            } label: {
                Label("Customize Quick Routes", systemImage: "pin")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .help("Pin up to three policy groups; unfilled slots follow profile order.")

        }
    }

    private var quickRouteGroups: [MihomoProxy] {
        let selectedNames = QuickRouteSelectionPolicy.select(
            availableNames: availableQuickRouteGroups.map(\.name),
            pinnedNames: model.pinnedQuickRouteNames
        )
        return selectedNames.compactMap { name in
            availableQuickRouteGroups.first { $0.name == name }
        }
    }

    private var availableQuickRouteGroups: [MihomoProxy] {
        let mode = (model.pendingMode ?? model.runtimeConfig?.mode ?? "rule").lowercased()
        guard mode != "direct" else { return [] }
        return ProxyGroupPartitionSnapshot(model: model, routingMode: mode)
            .orderedForPresentation
    }

    private var activePinnedQuickRouteCount: Int {
        let availableNames = Set(availableQuickRouteGroups.map(\.name))
        return model.pinnedQuickRouteNames.filter(availableNames.contains).count
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
        case .connecting: return AppLocalization.string("Waiting")
        case .reconnecting, .stale: return AppLocalization.string("Stale")
        case .inactive: return AppLocalization.string("Unavailable")
        }
    }

    private var liveConnectionCount: String {
        guard model.isConnected else { return "—" }
        switch model.liveStreamHealth[.connections]?.phase ?? .inactive {
        case .live: return formattedCount(model.connections?.connections.count ?? 0)
        case .connecting: return AppLocalization.string("Waiting")
        case .reconnecting, .stale: return AppLocalization.string("Stale")
        case .inactive: return AppLocalization.string("Unavailable")
        }
    }

    private var enabledAppRoutingRuleCount: Int {
        model.networkCapturePreferences.snapshot.rules.lazy.filter(\.enabled).count
    }

    private var appRoutingRuleSummary: String {
        AppLocalization.format(
            enabledAppRoutingRuleCount == 1
                ? "%d active rule"
                : "%d active rules",
            enabledAppRoutingRuleCount
        )
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
        let count = model.operationalIssues.count
        return AppLocalization.format(
            count == 1 ? "%@ item needs attention" : "%@ items need attention",
            formattedCount(count)
        )
    }

    private var attentionColor: Color {
        model.operationalIssues.first?.severity == .error ? .red : .orange
    }

    private func showMainWindow(destination: AppModel.Destination) {
        presentMainWindow(destination)
    }

    private var popoverHeight: CGFloat {
        if !model.operationalIssues.isEmpty || issueMessage != nil { return 520 }
        return model.isConnected ? 460 : 360
    }

    private var showsAppRoutingStatus: Bool {
        switch model.networkCaptureState {
        case .off:
            model.networkCapturePreferences.enabled
                || model.dnsProxyRuntimeError != nil
                || model.dnsProxyAutomaticallyDisabled
        case .waitingForConnection, .enabling, .awaitingUserApproval, .on,
             .disabling, .requiresReboot, .failed:
            true
        }
    }

    private var compactStatusSubtitle: String {
        if let profile = model.activeProfile?.name {
            return profile
        }
        return AppLocalization.string("Choose a profile to connect")
    }
}

/// `MenuBarExtra` may retain its SwiftUI root after ordering the panel out, so
/// `onDisappear` alone is not a sufficient presentation-demand signal. Track
/// the actual AppKit panel visibility to stop quick-metric streams whenever
/// the menu closes. Key-window changes are insufficient because a child
/// popover can temporarily take focus while the panel remains visible.
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
        private var visibilityObservation: NSKeyValueObservation?

        func observe(_ window: NSWindow) {
            guard self.window !== window else { return }
            stopObserving()
            self.window = window
            visibilityObservation = window.observe(
                \.isVisible,
                options: [.initial, .new]
            ) { [weak self] window, _ in
                MainActor.assumeIsolated {
                    self?.visibilityDidChange?(window.isVisible)
                }
            }
        }

        func stopObserving() {
            visibilityObservation?.invalidate()
            visibilityObservation = nil
            visibilityDidChange?(false)
            window = nil
        }
    }
}
