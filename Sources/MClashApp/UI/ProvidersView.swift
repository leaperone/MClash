import SwiftUI

struct ProvidersView: View {
    @Bindable var model: AppModel
    @State private var layout: ProvidersLayout = .wide
    @State private var hasCompletedInitialLoad = false

    var body: some View {
        Group {
            if !model.isConnected {
                DisconnectedUnavailableView(
                    model: model,
                    title: AppLocalization.string("Connect to manage providers"),
                    systemImage: "shippingbox",
                    description: AppLocalization.string(
                        "Provider status and update controls come from the active core."
                    )
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
            } else if allProvidersAreEmpty,
                      model.isPerforming(.refreshProviders) || !hasCompletedInitialLoad {
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
                ContentUnavailableView {
                    Label("No providers", systemImage: "shippingbox")
                } description: {
                    Text("The active profile does not define proxy or rule providers.")
                } actions: {
                    Button("Open Profiles") { model.selection = .profiles }
                }
            } else {
                List {
                    if !model.proxyProviders.isEmpty {
                        Section("Proxy Providers") {
                            ForEach(model.proxyProviders, id: \.name) { provider in
                                ProxyProviderRow(
                                    model: model,
                                    provider: provider,
                                    compact: layout == .compact
                                )
                            }
                        }
                    }

                    if !model.ruleProviders.isEmpty {
                        Section("Rule Providers") {
                            ForEach(model.ruleProviders, id: \.name) { provider in
                                RuleProviderRow(
                                    model: model,
                                    provider: provider,
                                    compact: layout == .compact
                                )
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .mclashListSurface()
            }
        }
        .navigationTitle("Providers")
        .mclashPageSurface()
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { updateLayout(geometry.size.width) }
                    .onChange(of: geometry.size.width) { _, width in
                        updateLayout(width)
                    }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.errorMessage == nil,
               let message = model.providersErrorMessage,
               !allProvidersAreEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.callout)
                        .lineLimit(2)
                        .help(message)
                    Spacer()
                    Button("Retry") { Task { await model.refreshProviders() } }
                        .disabled(!model.canPerform(.refreshProviders))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .task(id: [
            model.controllerIsReady,
            model.mainWindowPresentationTelemetryIsVisible,
        ]) {
            guard model.controllerIsReady,
                  model.mainWindowPresentationTelemetryIsVisible else {
                if !model.controllerIsReady {
                    hasCompletedInitialLoad = false
                }
                return
            }
            await loadProvidersWhenAvailable()
            guard !Task.isCancelled,
                  model.controllerIsReady,
                  model.mainWindowPresentationTelemetryIsVisible else { return }
            hasCompletedInitialLoad = true
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refreshProviders() }
                } label: {
                    if model.isPerforming(.refreshProviders) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh Status", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(
                    !model.controllerIsReady
                        || !model.canPerform(.refreshProviders)
                )
            }
        }
    }

    private var allProvidersAreEmpty: Bool {
        model.proxyProviders.isEmpty && model.ruleProviders.isEmpty
    }

    private func updateLayout(_ width: CGFloat) {
        let next = ProvidersLayout(width: width)
        if layout != next { layout = next }
    }

    private func loadProvidersWhenAvailable() async {
        guard !Task.isCancelled,
              model.controllerIsReady,
              model.mainWindowPresentationTelemetryIsVisible,
              model.providersLastLoadedAt == nil,
              model.providersErrorMessage == nil else {
            return
        }
        while !Task.isCancelled,
              model.controllerIsReady,
              model.mainWindowPresentationTelemetryIsVisible,
              model.providersLastLoadedAt == nil,
              model.providersErrorMessage == nil,
              !model.canPerform(.refreshProviders) {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
        if !Task.isCancelled,
           model.controllerIsReady,
           model.mainWindowPresentationTelemetryIsVisible,
           model.providersLastLoadedAt == nil,
           model.providersErrorMessage == nil,
           model.canPerform(.refreshProviders) {
            await model.refreshProviders()
        }
    }
}

private enum ProvidersLayout: Equatable {
    case compact
    case wide

    init(width: CGFloat) {
        self = width < 720 ? .compact : .wide
    }
}

private struct ProxyProviderRow: View {
    @Bindable var model: AppModel
    let provider: MihomoProxyProvider
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if compact {
                VStack(alignment: .leading, spacing: 9) {
                    providerIdentity
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        providerActions
                    }
                }
            } else {
                HStack(spacing: 12) {
                    providerIdentity
                    Spacer(minLength: 18)
                    providerActions
                }
            }

            if let subscription = provider.subscriptionInfo, subscription.total > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: usageFraction(subscription))
                        .accessibilityLabel(AppLocalization.string("Subscription usage"))
                        .accessibilityValue(subscriptionUsageAccessibilityValue(subscription))
                    HStack {
                        Text(
                            AppLocalization.format(
                                "%@ remaining",
                                remainingTraffic(subscription)
                            )
                        )
                        if subscription.expire > 0 {
                            Text("·")
                                .accessibilityHidden(true)
                            Text(expiration(subscription))
                        }
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if let receipt = latestReceipt {
                providerReceiptView(receipt)
            }
        }
        .padding(.vertical, compact ? 8 : 5)
    }

    private var providerIdentity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(provider.name)
                .lineLimit(compact ? 2 : 1)
                .help(provider.name)
            Text(metadata)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 2 : 1)
        }
    }

    private var providerActions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.updateProxyProvider(provider.name) }
            } label: {
                if model.isPerforming(.updateProxyProvider(provider.name)) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Updating…")
                    }
                } else {
                    Label("Update", systemImage: "arrow.clockwise")
                }
            }
            .disabled(
                providerOperationInProgress
                    || !model.canPerform(.updateProxyProvider(provider.name))
            )

            Menu {
                Button {
                    Task { await model.healthCheckProxyProvider(provider.name) }
                } label: {
                    Label("Test Provider", systemImage: "speedometer")
                }
                .disabled(
                    providerOperationInProgress
                        || !model.canPerform(.healthCheckProxyProvider(provider.name))
                )
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
        }
        .controlSize(.small)
    }

    private var providerOperationInProgress: Bool {
        model.isPerforming(.updateProxyProvider(provider.name))
            || model.isPerforming(.healthCheckProxyProvider(provider.name))
    }

    private var latestReceipt: AppModel.ProviderOperationReceipt? {
        [
            model.providerOperationReceipt(.updateProxy, providerName: provider.name),
            model.providerOperationReceipt(.healthCheckProxy, providerName: provider.name),
        ]
        .compactMap { $0 }
        .max { $0.completedAt < $1.completedAt }
    }

    private func providerReceiptView(
        _ receipt: AppModel.ProviderOperationReceipt
    ) -> some View {
        let action = AppLocalization.string(
            receipt.kind == .healthCheckProxy ? "Health check" : "Update"
        )
        let completedAt = AppLocalization.relativeDate(receipt.completedAt)
        return HStack(spacing: 5) {
            switch receipt.outcome {
            case .succeeded:
                Label(
                    AppLocalization.format("%@ completed %@", action, completedAt),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            case let .failed(message):
                Label(
                    AppLocalization.format("%@ failed %@", action, completedAt),
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .foregroundStyle(.red)
                    .help(message)
            }
        }
        .font(.caption)
    }

    private var metadata: String {
        let alive = provider.proxies.count { $0.alive }
        var parts = [
            AppLocalization.format(
                "Available %@ of %@",
                formattedCount(alive),
                formattedCount(provider.proxies.count)
            )
        ]
        if let updatedAt = provider.updatedAt, let date = parsedRuntimeTimestamp(updatedAt) {
            parts.append(
                AppLocalization.format(
                    "Updated %@",
                    AppLocalization.relativeDate(date)
                )
            )
        }
        return parts.joined(separator: " · ")
    }

    private func remainingTraffic(_ subscription: MihomoSubscriptionInfo) -> String {
        let used = saturatingByteSum(subscription.upload, subscription.download)
        let remaining = subscription.total > used ? subscription.total - used : 0
        return formattedByteCount(remaining)
    }

    private func subscriptionUsageAccessibilityValue(
        _ subscription: MihomoSubscriptionInfo
    ) -> String {
        let used = saturatingByteSum(subscription.upload, subscription.download)
        return AppLocalization.format(
            "Used %@ of %@",
            formattedByteCount(used),
            formattedByteCount(subscription.total)
        )
    }

    private func usageFraction(_ subscription: MihomoSubscriptionInfo) -> Double {
        let used = saturatingByteSum(subscription.upload, subscription.download)
        return min(max(Double(used) / Double(subscription.total), 0), 1)
    }

    private func expiration(_ subscription: MihomoSubscriptionInfo) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(subscription.expire))
        return AppLocalization.format(
            date < Date.now ? "Expired %@" : "Expires %@",
            AppLocalization.relativeDate(date)
        )
    }

}

