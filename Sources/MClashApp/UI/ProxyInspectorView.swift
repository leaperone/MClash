import Observation
import SwiftUI

struct ProxyInspectorView: View {
    @Bindable var model: AppModel
    let group: MihomoProxy?
    let focusedNodeName: String?
    let openGroup: (String) -> Void
    @State private var trafficPresentation = ProxyInspectorTrafficPresentation()

    var body: some View {
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
                        ProxyInspectorGroupTrafficRows(presentation: trafficPresentation)
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

                ProxyInspectorObservedTrafficSection(presentation: trafficPresentation)
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            ProxyInspectorTrafficObserver(
                model: model,
                groupName: group?.name,
                scopeName: trafficScopeName,
                presentation: trafficPresentation
            )
        }
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

    private func capability(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }
}

@MainActor
@Observable
private final class ProxyInspectorTrafficPresentation {
    private(set) var groupActiveConnections = 0
    private(set) var groupObservedBytes: Int64 = 0
    private(set) var routes: [ObservedRouteSummary] = []
    private(set) var connectionMetricsStale = false

    func publish(_ snapshot: ProxyInspectorTrafficSnapshot, stale: Bool) {
        if groupActiveConnections != snapshot.groupActiveConnections {
            groupActiveConnections = snapshot.groupActiveConnections
        }
        if groupObservedBytes != snapshot.groupObservedBytes {
            groupObservedBytes = snapshot.groupObservedBytes
        }
        if routes != snapshot.routes {
            routes = snapshot.routes
        }
        if connectionMetricsStale != stale {
            connectionMetricsStale = stale
        }
    }

    func publishStaleState(_ stale: Bool) {
        if connectionMetricsStale != stale {
            connectionMetricsStale = stale
        }
    }
}

private struct ProxyInspectorGroupTrafficRows: View {
    let presentation: ProxyInspectorTrafficPresentation

    var body: some View {
        InspectorValueRow(
            "Active Connections",
            value: presentation.connectionMetricsStale
                ? "Stale"
                : formattedCount(presentation.groupActiveConnections)
        )
        InspectorValueRow(
            "Observed Traffic",
            value: presentation.connectionMetricsStale
                ? "Stale"
                : formattedByteCount(presentation.groupObservedBytes)
        )
    }
}

private struct ProxyInspectorObservedTrafficSection: View {
    let presentation: ProxyInspectorTrafficPresentation

    var body: some View {
        let routes = presentation.routes

        InspectorSection("Observed Traffic", showsDivider: false) {
            if presentation.connectionMetricsStale {
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
}

private struct ProxyInspectorTrafficScope: Equatable {
    let groupName: String?
    let scopeName: String?
}

private struct ProxyInspectorTrafficObserver: View {
    @Bindable var model: AppModel
    let groupName: String?
    let scopeName: String?
    let presentation: ProxyInspectorTrafficPresentation
    @State private var accumulator = ProxyInspectorTrafficAccumulator()
    @State private var pendingRefreshTask: Task<Void, Never>?

    var body: some View {
        let connectionSnapshot = model.connections
        let routeTrafficEntries = model.routeTrafficEntries
        let connectionMetricsStale = model.degradedStreams.contains(.connections)
        let scope = ProxyInspectorTrafficScope(groupName: groupName, scopeName: scopeName)

        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                refreshImmediately()
            }
            .onChange(of: connectionSnapshot) { _, _ in
                scheduleRefresh()
            }
            .onChange(of: routeTrafficEntries) { _, _ in
                scheduleRefresh()
            }
            .onChange(of: connectionMetricsStale) { _, stale in
                presentation.publishStaleState(stale)
            }
            .onChange(of: scope) { _, _ in
                refreshImmediately()
            }
            .onDisappear {
                cancelPendingRefresh()
            }
    }

    private func scheduleRefresh() {
        guard pendingRefreshTask == nil else { return }
        pendingRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            publishLatestSnapshot()
            pendingRefreshTask = nil
        }
    }

    private func refreshImmediately() {
        cancelPendingRefresh()
        publishLatestSnapshot()
    }

    private func cancelPendingRefresh() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
    }

