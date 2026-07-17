import Charts
import SwiftUI

struct OverviewView: View {
    @Bindable var model: AppModel
    @State private var layout: OverviewLayout = .wide

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MClashLayout.sectionSpacing) {
                OverviewOperationalSummary(model: model)
                OverviewAttentionSummary(model: model)
                OverviewNetworkStateSection(model: model, layout: layout)
                OverviewLiveDataNotice(model: model)
                OverviewMetricsSection(model: model, layout: layout)
                OverviewFlowSummarySection(model: model, layout: layout)
                primaryContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { updateLayout(for: geometry.size.width) }
                        .onChange(of: geometry.size.width) { _, width in
                            updateLayout(for: width)
                        }
                }
            }
            .padding(.horizontal, MClashLayout.pagePadding)
            .padding(.vertical, 24)
            .frame(maxWidth: 1_320, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("Overview")
        .mclashPageSurface()
    }

    private var primaryContent: some View {
        let contentLayout = layout == .wide
            ? AnyLayout(HStackLayout(alignment: .top, spacing: MClashLayout.sectionSpacing))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: MClashLayout.sectionSpacing))

        return contentLayout {
            OverviewTrafficSection(model: model)
                .frame(minWidth: layout == .wide ? 500 : nil, maxWidth: .infinity, alignment: .topLeading)

            Divider()

            OverviewSessionDetailsSection(
                model: model,
                presentation: layout.detailsPresentation
            )
            .frame(width: layout == .wide ? 320 : nil, alignment: .topLeading)
        }
    }

    private func updateLayout(for width: CGFloat) {
        let nextLayout = OverviewLayout(width: width)
        if layout != nextLayout {
            layout = nextLayout
        }
    }
}

private struct OverviewOperationalSummary: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.11), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(model.operationalSnapshot.title)
                    .font(.title2.weight(.semibold))
                Text(model.operationalSnapshot.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    statusPill(
                        model.operationalSnapshot.captureSummary,
                        symbol: "arrow.triangle.branch"
                    )
                    if model.isConnected {
                        statusPill(
                            "\(formattedCount(model.connections?.connections.count ?? 0)) active",
                            symbol: "arrow.left.arrow.right"
                        )
                    }
                    if model.liveDataIsDegraded {
                        statusPill("Live data stale", symbol: "clock.badge.exclamationmark")
                    }
                }
            }

            Spacer(minLength: 20)

            if !model.operationalIssues.isEmpty {
                Button("Review \(model.operationalIssues.count) \(model.operationalIssues.count == 1 ? "Issue" : "Issues")") {
                    model.selection = .attention
                }
                .buttonStyle(.borderedProminent)
            } else if !model.isConnected {
                Button("Connect") { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canPerform(.connection) || model.activeProfile == nil)
            }
        }
        .padding(18)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(color.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func statusPill(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }

    private var color: Color {
        switch model.operationalSnapshot.level {
        case .active: .green
        case .transitioning: .accentColor
        case .attention: .orange
        case .localOnly: .yellow
        case .disconnected: .secondary
        }
    }

    private var symbol: String {
        switch model.operationalSnapshot.level {
        case .active: "checkmark.shield.fill"
        case .transitioning: "arrow.triangle.2.circlepath"
        case .attention: "exclamationmark.triangle.fill"
        case .localOnly: "cable.connector"
        case .disconnected: "power"
        }
    }
}

private struct OverviewAttentionSummary: View {
    @Bindable var model: AppModel

    @ViewBuilder
    var body: some View {
        if let issue = model.operationalIssues.first {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: issue.severity == .error
                    ? "exclamationmark.octagon.fill"
                    : "exclamationmark.triangle.fill")
                    .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title)
                        .font(.callout.weight(.semibold))
                    Text(issue.consequence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                Button("Review") { model.selection = .attention }
                    .controlSize(.small)
            }
            .padding(12)
            .background(
                (issue.severity == .error ? Color.red : Color.orange).opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .accessibilityElement(children: .contain)
        }
    }
}