private struct RuleProviderRow: View {
    @Bindable var model: AppModel
    let provider: MihomoRuleProvider
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if compact {
                    VStack(alignment: .leading, spacing: 9) {
                        ruleProviderIdentity
                        HStack(spacing: 10) {
                            Spacer(minLength: 0)
                            updateButton
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        ruleProviderIdentity
                        Spacer(minLength: 18)
                        updateButton
                    }
                }
            }
            if let receipt = model.providerOperationReceipt(
                .updateRule,
                providerName: provider.name
            ) {
                ruleProviderReceipt(receipt)
            }
        }
        .padding(.vertical, compact ? 8 : 5)
    }

    private var ruleProviderIdentity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(provider.name)
                .lineLimit(compact ? 2 : 1)
                .help(provider.name)
            Text(
                AppLocalization.format(
                    "Rules %@ · %@",
                    formattedCount(provider.ruleCount),
                    updatedLabel
                )
            )
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var updateButton: some View {
        Button {
            Task { await model.updateRuleProvider(provider.name) }
        } label: {
            if model.isPerforming(.updateRuleProvider(provider.name)) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating…")
                }
            } else {
                Label("Update", systemImage: "arrow.clockwise")
            }
        }
        .controlSize(.small)
        .disabled(!model.canPerform(.updateRuleProvider(provider.name)))
    }

    private var updatedLabel: String {
        guard let date = parsedRuntimeTimestamp(provider.updatedAt) else {
            return AppLocalization.string("Not updated yet")
        }
        return AppLocalization.relativeDate(date)
    }

    private func ruleProviderReceipt(
        _ receipt: AppModel.ProviderOperationReceipt
    ) -> some View {
        let action = AppLocalization.string("Update")
        let completedAt = AppLocalization.relativeDate(receipt.completedAt)
        Group {
            switch receipt.outcome {
            case .succeeded:
                Label(
                    AppLocalization.format("%@ completed %@", action, completedAt),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            case let .failed(message):
                Label(
                    AppLocalization.format("%@ failed %@", action, completedAt),
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .foregroundStyle(.red)
                    .help(message)
            }
        }
        .font(.caption2)
    }
}
