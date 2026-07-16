import SwiftUI

struct ProxyInspectorView: View {
    @Bindable var model: AppModel
    let group: MihomoProxy?
    let focusedNodeName: String?
    let openGroup: (String) -> Void

    var body: some View {
        let traffic = ProxyInspectorTrafficSnapshot(
            model: model,
            groupName: group?.name,
            scopeName: trafficScopeName
        )
        let routes = traffic.routes

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                inspectorHeader

                if let group {
                    InspectorSection("Current Route") {
                        if let path = model.proxySelectionPaths[group.name] {
                            ProxyPathDetail(path: path, topology: model.proxyTopology)
                        } else {
                            Text("No current route is available.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    InspectorSection("Group") {
                        InspectorValueRow("Type", value: group.type)
                        InspectorValueRow("Members", value: formattedCount(group.all.count))
                        InspectorValueRow(
                            "Active Connections",
                            value: connectionMetricsStale
                                ? "Stale"
                                : formattedCount(traffic.groupActiveConnections)
                        )
                        InspectorValueRow(
                            "Observed Traffic",
                            value: connectionMetricsStale
                                ? "Stale"
                                : formattedByteCount(traffic.groupObservedBytes)
                        )
                        if let fixed = group.fixedOverride {
                            InspectorValueRow("Pinned Preference", value: fixed)
                        }
                    }
                }

                if let node = focusedNode {
                    InspectorSection("Focused Node") {
                        InspectorValueRow("Name", value: node.name)
                        InspectorValueRow("Type", value: node.type)
                        if let provider = normalized(node.providerName) {
                            InspectorValueRow("Provider", value: provider)
                        }
                        if let group {
                            InspectorValueRow(
                                "Latency",
                                value: model.proxyDelay(for: node.name, in: group.name)
                                    .map { "\($0) ms" } ?? "Not tested"
                            )
                        }
                        InspectorValueRow(
                            "Status",
                            value: model.proxyAlive(for: node.name, in: group?.name) == false
                                ? "Unavailable"
                                : "Available"
                        )
                        if let dialer = normalized(node.dialerProxy) {
                            InspectorValueRow("Dialer Dependency", value: dialer)
                        }

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 52), spacing: 6)],
                            alignment: .leading,
                            spacing: 6
                        ) {
                            if node.udp { capability("UDP") }
                            if node.tcpFastOpen { capability("TFO") }
                            if node.multipathTCP { capability("MPTCP") }
                            if node.smux { capability("SMUX") }
                        }

                        if model.proxyTopology.vertices[node.name]?.isGroup == true {
                            Button("Open Nested Group") { openGroup(node.name) }
                        }
                    }
                }

                InspectorSection("Observed Traffic", showsDivider: false) {
                    if connectionMetricsStale {
                        Label(
                            "Connection data is stale while the live stream reconnects.",
                            systemImage: "arrow.clockwise"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    Text(
                        "Actual routes observed during the last five minutes. "
                            + "Showing up to eight routes with the most traffic."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if routes.isEmpty {
                        Text("No matching traffic has been observed yet.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(routes) { route in
                                ObservedRouteRow(
                                    route: route,
                                    maximumBytes: routes.first?.totalBytes ?? route.totalBytes
                                )
                                if route.id != routes.last?.id {
                                    Divider()
                                        .padding(.vertical, 9)
                                }
                            }
                        }
                    }
                }
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityLabel("Proxy inspector")
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group?.name ?? "Proxy Inspector")
                .font(.headline)
                .lineLimit(2)
            Text(focusedNodeName.map { "Inspecting \($0)" } ?? "Select a node to inspect it")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var focusedNode: MihomoProxy? {
        focusedNodeName.flatMap { model.proxiesByName[$0] }
    }

    private var trafficScopeName: String? {
        focusedNodeName ?? group?.name
    }

    private var connectionMetricsStale: Bool {
        model.degradedStreams.contains(.connections)
    }

    private func capability(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }
}

