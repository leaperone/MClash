import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Status") {
                    destinationRow(.overview)
                    destinationRow(.connections)
                }

                Section("Routing") {
                    destinationRow(.proxies)
                    destinationRow(.profiles)
                    destinationRow(.rules)
                    destinationRow(.providers)
                }

                Section("Diagnostics") {
                    destinationRow(.logs)
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
                    .transition(.opacity)
                }
                destinationView
            }
            .mclashPageSurface()
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

    @ViewBuilder
    private var destinationView: some View {
        switch model.selection ?? .overview {
        case .overview:
            OverviewView(model: model)
        case .proxies:
            ProxiesView(model: model)
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