private enum OverviewLayout: Equatable {
    case compact
    case singleColumn
    case wide

    init(width: CGFloat) {
        switch width {
        case ..<620: self = .compact
        case ..<880: self = .singleColumn
        default: self = .wide
        }
    }

    var metricColumnCount: Int {
        switch self {
        case .compact: 2
        case .singleColumn: 3
        case .wide: 5
        }
    }

    var stateRowsAreInline: Bool {
        self != .compact
    }

    var detailsPresentation: OverviewDetailPresentation {
        self == .singleColumn ? .row : .stacked
    }
}

private enum OverviewDetailPresentation {
    case row
    case stacked
}

private struct OverviewNetworkStateSection: View {
    @Bindable var model: AppModel
    let layout: OverviewLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OverviewSectionHeader(title: "Network State", symbol: "network")

            VStack(spacing: 0) {
                OverviewStateRow(
                    title: "mihomo Core",
                    status: coreStatusTitle,
                    description: coreStatusDescription,
                    symbol: coreStatusSymbol,
                    color: coreStatusColor,
                    isInline: layout.stateRowsAreInline
                ) {
                    Button {
                        Task { await model.toggleConnection() }
                    } label: {
                        HStack(spacing: 7) {
                            if model.preparationInProgress
                                || model.isBusy
                                || model.isPerforming(.connection) {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(connectionButtonTitle)
                                .frame(minWidth: 72)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canPerform(.connection))
                    .accessibilityHint(connectionButtonHint)
                }

                Divider()
                    .padding(.leading, layout.stateRowsAreInline ? 58 : 16)

                OverviewStateRow(
                    title: "macOS System Proxy",
                    status: systemProxyStatusTitle,
                    description: systemProxyStatusDescription,
                    symbol: systemProxyStatusSymbol,
                    color: systemProxyStatusColor,
                    isInline: layout.stateRowsAreInline
                ) {
                    Button {
                        Task {
                            if model.systemProxyRecoveryRequired {
                                await model.disableSystemProxy()
                            } else {
                                await model.setSystemProxyEnabled(!model.systemProxyEnabled)
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            if model.isPerforming(.changeSystemProxy) {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(systemProxyActionTitle)
                        }
                    }
                    .controlSize(.large)
                    .disabled(
                        !model.canPerform(.changeSystemProxy)
                            || (
                                !model.systemProxyRecoveryRequired
                                    && (!model.isConnected || !model.controllerIsReady)
                            )
                    )
                }

                Divider()
                    .padding(.leading, layout.stateRowsAreInline ? 58 : 16)

                OverviewStateRow(
                    title: "App Routing",
                    status: appRoutingStatusTitle,
                    description: appRoutingStatusDescription,
                    symbol: appRoutingStatusSymbol,
                    color: appRoutingStatusColor,
                    isInline: layout.stateRowsAreInline
                ) {
                    Button(appRoutingActionTitle) {
                        if case .failed = model.networkCaptureState {
                            Task { await model.retryNetworkCaptureActivation() }
                        } else {
                            model.selection = .appRouting
                        }
                    }
                    .controlSize(.large)
                    .disabled(appRoutingRetryDisabled)
                }
            }
            .padding(.horizontal, 16)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
    }

    private var coreStatusTitle: String {
        if model.preparationInProgress { return "Preparing" }
        switch model.coreState {
        case .stopped: return "Stopped"
        case .validating: return "Checking"
        case .starting: return "Starting"
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .failed: return "Failed"
        }
    }

    private var coreStatusDescription: String {
        if model.preparationInProgress {
            return "MClash is loading profiles, checking saved network state, and preparing the last session."
        }
        switch model.coreState {
        case .stopped:
            return "The local proxy core is not running. Choose a profile, then connect when needed."
        case .validating:
            return "MClash is validating the active profile before changing network state."
        case .starting:
            return "The core is opening its local proxy ports and controller."
        case let .running(session):
            return "The bundled Alpha core is healthy and has been running since \(session.startedAt.formatted(date: .omitted, time: .shortened))."
        case .stopping:
            return "MClash is shutting down the core and restoring network state."
        case .failed:
            return "The core could not reach a healthy running state. Review the error and logs before retrying."
        }
    }

    private var coreStatusSymbol: String {
        if model.preparationInProgress { return "arrow.triangle.2.circlepath" }
        switch model.coreState {
        case .running: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .validating, .starting, .stopping: return "arrow.triangle.2.circlepath"
        case .stopped: return "stop.circle"
        }
    }

    private var coreStatusColor: Color {
        if model.preparationInProgress { return .orange }
        switch model.coreState {
        case .running: return .green
        case .failed: return .red
        case .validating, .starting, .stopping: return .orange
        case .stopped: return .secondary
        }
    }

    private var systemProxyStatusTitle: String {
        switch model.systemProxyState {
        case .off: "Off"
        case .enabling: "Enabling"
        case .on: "On"
        case .disabling: "Disabling"
        case .failed: "Recovery Needed"
        }
    }

    private var systemProxyStatusDescription: String {
        switch model.systemProxyState {
        case .off:
            "macOS is not being directed through MClash. The core can still accept connections at its local addresses."
        case .enabling:
            "MClash is saving the current macOS proxy settings and applying its local endpoints."
        case .on:
            "macOS HTTP, HTTPS, and SOCKS traffic is directed to the running core."
        case .disabling:
            "MClash is restoring the proxy settings that were active before this session."
        case let .failed(message):
            message
        }
    }

    private var systemProxyStatusSymbol: String {
        switch model.systemProxyState {
        case .off: "desktopcomputer"
        case .enabling, .disabling: "arrow.triangle.2.circlepath"
        case .on: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var systemProxyStatusColor: Color {
        switch model.systemProxyState {
        case .on: .green
        case .failed: .red
        case .enabling, .disabling: .orange
        case .off: .secondary
        }
    }

    private var systemProxyActionTitle: String {
        if model.systemProxyRecoveryRequired { return "Restore" }
        switch model.systemProxyState {
        case .enabling: return "Turning On…"
        case .disabling: return "Turning Off…"
        default: return model.systemProxyEnabled ? "Turn Off" : "Turn On"
        }
    }

    private var appRoutingStatusTitle: String {
        switch model.networkCaptureState {
        case .off: "Off"
        case .waitingForConnection: "Waiting"
        case .enabling: "Starting"
        case .awaitingUserApproval: "Approval Required"
        case .on: "On"
        case .disabling: "Stopping"
        case .requiresReboot: "Restart Required"
        case .failed: "Failed"
        }
    }

    private var appRoutingStatusDescription: String {
        let activeRules = model.networkCapturePreferences.snapshot.rules.filter(\.enabled).count
        switch model.networkCaptureState {
        case .off:
            return "The Network Extension is not applying per-application traffic rules."
        case .waitingForConnection:
            return "\(activeRules) active \(activeRules == 1 ? "rule is" : "rules are") saved and will start after Mihomo connects."
        case .enabling:
            return "MClash is installing, configuring, and verifying the transparent network provider."
        case .awaitingUserApproval:
            return "macOS approval is required before application traffic can be intercepted."
        case let .on(revision):
            return "Provider revision \(revision) is applying \(activeRules) active \(activeRules == 1 ? "rule" : "rules")."
        case .disabling:
            return "MClash is stopping the provider and returning traffic handling to macOS."
        case .requiresReboot:
            return "macOS accepted the extension update and will activate it after a restart."
        case let .failed(message):
            return message
        }
    }

    private var appRoutingStatusSymbol: String {
        switch model.networkCaptureState {
        case .on: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .awaitingUserApproval: "lock.shield.fill"
        case .requiresReboot: "restart.circle.fill"
        case .enabling, .disabling: "arrow.triangle.2.circlepath"
        case .waitingForConnection: "pause.circle.fill"
        case .off: "app.badge"
        }
    }

    private var appRoutingStatusColor: Color {
        switch model.networkCaptureState {
        case .on: .green
        case .failed: .red
        case .awaitingUserApproval, .requiresReboot: .orange
        case .enabling, .disabling: .accentColor
        case .waitingForConnection, .off: .secondary
        }
    }

    private var appRoutingActionTitle: String {
        if case .failed = model.networkCaptureState { return "Retry" }
        return "Manage"
    }

    private var appRoutingRetryDisabled: Bool {
        if case .failed = model.networkCaptureState {
            return !model.canPerform(.changeNetworkCapture)
        }
        return false
    }

    private var connectionButtonTitle: String {
        if model.preparationInProgress { return "Preparing…" }
        switch model.coreState {
        case .running, .starting: return "Disconnect"
        case .stopping: return "Stopping…"
        case .validating: return "Checking…"
        default: return "Connect"
        }
    }

    private var connectionButtonHint: String {
        switch model.coreState {
        case .running, .starting:
            "Stops the local core and restores macOS proxy settings."
        default:
            "Starts the local core with the active profile."
        }
    }
}

private struct OverviewLiveDataNotice: View {
    @Bindable var model: AppModel

    @ViewBuilder
    var body: some View {
        if model.liveMetricsAreDegraded {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Live data is reconnecting")
                        .font(.callout.weight(.medium))
                    Text(degradedSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("View Logs") { model.selection = .logs }
                    .controlSize(.small)
            }
            .padding(12)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .accessibilityElement(children: .contain)
        }
    }

    private var degradedSummary: String {
        let names = AppModel.LiveStream.allCases.compactMap { stream -> String? in
            guard model.degradedStreams.contains(stream) else { return nil }
            switch stream {
            case .traffic: return "rates"
            case .connections: return "connections"
            case .logs: return "logs"
            case .proxies: return "proxy state"
            case .appRouting: return "App Routing activity"
            }
        }
        guard !names.isEmpty else { return "Some live values may be temporarily stale." }
        return names.joined(separator: ", ").capitalized + " may be temporarily stale."
    }
}

private struct OverviewMetricsSection: View {
    @Bindable var model: AppModel
    let layout: OverviewLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OverviewSectionHeader(title: "Live Session", symbol: "waveform.path.ecg")

            LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 16) {
                OverviewMetricCell(
                    title: "Download",
                    value: liveTrafficValue(model.traffic.download),
                    symbol: "arrow.down",
                    color: .blue
                )
                OverviewMetricCell(
                    title: "Upload",
                    value: liveTrafficValue(model.traffic.upload),
                    symbol: "arrow.up",
                    color: .orange
                )
                OverviewMetricCell(
                    title: "Connections",
                    value: liveConnectionCount,
                    symbol: "arrow.left.arrow.right",
                    color: .primary
                )
                OverviewMetricCell(
                    title: "Mihomo Session",
                    value: totalTraffic,
                    symbol: "sum",
                    color: .primary
                )
                OverviewMetricCell(
                    title: "App Relays",
                    value: formattedCount(activeAppRoutingRelayCount),
                    symbol: "app.connected.to.app.below.fill",
                    color: .primary
                )
            }
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Divider() }
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var metricColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 120), spacing: 16, alignment: .topLeading),
            count: layout.metricColumnCount
        )
    }

    private var totalTraffic: String {
        guard model.liveStreamHealth[.traffic]?.hasCurrentData == true else {
            return model.isConnected ? "Stale" : "—"
        }
        return formattedByteCount(
            saturatingByteSum(model.traffic.uploadTotal, model.traffic.downloadTotal)
        )
    }

    private func liveTrafficValue(_ value: Int64) -> String {
        guard model.liveStreamHealth[.traffic]?.hasCurrentData == true else {
            return model.isConnected ? "Stale" : "—"
        }
        return formattedByteRate(value)
    }

    private var liveConnectionCount: String {
        guard model.liveStreamHealth[.connections]?.hasCurrentData == true else {
            return model.isConnected ? "Stale" : "—"
        }
        return formattedCount(model.connections?.connections.count ?? 0)
    }

    private var activeAppRoutingRelayCount: Int {
        model.appRoutingActivities.lazy.filter { activity in
            guard activity.endedAt == nil else { return false }
            switch activity.relayState {
            case .pending, .connecting, .ready, .relaying:
                return true
            case .notApplicable, .completed, .failed:
                return false
            }
        }.count
    }
}