    private func publishLatestSnapshot() {
        let snapshot = accumulator.snapshot(
            connections: model.connections?.connections ?? [],
            entries: model.routeTrafficEntries,
            groupName: groupName,
            scopeName: scopeName
        )
        presentation.publish(
            snapshot,
            stale: model.degradedStreams.contains(.connections)
        )
    }
}

private struct ProxyInspectorTrafficSnapshot: Equatable {
    let groupActiveConnections: Int
    let groupObservedBytes: Int64
    let routes: [ObservedRouteSummary]
}

private struct ProxyInspectorTrafficAccumulator {
    private struct EntryIdentity: Equatable {
        let timestamp: Date
        let connectionID: String

        init(_ entry: TrafficAttribution.Entry) {
            timestamp = entry.timestamp
            connectionID = entry.connectionID
        }
    }

    private struct RouteAggregate {
        let key: ObservedRouteSummary.Key
        var upload: Int64
        var download: Int64
        var lastSeen: Date
        var entryCount: Int

        var summary: ObservedRouteSummary {
            ObservedRouteSummary(
                key: key,
                upload: upload,
                download: download,
                lastSeen: lastSeen
            )
        }
    }

    private var cachedGroupName: String?
    private var cachedScopeName: String?
    private var sourceEntries: [TrafficAttribution.Entry] = []
    private var groupObservedBytes: Int64 = 0
    private var routeAggregates: [ObservedRouteSummary.Key: RouteAggregate] = [:]
    private var cachedRoutes: [ObservedRouteSummary] = []
    private var routesDirty = false

    mutating func snapshot(
        connections: [MihomoConnection],
        entries: [TrafficAttribution.Entry],
        groupName: String?,
        scopeName: String?
    ) -> ProxyInspectorTrafficSnapshot {
        if cachedGroupName != groupName || cachedScopeName != scopeName {
            reset(groupName: groupName, scopeName: scopeName)
            append(contentsOf: entries)
            sourceEntries = entries
        } else {
            reconcile(entries)
        }

        let activeConnections: Int
        if let groupName {
            activeConnections = connections.reduce(into: 0) { count, connection in
                if connection.chains.contains(groupName) { count += 1 }
            }
        } else {
            activeConnections = 0
        }

        return ProxyInspectorTrafficSnapshot(
            groupActiveConnections: activeConnections,
            groupObservedBytes: groupObservedBytes,
            routes: topRoutes()
        )
    }

    private mutating func reset(groupName: String?, scopeName: String?) {
        cachedGroupName = groupName
        cachedScopeName = scopeName
        sourceEntries.removeAll(keepingCapacity: true)
        groupObservedBytes = 0
        routeAggregates.removeAll(keepingCapacity: true)
        cachedRoutes.removeAll(keepingCapacity: true)
        routesDirty = false
    }

    private mutating func reconcile(_ entries: [TrafficAttribution.Entry]) {
        guard !sourceEntries.isEmpty else {
            append(contentsOf: entries)
            sourceEntries = entries
            return
        }
        guard let firstEntry = entries.first else {
            reset(groupName: cachedGroupName, scopeName: cachedScopeName)
            return
        }

        let firstIdentity = EntryIdentity(firstEntry)
        guard let overlapStart = sourceEntries.firstIndex(where: {
            EntryIdentity($0) == firstIdentity
        }) else {
            rebuild(from: entries)
            return
        }

        let overlapCount = sourceEntries.count - overlapStart
        guard overlapCount <= entries.count,
              zip(sourceEntries[overlapStart...], entries.prefix(overlapCount)).allSatisfy({
                  EntryIdentity($0.0) == EntryIdentity($0.1)
              }) else {
            rebuild(from: entries)
            return
        }

        for entry in sourceEntries[..<overlapStart] {
            guard remove(entry) else {
                rebuild(from: entries)
                return
            }
        }
        append(contentsOf: entries.dropFirst(overlapCount))
        sourceEntries = entries
    }

    private mutating func rebuild(from entries: [TrafficAttribution.Entry]) {
        let groupName = cachedGroupName
        let scopeName = cachedScopeName
        reset(groupName: groupName, scopeName: scopeName)
        append(contentsOf: entries)
        sourceEntries = entries
    }

