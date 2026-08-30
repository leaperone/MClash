import AppKit
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

                Section(AppLocalization.string("Configure")) {
                    destinationRow(.workspaces, title: "Configuration")
                    destinationRow(.rules, title: "Rules")
                    destinationRow(.nodes)
                    destinationRow(.sources)
                    destinationRow(.entrances)
                    destinationRow(.proxyGroups, title: "Groups")
                }

                Section(AppLocalization.string("Monitor")) {
                    destinationRow(.connections)
                    destinationRow(.attention)
                }

                Section {
                    DisclosureGroup(AppLocalization.string("Advanced"), isExpanded: $advancedExpanded) {
                        destinationRow(.profiles)
                        destinationRow(.providers)
                        destinationRow(.logs)
                    }
                }

                Section {
                    destinationRow(.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 224, max: 260)
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

    private func destinationRow(_ destination: AppModel.Destination, title: String? = nil) -> some View {
        HStack(spacing: 8) {
            Label(AppLocalization.string(title ?? destination.title), systemImage: destination.symbol)
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

        var destination = AppModel.Destination(rawValue: restoredDestinationRawValue) ?? .overview
        if destination == .appRouting {
            destination = .entrances
            restoredDestinationRawValue = destination.rawValue
        }
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
        [.profiles, .providers, .logs]
    }

    @ViewBuilder
    private var destinationView: some View {
        switch model.selection ?? .overview {
        case .overview:
            OverviewView(model: model)
        case .workspaces:
            ConfigurationView(model: model)
        case .nodes:
            ConfigurationNodesView(model: model)
        case .sources:
            ConfigurationSourcesView(model: model)
        case .entrances:
            ConfigurationEntrancesView(model: model)
        case .proxies:
            // Legacy deep link retained for compatibility; the visible
            // navigation uses the strategy-owned Groups destination.
            ConfigurationProxyGroupsView(model: model)
        case .proxyGroups:
            ConfigurationProxyGroupsView(model: model)
        case .appRouting:
            ConfigurationEntrancesView(model: model)
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
        default:
            EmptyView()
        }
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
        .onChange(of: message, initial: true) { _, message in
            guard !message.isEmpty else { return }
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        }
    }
}