private struct OverviewFlowSummarySection: View {
    @Bindable var model: AppModel
    let layout: OverviewLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                OverviewSectionHeader(title: "Traffic at a Glance", symbol: "point.3.connected.trianglepath.dotted")
                Spacer()
                Button("Open Traffic") { model.selection = .connections }
                    .controlSize(.small)
            }

            if model.flowLedger.entries.isEmpty {
                Text(model.isConnected
                    ? "Waiting for the first observed flow…"
                    : "Connect to see which apps are active and where their traffic goes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            } else {
                let contentLayout = layout == .compact
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 12))

                contentLayout {
                    flowPanel(
                        title: "Top Applications",
                        rows: Array(model.flowLedger.applicationAggregates.prefix(4)).map {
                            FlowSummaryRow(
                                title: $0.application.displayName,
                                detail: "\(formattedCount($0.activeCount)) active · \(formattedCount($0.entryCount)) observed",
                                traffic: overviewTrafficTitle($0.traffic),
                                partial: $0.traffic.notMeasuredAfterHandoffCount > 0
                            )
                        }
                    )

                    flowPanel(
                        title: "Top Routes",
                        rows: Array(model.flowLedger.routeAggregates.prefix(4)).map {
                            FlowSummaryRow(
                                title: overviewRouteTitle($0.route),
                                detail: overviewRouteDetail($0.route, active: $0.activeCount),
                                traffic: overviewTrafficTitle($0.traffic),
                                partial: $0.traffic.notMeasuredAfterHandoffCount > 0
                            )
                        }
                    )
                }
            }
        }
    }

    private func flowPanel(title: String, rows: [FlowSummaryRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Text(row.traffic)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(row.partial ? Color.orange : Color.secondary)
                        .help(row.partial
                            ? "Measured bytes only. Some direct or fail-open payload continued outside MClash after handoff."
                            : "Observed traffic")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                if index < rows.count - 1 { Divider().padding(.leading, 14) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private struct FlowSummaryRow {
        let title: String
        let detail: String
        let traffic: String
        let partial: Bool
    }
}

private struct OverviewTrafficSection: View {
    @Bindable var model: AppModel

    var body: some View {
        let samples = model.trafficHistory
        let downloadRate = model.traffic.download
        let uploadRate = model.traffic.upload

        VStack(alignment: .leading, spacing: 14) {
            OverviewSectionHeader(title: "Traffic", symbol: "chart.xyaxis.line")

            HStack(spacing: 18) {
                OverviewTrafficLegendItem(
                    title: trafficIsCurrent ? "Download" : "Download · stale",
                    value: trafficIsCurrent ? formattedByteRate(downloadRate) : "—",
                    color: .blue
                )
                OverviewTrafficLegendItem(
                    title: trafficIsCurrent ? "Upload" : "Upload · stale",
                    value: trafficIsCurrent ? formattedByteRate(uploadRate) : "—",
                    color: .orange
                )
                Spacer()
                Text(trafficIsCurrent ? "Recent activity" : "Last received samples")
                    .font(.caption)
                    .foregroundStyle(trafficIsCurrent ? Color.secondary : Color.orange)
            }

            if samples.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(model.isConnected ? "Waiting for traffic samples…" : "Connect to view live traffic")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 230)
            } else {
                Chart(samples, id: \.timestamp) { sample in
                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Download", sample.download)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.blue.opacity(0.08))

                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Download", sample.download)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Upload", sample.upload)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.orange.opacity(0.07))

                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Upload", sample.upload)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                    if samples.count == 1 {
                        PointMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Download", sample.download)
                        )
                        .foregroundStyle(.blue)

                        PointMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Upload", sample.upload)
                        )
                        .foregroundStyle(.orange)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.hour().minute().second())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let bytes = value.as(Int64.self) {
                                Text(formattedByteRate(bytes))
                            }
                        }
                    }
                }
                .frame(height: 250)
                .accessibilityLabel("Recent network traffic")
                .accessibilityValue(
                    trafficIsCurrent
                        ? "Download \(formattedByteRate(downloadRate)), upload \(formattedByteRate(uploadRate))"
                        : "Traffic data is stale"
                )
            }
        }
    }

    private var trafficIsCurrent: Bool {
        model.liveStreamHealth[.traffic]?.hasCurrentData == true
    }
}

