import SwiftUI

struct ProvidersView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if !model.isConnected {
                ContentUnavailableView(
                    "Connect to manage providers",
                    systemImage: "shippingbox",
                    description: Text("Provider status and update controls come from the active core.")
                )
            } else if case let .degraded(message) = model.controllerState {
                ContentUnavailableView {
                    Label("Providers unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Reconnect") { Task { await model.restartConnection() } }
                        .disabled(!model.canPerform(.connection))
                    Button("View Logs") { model.selection = .logs }
                }
            } else if model.isPerforming(.refreshProviders), allProvidersAreEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading providers…")
                        .foregroundStyle(.secondary)
                }
            } else if let message = model.providersErrorMessage, allProvidersAreEmpty {
                ContentUnavailableView {
                    Label("Providers unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await model.refreshProviders() } }
                        .disabled(!model.canPerform(.refreshProviders))
                    Button("View Logs") { model.selection = .logs }
                }
            } else if allProvidersAreEmpty {
                ContentUnavailableView(
                    "No providers",
                    systemImage: "shippingbox",
                    description: Text("The active profile does not define proxy or rule providers.")
                )
            } else {
                List {
                    if !model.proxyProviders.isEmpty {
                        Section("Proxy Providers") {
                            ForEach(model.proxyProviders, id: \.name) { provider in
                                ProxyProviderRow(model: model, provider: provider)
                            }
                        }
                    }

                    if !model.ruleProviders.isEmpty {
                        Section("Rule Providers") {
                            ForEach(model.ruleProviders, id: \.name) { provider in
                                RuleProviderRow(model: model, provider: provider)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Providers")
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = model.providersErrorMessage, !allProvidersAreEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.callout)
                        .lineLimit(2)
                    Spacer()
                    Button("Retry") { Task { await model.refreshProviders() } }
                        .disabled(!model.canPerform(.refreshProviders))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .task(id: model.controllerIsReady) {
            await loadProvidersWhenAvailable()
        }
        .toolbar {
            Button {
                Task { await model.refreshProviders() }
            } label: {
                if model.isPerforming(.refreshProviders) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
            }
            .disabled(
                !model.controllerIsReady
                    || !model.canPerform(.refreshProviders)
            )
        }
    }

    private var allProvidersAreEmpty: Bool {
        model.proxyProviders.isEmpty && model.ruleProviders.isEmpty
    }

    private func loadProvidersWhenAvailable() async {
        guard model.controllerIsReady,
              allProvidersAreEmpty,
              model.providersErrorMessage == nil else {
            return
        }
        while model.controllerIsReady,
              allProvidersAreEmpty,
              model.providersErrorMessage == nil,
              !model.canPerform(.refreshProviders) {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
        if model.controllerIsReady,
           allProvidersAreEmpty,
           model.providersErrorMessage == nil,
           model.canPerform(.refreshProviders) {
            await model.refreshProviders()
        }
    }
}

private struct ProxyProviderRow: View {
    @Bindable var model: AppModel
    let provider: MihomoProxyProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name)
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await model.healthCheckProxyProvider(provider.name) }
                } label: {
                    if model.isPerforming(.healthCheckProxyProvider(provider.name)) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Health Check", systemImage: "speedometer")
                    }
                }
                .disabled(
                    providerOperationInProgress
                        || !model.canPerform(.healthCheckProxyProvider(provider.name))
                )

                Button {
                    Task { await model.updateProxyProvider(provider.name) }
                } label: {
                    if model.isPerforming(.updateProxyProvider(provider.name)) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Update", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(
                    providerOperationInProgress
                        || !model.canPerform(.updateProxyProvider(provider.name))
                )
            }

            if let subscription = provider.subscriptionInfo, subscription.total > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: usageFraction(subscription))
                    HStack {
                        Text("Used \(bytes(subscription.upload + subscription.download))")
                        Spacer()
                        Text("Total \(bytes(subscription.total))")
                        if subscription.expire > 0 {
                            Text("· Expires \(expiration(subscription))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 5)
    }

    private var providerOperationInProgress: Bool {
        model.isPerforming(.updateProxyProvider(provider.name))
            || model.isPerforming(.healthCheckProxyProvider(provider.name))
    }

    private var metadata: String {
        let alive = provider.proxies.count { $0.alive }
        var parts = [
            provider.vehicleType,
            "\(provider.proxies.count) nodes",
            "\(alive) available",
        ]
        if let updatedAt = provider.updatedAt, let date = providerDate(updatedAt) {
            parts.append("updated \(date.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private func usageFraction(_ subscription: MihomoSubscriptionInfo) -> Double {
        min(max(Double(subscription.upload + subscription.download) / Double(subscription.total), 0), 1)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func expiration(_ subscription: MihomoSubscriptionInfo) -> String {
        Date(timeIntervalSince1970: TimeInterval(subscription.expire))
            .formatted(date: .abbreviated, time: .omitted)
    }

}

private struct RuleProviderRow: View {
    @Bindable var model: AppModel
    let provider: MihomoRuleProvider

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.name)
                Text("\(provider.behavior) · \(provider.vehicleType) · \(provider.ruleCount) rules")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(updatedLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Button {
                Task { await model.updateRuleProvider(provider.name) }
            } label: {
                if model.isPerforming(.updateRuleProvider(provider.name)) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Update", systemImage: "arrow.clockwise")
                }
            }
            .disabled(!model.canPerform(.updateRuleProvider(provider.name)))
        }
        .padding(.vertical, 5)
    }

    private var updatedLabel: String {
        guard let date = providerDate(provider.updatedAt) else {
            return provider.updatedAt
        }
        return date.formatted(.relative(presentation: .named))
    }
}

private func providerDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value)
}
