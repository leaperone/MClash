import Charts
import SwiftUI

struct OverviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                networkStateSection

                if model.liveMetricsAreDegraded {
                    liveDataNotice
                }

                liveSessionSection
                trafficChartSection
                sessionDetailsSection
            }
            .padding(32)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .navigationTitle("Overview")
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var networkStateSection: some View {
        GroupBox {
            VStack(spacing: 0) {
                StateRow(
                    title: "mihomo Core",
                    status: coreStatusTitle,
                    description: coreStatusDescription,
                    symbol: coreStatusSymbol,
                    color: coreStatusColor
                ) {
                    Button {
                        Task { await model.toggleConnection() }
                    } label: {
                        HStack(spacing: 7) {
                            if model.isBusy || model.isPerforming(.connection) {
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
                    .padding(.leading, 42)

                StateRow(
                    title: "macOS System Proxy",
                    status: systemProxyStatusTitle,
                    description: systemProxyStatusDescription,
                    symbol: systemProxyStatusSymbol,
                    color: systemProxyStatusColor
                ) {
                    Button(systemProxyActionTitle) {
                        Task {
                            if model.systemProxyRecoveryRequired {
                                await model.disableSystemProxy()
                            } else {
                                await model.setSystemProxyEnabled(!model.systemProxyEnabled)
                            }
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
            }
            .padding(.vertical, 2)
        } label: {
            Label("Network State", systemImage: "network")
        }
    }

    private var liveDataNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Live data is reconnecting")
                    .font(.callout.weight(.medium))
                Text("Traffic, memory, or connection totals may be temporarily stale.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("View Logs") { model.selection = .logs }
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.2))
        }
        .accessibilityElement(children: .contain)
    }

    private var liveSessionSection: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 16) {
                MetricCell(
                    title: "Download",
                    value: rate(model.traffic.download),
                    symbol: "arrow.down",
                    color: .blue
                )
                metricDivider
                MetricCell(
                    title: "Upload",
                    value: rate(model.traffic.upload),
                    symbol: "arrow.up",
                    color: .orange
                )
                metricDivider
                MetricCell(
                    title: "Connections",
                    value: "\(model.connections?.connections.count ?? 0)",
                    symbol: "arrow.left.arrow.right",
                    color: .primary
                )
                metricDivider
                MetricCell(
                    title: "Session Traffic",
                    value: totalTraffic,
                    symbol: "sum",
                    color: .primary
                )
                metricDivider
                MetricCell(
                    title: "Memory",
                    value: memoryUsage,
                    symbol: "memorychip",
                    color: .primary
                )
            }
            .padding(.vertical, 6)
        } label: {
            Label("Live Session", systemImage: "waveform.path.ecg")
        }
    }

    private var metricDivider: some View {
        Divider()
            .frame(height: 42)
    }

    private var trafficChartSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    TrafficLegendItem(
                        title: "Download",
                        value: rate(model.traffic.download),
                        color: .blue
                    )
                    TrafficLegendItem(
                        title: "Upload",
                        value: rate(model.traffic.upload),
                        color: .orange
                    )
                    Spacer()
                    Text("Recent activity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.trafficHistory.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Text(model.isConnected ? "Waiting for traffic samples…" : "Connect to view live traffic")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 190)
                } else {
                    Chart(model.trafficHistory, id: \.timestamp) { sample in
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

                        if model.trafficHistory.count == 1 {
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
                                    Text(compactRate(bytes))
                                }
                            }
                        }
                    }
                    .frame(height: 220)
                    .accessibilityLabel("Recent network traffic")
                    .accessibilityValue(
                        "Download \(rate(model.traffic.download)), upload \(rate(model.traffic.upload))"
                    )
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Traffic", systemImage: "chart.xyaxis.line")
        }
    }

    private var sessionDetailsSection: some View {
        GroupBox {
            VStack(spacing: 0) {
                DetailRow(title: "Profile") {
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

                DetailRow(title: "Routing Mode") {
                    Text(routingMode)
                }

                detailDivider

                DetailRow(title: "Primary Group") {
                    HStack(spacing: 10) {
                        Text(primaryGroupSelection)
                            .lineLimit(1)
                        Button("Choose…") { model.selection = .proxies }
                            .controlSize(.small)
                            .disabled(!model.controllerIsReady)
                    }
                }

                detailDivider

                DetailRow(title: "HTTP Proxy") {
                    addressText(model.localHTTPProxyAddress)
                }

                detailDivider

                DetailRow(title: "SOCKS5 Proxy") {
                    addressText(model.localSOCKSProxyAddress)
                }

                if let session = model.runningSession {
                    detailDivider

                    DetailRow(title: "Core Version") {
                        Text(session.version)
                            .monospaced()
                            .textSelection(.enabled)
                    }

                    detailDivider

                    DetailRow(title: "Session Started") {
                        Text(session.startedAt.formatted(date: .abbreviated, time: .standard))
                    }
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Configuration", systemImage: "slider.horizontal.3")
        }
    }

    private var detailDivider: some View {
        Divider()
            .padding(.leading, 138)
    }

    @ViewBuilder
    private func addressText(_ address: String?) -> some View {
        if let address {
            Text(address)
                .monospaced()
                .textSelection(.enabled)
        } else {
            Text("Unavailable")
                .foregroundStyle(.secondary)
        }
    }

    private var coreStatusTitle: String {
        switch model.coreState {
        case .stopped: "Stopped"
        case .validating: "Checking"
        case .starting: "Starting"
        case .running: "Running"
        case .stopping: "Stopping"
        case .failed: "Failed"
        }
    }

    private var coreStatusDescription: String {
        switch model.coreState {
        case .stopped:
            "The local proxy core is not running. Choose a profile, then connect when needed."
        case .validating:
            "MClash is validating the active profile before changing network state."
        case .starting:
            "The core is opening its local proxy ports and controller."
        case let .running(session):
            "The bundled Alpha core is healthy and has been running since \(session.startedAt.formatted(date: .omitted, time: .shortened))."
        case .stopping:
            "MClash is shutting down the core and restoring network state."
        case .failed:
            "The core could not reach a healthy running state. Review the error and logs before retrying."
        }
    }

    private var coreStatusSymbol: String {
        switch model.coreState {
        case .running: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .validating, .starting, .stopping: "arrow.triangle.2.circlepath"
        case .stopped: "stop.circle"
        }
    }

    private var coreStatusColor: Color {
        switch model.coreState {
        case .running: .green
        case .failed: .red
        case .validating, .starting, .stopping: .orange
        case .stopped: .secondary
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
        return model.systemProxyEnabled ? "Turn Off" : "Turn On"
    }

    private var connectionButtonTitle: String {
        switch model.coreState {
        case .running, .starting: "Disconnect"
        case .stopping: "Stopping…"
        case .validating: "Checking…"
        default: "Connect"
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

    private var primaryGroupSelection: String {
        let global = model.proxyGroups.first {
            $0.name.caseInsensitiveCompare("GLOBAL") == .orderedSame
        }
        guard let group = global ?? model.proxyGroups.first else { return "Unavailable" }
        return "\(group.name) → \(group.now ?? "Not selected")"
    }

    private var totalTraffic: String {
        let (total, overflow) = model.traffic.uploadTotal.addingReportingOverflow(
            model.traffic.downloadTotal
        )
        return byteCount(overflow ? Int64.max : total, style: .file)
    }

    private var memoryUsage: String {
        guard let memory = model.connections?.memory else { return "—" }
        return byteCount(Int64(clamping: memory), style: .memory)
    }

    private func rate(_ bytes: Int64) -> String {
        "\(byteCount(bytes, style: .file))/s"
    }

    private func compactRate(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.isAdaptive = true
        formatter.includesUnit = true
        formatter.includesCount = true
        return "\(formatter.string(fromByteCount: max(0, bytes)))/s"
    }

    private func byteCount(_ bytes: Int64, style: ByteCountFormatter.CountStyle) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: style)
    }
}

private struct StateRow<Action: View>: View {
    let title: String
    let status: String
    let description: String
    let symbol: String
    let color: Color
    @ViewBuilder let action: () -> Action

    init(
        title: String,
        status: String,
        description: String,
        symbol: String,
        color: Color,
        @ViewBuilder action: @escaping () -> Action
    ) {
        self.title = title
        self.status = status
        self.description = description
        self.symbol = symbol
        self.color = color
        self.action = action
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 30)
                .accessibilityHidden(true)

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

            Spacer(minLength: 16)
            action()
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}

private extension StateRow where Action == EmptyView {
    init(
        title: String,
        status: String,
        description: String,
        symbol: String,
        color: Color
    ) {
        self.init(
            title: title,
            status: status,
            description: description,
            symbol: symbol,
            color: color
        ) {
            EmptyView()
        }
    }
}

private struct MetricCell: View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct TrafficLegendItem: View {
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

private struct DetailRow<Value: View>: View {
    let title: String
    @ViewBuilder let value: () -> Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
    }
}
