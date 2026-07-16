import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppModel.Destination.allCases, selection: $model.selection) { destination in
                Label(destination.title, systemImage: destination.symbol)
                    .tag(destination)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
        } detail: {
            destinationView
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let errorMessage = model.errorMessage {
                ErrorBanner(
                    message: errorMessage,
                    retryNetworkRestore: model.systemProxyRecoveryRequired ? {
                        Task { await model.disableSystemProxy() }
                    } : nil,
                    showLogs: {
                        model.selection = .logs
                        if !model.systemProxyRecoveryRequired {
                            model.errorMessage = nil
                        }
                    },
                    dismiss: model.systemProxyRecoveryRequired ? nil : {
                        model.errorMessage = nil
                    }
                )
                .transition(.opacity)
            }
        }
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
        case .settings:
            SettingsView(model: model)
        }
    }
}

private struct ErrorBanner: View {
    let message: String
    let retryNetworkRestore: (() -> Void)?
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

            Spacer(minLength: 12)

            if let retryNetworkRestore {
                Button("Restore Network Settings", action: retryNetworkRestore)
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
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MClash could not complete the operation")
    }
}