private func overviewTrafficTitle(_ aggregate: FlowLedgerTrafficAggregate) -> String {
    let total = aggregate.exactTotalBytes > UInt64(Int64.max)
        ? Int64.max
        : Int64(aggregate.exactTotalBytes)
    let measured = formattedByteCount(total)
    return aggregate.notMeasuredAfterHandoffCount > 0 ? "\(measured)+" : measured
}

private func overviewRouteTitle(_ route: FlowLedgerRouteKey) -> String {
    switch route {
    case let .mihomo(rule, _, chain): return chain.last ?? rule ?? "Mihomo"
    case let .unresolvedMihomo(rule): return rule.map { "Mihomo · \($0)" } ?? "Mihomo"
    case .direct: return "Direct"
    case .rejected: return "Rejected"
    case .failOpen: return "Fail Open"
    case .relayFailed: return "Relay Failed"
    }
}

private func overviewRouteDetail(_ route: FlowLedgerRouteKey, active: Int) -> String {
    let activeTitle = "\(formattedCount(active)) active"
    switch route {
    case let .mihomo(rule, payload, chain):
        let ruleTitle = [rule, payload]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
        let path = chain.joined(separator: " → ")
        return [activeTitle, ruleTitle.isEmpty ? path : ruleTitle]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    case .direct: return "\(activeTitle) · handed to macOS"
    case .rejected: return "\(activeTitle) · blocked"
    case .failOpen: return "\(activeTitle) · handed to macOS after failure"
    case .relayFailed: return "\(activeTitle) · relay unavailable"
    case .unresolvedMihomo: return "\(activeTitle) · awaiting route correlation"
    }
}