private struct ProxyInspectorTrafficSnapshot {
    let groupActiveConnections: Int
    let groupObservedBytes: Int64
    let routes: [ObservedRouteSummary]

    @MainActor
    init(model: AppModel, groupName: String?, scopeName: String?) {
        if let groupName {
            groupActiveConnections = model.connections?.connections.reduce(into: 0) { count, connection in
                if connection.chains.contains(groupName) { count += 1 }
            } ?? 0
        } else {
            groupActiveConnections = 0
        }

        var groupObservedBytes: Int64 = 0
        var summaries: [ObservedRouteSummary.Key: ObservedRouteSummary] = [:]
        for entry in model.routeTrafficEntries {
            if let groupName, entry.routing.chains.contains(groupName) {
                groupObservedBytes = addingTraffic(groupObservedBytes, entry.totalDelta)
            }

            guard let scopeName, entry.routing.chains.contains(scopeName) else { continue }
            let key = ObservedRouteSummary.Key(
                destination: entry.routing.destination,
                rule: entry.routing.rule,
                rulePayload: entry.routing.rulePayload,
                chains: entry.routing.chains
            )
            var summary = summaries[key] ?? ObservedRouteSummary(key: key)
            summary.upload = addingTraffic(summary.upload, entry.uploadDelta)
            summary.download = addingTraffic(summary.download, entry.downloadDelta)
            summary.lastSeen = max(summary.lastSeen, entry.timestamp)
            summaries[key] = summary
        }
        self.groupObservedBytes = groupObservedBytes
        routes = summaries.values
            .sorted { lhs, rhs in
                if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
                if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
                return lhs.destination.localizedStandardCompare(rhs.destination) == .orderedAscending
            }
            .prefix(8)
            .map { $0 }
    }
}

private struct InspectorValueRow: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            LabeledContent(title) {
                Text(value)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .lineLimit(3)
            }
        }
        .help(value)
        .textSelection(.enabled)
    }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    let showsDivider: Bool
    @ViewBuilder let content: Content

    init(
        _ title: String,
        showsDivider: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.showsDivider = showsDivider
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider()
                    .offset(y: 10)
            }
        }
    }
}

