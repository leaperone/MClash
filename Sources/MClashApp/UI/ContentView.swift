import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @Bindable var applicationUpdater: ApplicationUpdater
    @AppStorage("mclash.navigation.destination") private var restoredDestinationRawValue =
        AppModel.Destination.overview.rawValue
    @State private var hasRestoredDestination = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Status") {
                    destinationRow(.overview)
                    destinationRow(.connections)
                }

                Section("Routing") {
                    destinationRow(.proxies)
                    destinationRow(.appRouting)
                    destinationRow(.profiles)
                    destinationRow(.rules)
                    destinationRow(.providers)
                }

                Section("Diagnostics") {
                    destinationRow(.attention)
                    destinationRow(.logs)
                }

                Section("Application") {
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
            VStack(spacing: 0) {
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
                    .transition(errorTransition)
                }
                // Keep the detail column's view graph stable while switching
                // between structurally different destinations. NavigationSplitView
                // can otherwise fail to refresh conditional column content on macOS.
                ZStack {
                    destinationView
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
        }
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.14)
                : .spring(response: 0.3, dampingFraction: 1),
            value: activeErrorMessage
        )
        .alert(
            "Import Subscription?",
            isPresented: pendingSubscriptionImportIsPresented,
            presenting: model.pendingSubscriptionImport
        ) { request in
            Button("Cancel", role: .cancel) {
                model.cancelPendingSubscriptionImport()
            }
            Button("Import") {
                Task { await model.confirmPendingSubscriptionImport(request) }
            }
        } message: { request in
            Text(
                "Download a subscription from \(request.displayHost)? "
                    + "It will be added to Profiles without changing your active route."
            )
        }
    }

    private func destinationRow(_ destination: AppModel.Destination) -> some View {
        HStack(spacing: 8) {
            Label(destination.title, systemImage: destination.symbol)
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

    private var errorTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .offset(y: -8).combined(with: .opacity),
            removal: .opacity
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
        if restoredDestinationRawValue != destination.rawValue {
            restoredDestinationRawValue = destination.rawValue
        }
        if model.selection != destination {
            model.selection = destination
        }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch model.selection ?? .overview {
        case .overview:
            OverviewView(model: model)
        case .proxies:
            ProxiesView(model: model)
                .id(model.activeProfileID)
        case .appRouting:
            AppRoutingView(model: model)
        case .profiles:
            ProfilesView(model: model)
        case .rules:
            RulesView(model: model)
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
            Text(formattedCount(model.operationalIssues.count))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.red, in: Capsule())
                .accessibilityLabel("\(model.operationalIssues.count) items need attention")
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

    private var sidebarConnectionValue: String {
        switch model.liveStreamHealth[.connections]?.phase ?? .inactive {
        case .live: formattedCount(model.connections?.connections.count ?? 0)
        case .connecting: "…"
        case .reconnecting, .stale, .inactive: "—"
        }
    }

    private var sidebarConnectionAccessibilityLabel: String {
        switch model.liveStreamHealth[.connections]?.phase ?? .inactive {
        case .live: "\(model.connections?.connections.count ?? 0) active connections"
        case .connecting: "Waiting for active connections"
        case .reconnecting, .stale: "Active connection count is stale"
        case .inactive: "Active connection count is unavailable"
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
        switch model.networkCaptureState {
        case .on: "App Routing on"
        case .failed: "App Routing failed"
        case .awaitingUserApproval: "App Routing needs approval"
        case .requiresReboot: "App Routing requires restart"
        case .enabling: "App Routing starting"
        case .disabling: "App Routing stopping"
        case .waitingForConnection: "App Routing waiting for connection"
        case .off: "App Routing off"
        }
    }
}

private struct SidebarOperationalStatus: View {
    @Bindable var model: AppModel

    var body: some View {
        let snapshot = model.operationalSnapshot

        Button {
            model.selection = model.operationalIssues.isEmpty ? .overview : .attention
        } label: {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .help(snapshot.detail)
        .accessibilityLabel(
            "\(snapshot.title), \(snapshot.captureSummary)"
        )
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
                .help("Dismiss")
                .accessibilityLabel("Dismiss error")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MClash could not complete the operation")
    }
}
