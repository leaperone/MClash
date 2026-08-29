import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @Bindable var applicationUpdater: ApplicationUpdater
    @AppStorage("mclash.navigation.destination") private var restoredDestinationRawValue =
        AppModel.Destination.overview.rawValue
    @AppStorage("mclash.navigation.advancedExpanded") private var advancedExpanded = false
    @State private var hasRestoredDestination = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section {
                    destinationRow(.overview)
                }

                Section("Configure") {
                    destinationRow(.workspaces)
                    destinationRow(.nodes)
                    destinationRow(.sources)
                    destinationRow(.entrances)
                    destinationRow(.proxies)
                    appRoutingToggleRow
                }

                Section("Monitor") {
                    destinationRow(.connections)
                    destinationRow(.attention)
                }

                Section {
                DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                        destinationRow(.profiles)
                        destinationRow(.rules)
                        destinationRow(.providers)
                        destinationRow(.logs)
                    }
                }

                Section {
                    destinationRow(.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 176, ideal: 206, max: 240)
            .navigationTitle("MClash")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarOperationalStatus(model: model)
            }
        } detail: {
            GeometryReader { geometry in
                // Keep every destination inside the finite detail-column size.
                // Wide Tables must not feed their intrinsic width back into
                // NavigationSplitView and displace or blank the sidebar.
                destinationView
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let errorMessage = activeErrorMessage {
                            ErrorBanner(
                                message: errorMessage,
                                retryNetworkRestore: model.systemProxyRecoveryRequired ? {
                                    Task { await model.disableSystemProxy() }
                                } : nil,
                                isRestoringNetwork: model.isPerforming(.changeSystemProxy),
                                showLogs: {
                                    model.selection = .logs
                                    if !model.systemProxyRecoveryRequired {
                                        model.errorMessage = nil
                                    }
                                },
                                dismiss: model.systemProxyRecoveryRequired
                                    ? nil
                                    : { model.errorMessage = nil }
                            )
                            .frame(maxWidth: 720)
                            .padding(.horizontal, MClashLayout.pagePadding)
                            .padding(.vertical, 8)
                        }
                    }
            }
            .mclashPageSurface()
        }
        .onAppear {
            restoreDestination()
        }
        .onChange(of: model.selection) { _, destination in
            guard let destination else { return }
            restoredDestinationRawValue = destination.rawValue
            if advancedDestinations.contains(destination) {
                advancedExpanded = true
            }
        }
        .alert(
            AppLocalization.string("Add Source?"),
            isPresented: pendingSubscriptionImportIsPresented,
            presenting: model.pendingSubscriptionImport
        ) { request in
            Button("Cancel", role: .cancel) {
                model.cancelPendingSubscriptionImport()
            }
            Button(AppLocalization.string("Import Source")) {
                Task { await model.confirmPendingSubscriptionImport(request) }
            }
        } message: { request in
            Text(
                AppLocalization.format(
                    "Download a source from %@? Only node connection data is imported. Source proxy groups, rules, DNS and TUN settings are ignored.",
                    request.displayHost
                )
            )
        }
    }

    private func destinationRow(_ destination: AppModel.Destination) -> some View {
        HStack(spacing: 8) {
            Label(AppLocalization.string(destination.title), systemImage: destination.symbol)
            Spacer(minLength: 4)
            destinationAccessory(destination)
        }
        .tag(destination)
    }

    private var activeErrorMessage: String? {
        if case let .failed(message) = model.systemProxyState {
            return message
        }
        return model.errorMessage
    }

    private var pendingSubscriptionImportIsPresented: Binding<Bool> {
        Binding(
            get: { model.pendingSubscriptionImport != nil },
            // Alert actions own the pending request. Keeping the setter inert
            // prevents SwiftUI's automatic dismissal from racing the async
            // confirmation action before it consumes the request.
            set: { _ in }
        )
    }

    private func restoreDestination() {
        guard !hasRestoredDestination else { return }
        hasRestoredDestination = true

        if let currentDestination = model.selection, currentDestination != .overview {
            restoredDestinationRawValue = currentDestination.rawValue
            return
        }

        let destination = AppModel.Destination(rawValue: restoredDestinationRawValue) ?? .overview
        if advancedDestinations.contains(destination) {
            advancedExpanded = true
        }
        if restoredDestinationRawValue != destination.rawValue {
            restoredDestinationRawValue = destination.rawValue
        }
        if model.selection != destination {
            model.selection = destination
        }
    }

    private var advancedDestinations: Set<AppModel.Destination> {
        [.profiles, .rules, .providers, .logs]
    }

    @ViewBuilder
    private var destinationView: some View {
        switch model.selection ?? .overview {
        case .overview:
            OverviewView(model: model)
        case .workspaces:
            ConfigurationWorkspacesView(model: model)
        case .nodes:
            ConfigurationNodesView(model: model)
        case .sources:
            ConfigurationSourcesView(model: model)
        case .entrances:
            ConfigurationEntrancesView(model: model)
        case .proxies:
            ConfigurationProxyGroupsView(model: model)
        case .appRouting:
            ConnectionsView(model: model)
        case .profiles:
            ProfilesView(model: model)
        case .rules:
            ConfigurationRulesView(model: model)
        case .providers:
            ProvidersView(model: model)
        case .connections:
            ConnectionsView(model: model)
        case .attention:
            AttentionView(model: model)
        case .logs:
            LogsView(model: model)
        case .settings:
            SettingsView(model: model, applicationUpdater: applicationUpdater)
        }
    }

    @ViewBuilder
    private func destinationAccessory(_ destination: AppModel.Destination) -> some View {
        switch destination {
        case .attention where !model.operationalIssues.isEmpty:
            Text(AppLocalization.number(model.operationalIssues.count))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.red, in: Capsule())
                .accessibilityLabel(
                    AppLocalization.format(
                        model.operationalIssues.count == 1
                            ? "%@ item needs attention"
                            : "%@ items need attention",
                        AppLocalization.number(model.operationalIssues.count)
                    )
                )
        case .connections where model.isConnected:
            Text(sidebarConnectionValue)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(sidebarConnectionAccessibilityLabel)
        case .appRouting:
            Circle()
                .fill(appRoutingAccessoryColor)
                .frame(width: 7, height: 7)
                .accessibilityLabel(appRoutingAccessoryLabel)
        default:
            EmptyView()
        }
    }

    private var appRoutingToggleRow: some View {
        Toggle(isOn: appRoutingEnabled) {
            Label(AppLocalization.string("App Routing"), systemImage: "app.badge")
        }
        .toggleStyle(.switch)
        .disabled(
            model.pendingNetworkCaptureEnabled != nil
                || !model.canPerform(.changeNetworkCapture)
        )
        .help(AppLocalization.string(model.unifiedConfigurationEnabled
            ? "Capture application traffic using the unified MClash rules"
            : "Legacy application capture is active until a MClash Workspace is selected"))
        .accessibilityLabel(AppLocalization.string(model.unifiedConfigurationEnabled
            ? "App Routing using unified MClash rules"
            : "App Routing using legacy profile rules"))
    }

    private var appRoutingEnabled: Binding<Bool> {
        Binding(
            get: { model.appRoutingCapabilityEnabled },
            set: { value in Task { await model.setNetworkCaptureEnabled(value) } }
        )
    }

    private var sidebarConnectionValue: String {
        switch model.liveStreamHealth[.connections]?.phase ?? .inactive {
        case .live: AppLocalization.number(model.connections?.connections.count ?? 0)
        case .connecting: "…"
        case .reconnecting, .stale, .inactive: "—"
        }
    }

    private var sidebarConnectionAccessibilityLabel: String {
        switch model.liveStreamHealth[.connections]?.phase ?? .inactive {
        case .live:
            let count = model.connections?.connections.count ?? 0
            return AppLocalization.format(
                count == 1 ? "%@ active connection" : "%@ active connections",
                AppLocalization.number(count)
            )
        case .connecting:
            return AppLocalization.string("Waiting for active connections")
        case .reconnecting, .stale:
            return AppLocalization.string("Active connection count is stale")
        case .inactive:
            return AppLocalization.string("Active connection count is unavailable")
        }
    }

    private var appRoutingAccessoryColor: Color {
        switch model.networkCaptureState {
        case .on: .green
        case .failed: .red
        case .awaitingUserApproval, .requiresReboot: .orange
        case .enabling, .disabling: .accentColor
        case .off, .waitingForConnection: .secondary.opacity(0.5)
        }
    }

    private var appRoutingAccessoryLabel: String {
        let statusKey = switch model.networkCaptureState {
        case .on: "Active"
        case .failed: "Failed"
        case .awaitingUserApproval: "Needs Approval"
        case .requiresReboot: "Restart Required"
        case .enabling: "Starting"
        case .disabling: "Stopping"
        case .waitingForConnection: "Waiting"
        case .off: "Off"
        }
        return AppLocalization.format(
            "%@, %@",
            AppLocalization.string("App Routing"),
            AppLocalization.string(statusKey)
        )
    }
}