private struct OverviewSessionDetailsSection: View {
    @Bindable var model: AppModel
    let presentation: OverviewDetailPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            OverviewSectionHeader(title: "Configuration", symbol: "slider.horizontal.3")

            VStack(spacing: 0) {
                OverviewDetailRow(title: "Profile", presentation: presentation) {
                    HStack(spacing: 10) {
                        Text(activeProfileName)
                            .foregroundStyle(model.activeProfileID == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .help(activeProfileName)
                        Button("Manage…") { model.selection = .profiles }
                            .controlSize(.small)
                    }
                }

                detailDivider

                OverviewDetailRow(title: "Routing Mode", presentation: presentation) {
                    Text(routingMode)
                }

                detailDivider

                OverviewDetailRow(title: routingSummaryTitle, presentation: presentation) {
                    HStack(spacing: 10) {
                        Text(routingSummary)
                            .lineLimit(1)
                            .help(routingSummary)
                        if routingMode.lowercased() != "direct" {
                            Button(routingMode.lowercased() == "global" ? "Choose…" : "Inspect…") {
                                model.selection = .proxies
                            }
                            .controlSize(.small)
                            .disabled(!model.controllerIsReady)
                        }
                    }
                }

                detailDivider

                OverviewDetailRow(title: "HTTP Proxy", presentation: presentation) {
                    addressValue(
                        model.localHTTPListenerAddress,
                        accessibilityName: "HTTP proxy address"
                    )
                }

                detailDivider

                OverviewDetailRow(title: "SOCKS5 Proxy", presentation: presentation) {
                    addressValue(
                        model.localSOCKSListenerAddress,
                        accessibilityName: "SOCKS5 proxy address"
                    )
                }

                detailDivider

                OverviewDetailRow(title: "Mixed Proxy", presentation: presentation) {
                    addressValue(
                        model.localMixedListenerAddress,
                        accessibilityName: "Mixed proxy address"
                    )
                }

                if let session = model.runningSession {
                    detailDivider

                    OverviewDetailRow(title: "Core Version", presentation: presentation) {
                        Text(session.version)
                            .monospaced()
                            .textSelection(.enabled)
                    }

                    detailDivider

                    OverviewDetailRow(title: "Session Started", presentation: presentation) {
                        Text(session.startedAt.formatted(date: .abbreviated, time: .standard))
                    }
                }
            }
        }
    }

    private var detailDivider: some View {
        Divider()
            .padding(.leading, presentation == .row ? 138 : 0)
    }

    @ViewBuilder
    private func addressValue(
        _ address: String?,
        accessibilityName: String
    ) -> some View {
        if let address {
            CopyableValueButton(
                value: address,
                accessibilityName: accessibilityName
            )
        } else {
            Text("Unavailable")
                .foregroundStyle(.secondary)
        }
    }

    private var activeProfileName: String {
        model.activeProfile?.name ?? "Not selected"
    }

    private var routingMode: String {
        guard let mode = model.runtimeConfig?.mode, !mode.isEmpty else { return "Unavailable" }
        return switch mode.lowercased() {
        case "rule": "Rule"
        case "global": "Global"
        case "direct": "Direct"
        default: mode.capitalized
        }
    }

    private var routingSummaryTitle: String {
        switch model.runtimeConfig?.mode.lowercased() {
        case "global": "Global Route"
        case "rule": "Rule Routing"
        case "direct": "Routing"
        default: "Routing"
        }
    }

    private var routingSummary: String {
        switch model.runtimeConfig?.mode.lowercased() {
        case "direct":
            return "Direct · proxy groups bypassed"
        case "rule":
            return "Rules choose a route per connection"
        case "global":
            break
        default:
            return "Unavailable"
        }

        let global = model.proxyGroups.first {
            $0.name.caseInsensitiveCompare("GLOBAL") == .orderedSame
        }
        guard let group = global else { return "Global route unavailable" }
        return "\(group.name) → \(group.now ?? "Not selected")"
    }
}