    private mutating func append<S: Sequence>(contentsOf entries: S)
    where S.Element == TrafficAttribution.Entry {
        for entry in entries {
            add(entry)
        }
    }

    private mutating func add(_ entry: TrafficAttribution.Entry) {
        if let cachedGroupName, entry.routing.chains.contains(cachedGroupName) {
            groupObservedBytes = addingTraffic(groupObservedBytes, entry.totalDelta)
        }

        guard let cachedScopeName, entry.routing.chains.contains(cachedScopeName) else {
            return
        }

        let key = routeKey(for: entry)
        if var aggregate = routeAggregates[key] {
            aggregate.upload = addingTraffic(aggregate.upload, entry.uploadDelta)
            aggregate.download = addingTraffic(aggregate.download, entry.downloadDelta)
            aggregate.lastSeen = max(aggregate.lastSeen, entry.timestamp)
            aggregate.entryCount += 1
            routeAggregates[key] = aggregate
        } else {
            routeAggregates[key] = RouteAggregate(
                key: key,
                upload: max(0, entry.uploadDelta),
                download: max(0, entry.downloadDelta),
                lastSeen: entry.timestamp,
                entryCount: 1
            )
        }
        routesDirty = true
    }

    @discardableResult
    private mutating func remove(_ entry: TrafficAttribution.Entry) -> Bool {
        if let cachedGroupName, entry.routing.chains.contains(cachedGroupName) {
            groupObservedBytes = subtractingTraffic(groupObservedBytes, entry.totalDelta)
        }

        guard let cachedScopeName, entry.routing.chains.contains(cachedScopeName) else {
            return true
        }

        let key = routeKey(for: entry)
        guard var aggregate = routeAggregates[key] else {
            return false
        }
        if aggregate.entryCount <= 1 {
            routeAggregates.removeValue(forKey: key)
        } else {
            aggregate.upload = subtractingTraffic(aggregate.upload, entry.uploadDelta)
            aggregate.download = subtractingTraffic(aggregate.download, entry.downloadDelta)
            aggregate.entryCount -= 1
            routeAggregates[key] = aggregate
        }
        routesDirty = true
        return true
    }

    private func routeKey(for entry: TrafficAttribution.Entry) -> ObservedRouteSummary.Key {
        ObservedRouteSummary.Key(
            destination: entry.routing.destination,
            rule: entry.routing.rule,
            rulePayload: entry.routing.rulePayload,
            chains: entry.routing.chains
        )
    }

    private mutating func topRoutes() -> [ObservedRouteSummary] {
        guard routesDirty else { return cachedRoutes }

        var routes: [ObservedRouteSummary] = []
        routes.reserveCapacity(8)
        for aggregate in routeAggregates.values {
            let summary = aggregate.summary
            let insertionIndex = routes.firstIndex {
                routeRanksBefore(summary, $0)
            } ?? routes.endIndex
            guard insertionIndex < 8 else { continue }
            routes.insert(summary, at: insertionIndex)
            if routes.count > 8 {
                routes.removeLast()
            }
        }
        cachedRoutes = routes
        routesDirty = false
        return routes
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

private struct ObservedRouteSummary: Equatable, Identifiable {
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

private func subtractingTraffic(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let normalizedRHS = max(0, rhs)
    guard lhs >= normalizedRHS else { return 0 }
    return lhs - normalizedRHS
}

private func routeRanksBefore(
    _ lhs: ObservedRouteSummary,
    _ rhs: ObservedRouteSummary
) -> Bool {
    if lhs.totalBytes != rhs.totalBytes { return lhs.totalBytes > rhs.totalBytes }
    if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
    let destinationOrder = lhs.destination.localizedStandardCompare(rhs.destination)
    if destinationOrder != .orderedSame { return destinationOrder == .orderedAscending }
    let ruleOrder = lhs.key.rule.localizedStandardCompare(rhs.key.rule)
    if ruleOrder != .orderedSame { return ruleOrder == .orderedAscending }
    let payloadOrder = lhs.key.rulePayload.localizedStandardCompare(rhs.key.rulePayload)
    if payloadOrder != .orderedSame { return payloadOrder == .orderedAscending }
    return lhs.chains.lexicographicallyPrecedes(rhs.chains)
}