private struct ProxyPathDetail: View {
    let path: ProxySelectionPath
    let topology: ProxyTopology

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(path.route.enumerated()), id: \.offset) { index, name in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle()
                                .fill(index == path.route.count - 1
                                    ? Color.accentColor
                                    : Color(nsColor: .controlBackgroundColor))
                                .frame(width: 22, height: 22)
                            Image(systemName: pathSymbol(name))
                                .font(.caption2)
                                .foregroundStyle(
                                    index == path.route.count - 1 ? Color.white : Color.secondary
                                )
                        }
                        if index < path.route.count - 1 {
                            Rectangle()
                                .fill(Color(nsColor: .separatorColor))
                                .frame(width: 1, height: 22)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.callout.weight(index == 0 ? .semibold : .regular))
                            .lineLimit(1)
                            .help(name)
                        Text(stepDescription(after: index))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, index < path.route.count - 1 ? 8 : 0)
                }
            }

            if let issue = path.issue {
                Label(issueDescription(issue), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            } else {
                Label(certaintyDescription, systemImage: certaintySymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }

            if !path.dialerHops.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(path.dialerHops.enumerated()), id: \.offset) { _, hop in
                        Label(
                            dialerDescription(hop),
                            systemImage: "link"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
                .padding(.top, 8)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func pathSymbol(_ name: String) -> String {
        topology.vertices[name]?.isGroup == true
            ? "point.3.connected.trianglepath.dotted"
            : "network"
    }

    private func stepDescription(after index: Int) -> String {
        guard path.selectionHops.indices.contains(index) else { return "Final outlet" }
        let hop = path.selectionHops[index]
        return switch hop.kind {
        case let .selection(decision): decision.description
        case .dialer, .dialerSelection: "Dialer dependency"
        }
    }

    private var certaintyDescription: String {
        switch path.certainty {
        case .deterministic: "Configured route"
        case .automatic: "Current automatic route"
        case .perConnection: "The final route varies by connection"
        }
    }

    private var certaintySymbol: String {
        switch path.certainty {
        case .deterministic: "checkmark.circle"
        case .automatic: "arrow.triangle.2.circlepath"
        case .perConnection: "arrow.triangle.branch"
        }
    }

    private func dialerDescription(_ hop: ProxySelectionHop) -> String {
        switch hop.kind {
        case .dialer:
            "\(hop.source) uses \(hop.target) as its dialer dependency"
        case .dialerSelection:
            "Dialer group \(hop.source) currently selects \(hop.target)"
        case .selection:
            "\(hop.source) selects \(hop.target)"
        }
    }
}

private struct ObservedRouteRow: View {
    let route: ObservedRouteSummary
    let maximumBytes: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(route.destination)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(formattedByteCount(route.totalBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(route.ruleDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(route.chains.joined(separator: " → "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            GeometryReader { geometry in
                Capsule()
                    .fill(Color.accentColor.opacity(0.45))
                    .frame(
                        width: geometry.size.width * max(
                            0.04,
                            min(1, Double(route.totalBytes) / Double(max(1, maximumBytes)))
                        ),
                        height: 3
                    )
            }
            .frame(height: 3)

            HStack {
                Label(formattedByteCount(route.download), systemImage: "arrow.down")
                Label(formattedByteCount(route.upload), systemImage: "arrow.up")
                Spacer()
                Text(route.lastSeen, style: .relative)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(route.destination), \(route.ruleDescription), route "
                + "\(route.chains.joined(separator: ", then ")), "
                + "\(formattedByteCount(route.totalBytes)) observed"
        )
    }
}

private struct ObservedRouteSummary: Identifiable {
    struct Key: Hashable {
        let destination: String
        let rule: String
        let rulePayload: String
        let chains: [String]
    }

    let key: Key
    var upload: Int64 = 0
    var download: Int64 = 0
    var lastSeen = Date.distantPast

    var id: Key { key }
    var destination: String { key.destination }
    var chains: [String] { key.chains }
    var totalBytes: Int64 { addingTraffic(upload, download) }

    var ruleDescription: String {
        let type = key.rule.isEmpty ? "Rule" : key.rule
        let payload = key.rulePayload.trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? type : "\(type) · \(payload)"
    }
}

private extension ProxySelectionDecision {
    var description: String {
        switch self {
        case .selector: "Manual selection"
        case .urlTest: "Automatic latency choice"
        case .fallback: "Automatic fallback"
        case .fixedOverride: "Pinned automatic preference"
        case .relay: "Relay sequence"
        case let .automatic(type): "Automatic \(type) choice"
        }
    }
}

private func issueDescription(_ issue: ProxySelectionPathIssue) -> String {
    switch issue {
    case let .rootNotFound(name): "Root group \(name) is unavailable."
    case let .unresolvedReference(name): "Referenced node \(name) is unavailable."
    case let .noSelection(group): "\(group) has no current selection."
    case .cycle: "The configuration contains a recursive proxy dependency."
    case .loadBalance: "Load balancing chooses a route independently for each connection."
    case let .dialerUnresolvedReference(name):
        "Dialer dependency \(name) is unavailable."
    case let .dialerNoSelection(group):
        "Dialer group \(group) has no current selection."
    case .dialerCycle:
        "The configuration contains a recursive dialer dependency."
    case .dialerLoadBalance:
        "The dialer route is selected independently for each connection."
    case .dialerDepthLimit:
        "The dialer dependency chain is too deep to resolve safely."
    }
}

private func addingTraffic(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int64.max : max(0, value)
}