private struct SidebarOperationalStatus: View {
    @Bindable var model: AppModel

    var body: some View {
        let snapshot = model.operationalSnapshot

        Group {
            if model.operationalIssues.isEmpty {
                statusContent(snapshot)
            } else {
                Button {
                    model.selection = .attention
                } label: {
                    statusContent(snapshot)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(AppLocalization.string("Review issues"))
                .accessibilityHint(AppLocalization.string("Opens recovery actions"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .help(snapshot.detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            AppLocalization.format("%@, %@", snapshot.title, snapshot.captureSummary)
        )
    }

    private func statusContent(_ snapshot: OperationalSnapshot) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(statusColor(for: snapshot.level))
                .frame(width: 9, height: 9)
                .padding(.top, 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(snapshot.captureSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusColor(for level: OperationalSnapshot.Level) -> Color {
        switch level {
        case .active: .green
        case .transitioning: .accentColor
        case .attention: .orange
        case .localOnly: .yellow
        case .disconnected: .secondary
        }
    }
}

private struct ErrorBanner: View {
    let message: String
    let retryNetworkRestore: (() -> Void)?
    let isRestoringNetwork: Bool
    let showLogs: () -> Void
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            Text(message)
                .font(.callout)
                .lineLimit(2)
                .help(message)

            Spacer(minLength: 12)

            if let retryNetworkRestore {
                Button(action: retryNetworkRestore) {
                    if isRestoringNetwork {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Restoring…")
                        }
                    } else {
                        Text("Try Restore Again")
                    }
                }
                .disabled(isRestoringNetwork)
            }
            Button("View Logs", action: showLogs)
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(AppLocalization.string("Dismiss"))
                .accessibilityLabel(AppLocalization.string("Dismiss error"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("MClash could not complete the operation"))
    }
}
