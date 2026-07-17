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
                    destinationRow(.logs)
                }

                Section("Application") {
                    destinationRow(.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 176, ideal: 206, max: 240)
            .navigationTitle("MClash")
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
        Label(destination.title, systemImage: destination.symbol)
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
        case .logs:
            LogsView(model: model)
        case .settings:
            SettingsView(model: model, applicationUpdater: applicationUpdater)
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