private struct OverviewSectionHeader: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct OverviewStateRow<Action: View>: View {
    let title: String
    let status: String
    let description: String
    let symbol: String
    let color: Color
    let isInline: Bool
    @ViewBuilder let action: () -> Action

    init(
        title: String,
        status: String,
        description: String,
        symbol: String,
        color: Color,
        isInline: Bool,
        @ViewBuilder action: @escaping () -> Action
    ) {
        self.title = title
        self.status = status
        self.description = description
        self.symbol = symbol
        self.color = color
        self.isInline = isInline
        self.action = action
    }

    var body: some View {
        Group {
            if isInline {
                HStack(alignment: .center, spacing: 12) {
                    stateIcon
                    stateDescription
                    Spacer(minLength: 16)
                    action()
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        stateIcon
                        stateTitle
                        Spacer(minLength: 8)
                        action()
                    }
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }

    private var stateIcon: some View {
        Image(systemName: symbol)
            .font(.title3.weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 30)
            .accessibilityHidden(true)
    }

    private var stateTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(status)
                .font(.callout.weight(.medium))
                .foregroundStyle(color)
        }
    }

    private var stateDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(status)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(color)
            }
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OverviewMetricCell: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

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
}

private struct OverviewTrafficLegendItem: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewDetailRow<Value: View>: View {
    let title: String
    let presentation: OverviewDetailPresentation
    @ViewBuilder let value: () -> Value

    var body: some View {
        Group {
            if presentation == .row {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    Text(title)
                        .foregroundStyle(.secondary)
                        .frame(width: 118, alignment: .leading)
                    value()
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    value()
                }
            }
        }
        .padding(.vertical, 9)
    }
}
