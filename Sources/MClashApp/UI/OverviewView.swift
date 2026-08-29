import SwiftUI

struct OverviewView: View {
    @Bindable var model: AppModel
    @State private var compact = false
    @State private var detailsExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MClashLayout.sectionSpacing) {
                OverviewStatusCard(model: model, compact: compact)

                if model.isConnected {
                    OverviewMetricsCard(model: model, compact: compact)
                }

                DisclosureGroup("Connection Details", isExpanded: $detailsExpanded) {
                    OverviewConnectionDetails(model: model)
                        .padding(.top, MClashLayout.compactSpacing)
                }
                .font(.headline)
                .padding(MClashLayout.panelSpacing)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, compact
                ? MClashLayout.compactPagePadding
                : MClashLayout.pagePadding)
            .padding(.vertical, MClashLayout.sectionSpacing)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { updateCompactState(geometry.size.width) }
                        .onChange(of: geometry.size.width) { _, width in
                            updateCompactState(width)
                        }
                }
            }
        }
        .navigationTitle("Overview")
        .mclashPageSurface()
    }

    private func updateCompactState(_ width: CGFloat) {
        let next = width < 620
        if compact != next { compact = next }
    }
}

private struct OverviewStatusCard: View {
    @Bindable var model: AppModel
    let compact: Bool

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: MClashLayout.controlSpacing) {
                    statusContent
                    action.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .center, spacing: MClashLayout.panelSpacing) {
                    statusContent
                    Spacer(minLength: MClashLayout.sectionSpacing)
                    action
                }
            }
        }
        .padding(18)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(statusColor.opacity(0.2), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var statusContent: some View {
        HStack(alignment: .top, spacing: MClashLayout.panelSpacing) {
            Image(systemName: statusSymbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 44, height: 44)
                .background(statusColor.opacity(0.11), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(model.operationalSnapshot.title)
                    .font(.title2.weight(.semibold))
                Text(model.operationalSnapshot.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: MClashLayout.compactSpacing) { statusPills }
                    VStack(alignment: .leading, spacing: MClashLayout.compactSpacing) {
                        statusPills
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusPills: some View {
        statusPill(
            model.configurationDocument.currentWorkspace?.name
                ?? model.activeProfile?.name
                ?? AppLocalization.string("No Workspace"),
            symbol: "rectangle.3.group"
        )
        statusPill(captureTitle, symbol: captureSymbol)
        if model.liveDataIsDegraded {
            statusPill(
                AppLocalization.string("Live data stale"),
                symbol: "clock.badge.exclamationmark"
            )
        }
    }

    @ViewBuilder
    private var action: some View {
        if model.systemProxyRecoveryRequired {
            Button {
                Task { await model.disableSystemProxy() }
            } label: {
                actionLabel(
                    model.isPerforming(.changeSystemProxy) ? "Restoring…" : "Restore Network Settings",
                    symbol: "arrow.uturn.backward",
                    showsProgress: model.isPerforming(.changeSystemProxy)
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canPerform(.changeSystemProxy))
        } else if !model.operationalIssues.isEmpty {
            Button {
                model.selection = .attention
            } label: {
                Label(reviewIssuesTitle, systemImage: "exclamationmark.triangle.fill")
            }
            .buttonStyle(.borderedProminent)
        } else if model.activeProfile == nil {
            Button {
                model.selection = .profiles
            } label: {
                Label("Choose a Profile", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        } else if !model.isConnected {
            Button {
                Task { await model.connect() }
            } label: {
                actionLabel(
                    model.preparationInProgress ? "Preparing…" : "Connect",
                    symbol: "play.fill",
                    showsProgress: model.preparationInProgress || model.isPerforming(.connection)
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canPerform(.connection))
        } else {
            Button {
                Task { await model.toggleConnection() }
            } label: {
                actionLabel(
                    model.isPerforming(.connection) ? "Disconnecting…" : "Disconnect",
                    symbol: "stop.fill",
                    showsProgress: model.isPerforming(.connection)
                )
            }
            .buttonStyle(.bordered)
            .disabled(!model.canPerform(.connection))
        }
    }

    private func actionLabel(
        _ title: String,
        symbol: String,
        showsProgress: Bool
    ) -> some View {
        HStack(spacing: 7) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
            }
            Text(AppLocalization.string(title))
        }
    }

    private func statusPill(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }

    private var reviewIssuesTitle: String {
        let count = model.operationalIssues.count
        return AppLocalization.format(
            count == 1 ? "Review %@ Issue" : "Review %@ Issues",
            AppLocalization.number(count)
        )
    }

    private var captureTitle: String {
        if appRoutingIsActive { return AppLocalization.string("App Routing") }
        if model.systemProxyEnabled { return AppLocalization.string("macOS System Proxy") }
        return AppLocalization.string(model.isConnected ? "Local Proxy" : "Not Connected")
    }

    private var captureSymbol: String {
        if appRoutingIsActive { return "app.badge" }
        if model.systemProxyEnabled { return "desktopcomputer" }
        return model.isConnected ? "point.3.connected.trianglepath.dotted" : "power"
    }

    private var appRoutingIsActive: Bool {
        switch model.networkCaptureState {
        case .off: false
        case .waitingForConnection, .enabling, .awaitingUserApproval, .on,
             .disabling, .requiresReboot, .failed: true
        }
    }

    private var statusColor: Color {
        switch model.operationalSnapshot.level {
        case .active: .green
        case .transitioning: .orange
        case .attention:
            model.operationalIssues.first?.severity == .error ? .red : .orange
        case .localOnly: .yellow
        case .disconnected: .secondary
        }
    }

    private var statusSymbol: String {
        switch model.operationalSnapshot.level {
        case .active: "checkmark.shield.fill"
        case .transitioning: "arrow.triangle.2.circlepath"
        case .attention: "exclamationmark.triangle.fill"
        case .localOnly: "cable.connector"
        case .disconnected: "power"
        }
    }
}

private struct OverviewMetricsCard: View {
    @Bindable var model: AppModel
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MClashLayout.controlSpacing) {
            HStack {
                Label("Live Traffic", systemImage: "waveform.path.ecg")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("View Traffic") { model.selection = .connections }
                    .controlSize(.small)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                metric("Download", value: trafficValue(model.traffic.download), symbol: "arrow.down", color: .blue)
                metric("Upload", value: trafficValue(model.traffic.upload), symbol: "arrow.up", color: .orange)
                metric("Connections", value: connectionCount, symbol: "arrow.left.arrow.right", color: .primary)
            }

            if model.liveMetricsAreDegraded {
                Label(
                    "Live data is reconnecting. Last-known values may be stale.",
                    systemImage: "arrow.clockwise"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(MClashLayout.panelSpacing)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 120), spacing: 16, alignment: .topLeading),
            count: compact ? 1 : 3
        )
    }

    private func metric(
        _ title: String,
        value: String,
        symbol: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(AppLocalization.string(title), systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func trafficValue(_ value: Int64) -> String {
        model.liveStreamHealth[.traffic]?.hasCurrentData == true
            ? formattedByteRate(value)
            : "—"
    }

    private var connectionCount: String {
        model.liveStreamHealth[.connections]?.hasCurrentData == true
            ? AppLocalization.number(model.connections?.connections.count ?? 0)
            : "—"
    }
}

private struct OverviewConnectionDetails: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            detailRow(
                title: "Connection",
                value: connectionStatus,
                symbol: connectionSymbol,
                color: connectionColor
            )
            Divider().padding(.leading, 36)
            detailRow(
                title: "Traffic Routing",
                value: model.operationalSnapshot.captureSummary,
                symbol: routingSymbol,
                color: routingColor
            )
            Divider().padding(.leading, 36)
            valueRow(
                "Profile",
                value: model.activeProfile?.name ?? AppLocalization.string("Not selected")
            )
            Divider().padding(.leading, 36)
            valueRow("Routing Mode", value: routingMode)

            if let address = model.localMixedListenerAddress {
                Divider().padding(.leading, 36)
                HStack(spacing: 12) {
                    Text("Mixed Proxy")
                        .foregroundStyle(.secondary)
                    Spacer()
                    CopyableValueButton(
                        value: address,
                        accessibilityName: "Mixed proxy address"
                    )
                }
                .padding(.vertical, 10)
            }

            if let session = model.runningSession {
                Divider().padding(.leading, 36)
                valueRow("Core Version", value: session.version, monospaced: true)
                Divider().padding(.leading, 36)
                valueRow(
                    "Session Started",
                    value: AppLocalization.date(session.startedAt)
                )
            }
        }
        .font(.callout)
    }

    private func detailRow(
        title: String,
        value: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(AppLocalization.string(title))
                .fontWeight(.medium)
            Spacer(minLength: 16)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func valueRow(
        _ title: String,
        value: String,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Color.clear
                .frame(width: 24, height: 1)
                .accessibilityHidden(true)
            Text(AppLocalization.string(title))
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var connectionStatus: String {
        if model.preparationInProgress { return AppLocalization.string("Preparing") }
        return switch model.coreState {
        case .stopped: AppLocalization.string("Stopped")
        case .validating: AppLocalization.string("Checking")
        case .starting: AppLocalization.string("Starting")
        case .running: AppLocalization.string("Connected")
        case .stopping: AppLocalization.string("Stopping")
        case .failed: AppLocalization.string("Failed")
        }
    }

    private var connectionSymbol: String {
        switch model.coreState {
        case .running: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .validating, .starting, .stopping: "arrow.triangle.2.circlepath"
        case .stopped: "stop.circle"
        }
    }

    private var connectionColor: Color {
        switch model.coreState {
        case .running: .green
        case .failed: .red
        case .validating, .starting, .stopping: .orange
        case .stopped: .secondary
        }
    }

    private var routingSymbol: String {
        if appRoutingIsOn { return "app.badge" }
        return model.systemProxyEnabled
            ? "desktopcomputer"
            : "point.3.connected.trianglepath.dotted"
    }

    private var routingColor: Color {
        if model.operationalIssues.contains(where: { $0.subsystem == .appRouting }) {
            return .orange
        }
        return appRoutingIsOn || model.systemProxyEnabled ? .green : .secondary
    }

    private var appRoutingIsOn: Bool {
        if case .on = model.networkCaptureState { return true }
        return false
    }

    private var routingMode: String {
        guard let mode = model.runtimeConfig?.mode, !mode.isEmpty else {
            return AppLocalization.string("Unavailable")
        }
        return switch mode.lowercased() {
        case "rule": AppLocalization.string("Rule")
        case "global": AppLocalization.string("Global")
        case "direct": AppLocalization.string("Direct")
        default: mode.capitalized
        }
    }
}
