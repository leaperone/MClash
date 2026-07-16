import Observation
import OSLog
import SwiftUI

private let proxyInspectorPerformanceLogger = Logger(
    subsystem: "one.leaper.mclash",
    category: "ProxyInspectorPerformance"
)

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
    @State private var refreshRevision: UInt64 = 0
    @State private var refreshTask: Task<Void, Never>?
    @State private var refreshRequestedWhileRunning = false

    var body: some View {
        let trafficRevision = model.proxyInspectorTrafficRevision
        let connectionMetricsStale = model.degradedStreams.contains(.connections)
        let scope = ProxyInspectorTrafficScope(groupName: groupName, scopeName: scopeName)

        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                refreshImmediately()
            }
            .onChange(of: trafficRevision) { _, _ in
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
        guard refreshTask == nil else {
            refreshRequestedWhileRunning = true
            return
        }
        requestRefresh(debounce: .milliseconds(120))
    }

    private func refreshImmediately() {
        refreshRequestedWhileRunning = false
        requestRefresh(debounce: nil)
    }

    private func cancelPendingRefresh() {
        refreshRevision &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshRequestedWhileRunning = false
    }

    private func requestRefresh(debounce: Duration?) {
        refreshRevision &+= 1
        let revision = refreshRevision

        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            if let debounce {
                do {
                    try await Task.sleep(for: debounce)
                } catch {
                    return
                }
            }

            guard !Task.isCancelled, revision == refreshRevision else { return }

            // Copy value-semantic, Sendable inputs while isolated to the model's MainActor.
            // The detached worker never reads observable model state directly.
            let input = ProxyInspectorTrafficInput(
                connections: model.connections?.connections ?? [],
                entries: model.routeTrafficEntries,
                groupName: groupName,
                scopeName: scopeName
            )
            // Any changes received during the debounce are represented in this
            // snapshot. Only changes that arrive after this point need a follow-up.
            refreshRequestedWhileRunning = false
            let seedAccumulator = accumulator
            let worker = Task.detached(priority: .userInitiated) {
                ProxyInspectorTrafficComputation.compute(
                    revision: revision,
                    input: input,
                    seedAccumulator: seedAccumulator
                )
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled,
                  revision == refreshRevision,
                  let result else {
                if revision == refreshRevision {
                    finishRefresh()
                }
                return
            }

            accumulator = result.accumulator
            presentation.publish(
                result.snapshot,
                stale: model.degradedStreams.contains(.connections)
            )
            finishRefresh()
        }
    }

    private func finishRefresh() {
        refreshTask = nil
        guard refreshRequestedWhileRunning else { return }
        refreshRequestedWhileRunning = false

        // Inputs changed while the detached worker was running. Recompute once
        // immediately from the latest model snapshot instead of losing that edge
        // or repeatedly pushing a debounce window forward under a busy stream.
        requestRefresh(debounce: nil)
    }
}

private struct ProxyInspectorTrafficInput: Sendable {
    let connections: [MihomoConnection]
    let entries: [TrafficAttribution.Entry]
    let groupName: String?
    let scopeName: String?
}

private struct ProxyInspectorTrafficComputation: Sendable {
    let accumulator: ProxyInspectorTrafficAccumulator
    let snapshot: ProxyInspectorTrafficSnapshot

    static func compute(
        revision: UInt64,
        input: ProxyInspectorTrafficInput,
        seedAccumulator: ProxyInspectorTrafficAccumulator
    ) -> Self? {
        let clock = ContinuousClock()
        let startedAt = clock.now
        var accumulator = seedAccumulator

        do {
            let snapshot = try accumulator.snapshot(
                connections: input.connections,
                entries: input.entries,
                groupName: input.groupName,
                scopeName: input.scopeName
            )
            let elapsed = startedAt.duration(to: clock.now)
            proxyInspectorPerformanceLogger.debug(
                "snapshot completed revision=\(revision, privacy: .public) duration_ms=\(elapsed.milliseconds, privacy: .public) connections=\(input.connections.count, privacy: .public) entries=\(input.entries.count, privacy: .public) routes=\(snapshot.routes.count, privacy: .public)"
            )
            return Self(accumulator: accumulator, snapshot: snapshot)
        } catch is CancellationError {
            let elapsed = startedAt.duration(to: clock.now)
            proxyInspectorPerformanceLogger.debug(
                "snapshot cancelled revision=\(revision, privacy: .public) duration_ms=\(elapsed.milliseconds, privacy: .public) connections=\(input.connections.count, privacy: .public) entries=\(input.entries.count, privacy: .public)"
            )
            return nil
        } catch {
            assertionFailure("Proxy inspector aggregation only throws CancellationError")
            return nil
        }
    }
}

private extension Duration {
    var milliseconds: Int64 {
        let components = self.components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000)
        if seconds.overflow {
            return components.seconds.signum() >= 0 ? .max : .min
        }
        let fractionalMilliseconds = components.attoseconds / 1_000_000_000_000_000
        let total = seconds.partialValue.addingReportingOverflow(fractionalMilliseconds)
        if total.overflow {
            return seconds.partialValue.signum() >= 0 ? .max : .min
        }
        return total.partialValue
    }
}

private struct ProxyInspectorTrafficSnapshot: Equatable, Sendable {
    let groupActiveConnections: Int
    let groupObservedBytes: Int64
    let routes: [ObservedRouteSummary]
}

private struct ProxyInspectorTrafficAccumulator: Sendable {
    private struct EntryIdentity: Equatable, Sendable {
        let timestamp: Date
        let connectionID: String

        init(_ entry: TrafficAttribution.Entry) {
            timestamp = entry.timestamp
            connectionID = entry.connectionID
        }
    }

    private struct RouteAggregate: Sendable {
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
    ) throws -> ProxyInspectorTrafficSnapshot {
        try Task.checkCancellation()
        if cachedGroupName != groupName || cachedScopeName != scopeName {
            reset(groupName: groupName, scopeName: scopeName)
            try append(contentsOf: entries)
            sourceEntries = entries
        } else {
            try reconcile(entries)
        }

        let activeConnections: Int
        if let groupName {
            var count = 0
            for (offset, connection) in connections.enumerated() {
                if offset.isMultiple(of: 64) { try Task.checkCancellation() }
                if connection.chains.contains(groupName) { count += 1 }
            }
            activeConnections = count
        } else {
            activeConnections = 0
        }

        try Task.checkCancellation()
        return ProxyInspectorTrafficSnapshot(
            groupActiveConnections: activeConnections,
            groupObservedBytes: groupObservedBytes,
            routes: try topRoutes()
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

    private mutating func reconcile(_ entries: [TrafficAttribution.Entry]) throws {
        guard !sourceEntries.isEmpty else {
            try append(contentsOf: entries)
            sourceEntries = entries
            return
        }
        guard let firstEntry = entries.first else {
            reset(groupName: cachedGroupName, scopeName: cachedScopeName)
            return
        }

        let firstIdentity = EntryIdentity(firstEntry)
        var overlapStart: Int?
        for (offset, entry) in sourceEntries.enumerated() {
            if offset.isMultiple(of: 64) { try Task.checkCancellation() }
            if EntryIdentity(entry) == firstIdentity {
                overlapStart = offset
                break
            }
        }
        guard let overlapStart else {
            try rebuild(from: entries)
            return
        }

        let overlapCount = sourceEntries.count - overlapStart
        guard overlapCount <= entries.count else {
            try rebuild(from: entries)
            return
        }

        for offset in 0..<overlapCount {
            if offset.isMultiple(of: 64) { try Task.checkCancellation() }
            if EntryIdentity(sourceEntries[overlapStart + offset]) != EntryIdentity(entries[offset]) {
                try rebuild(from: entries)
                return
            }
        }

        for (offset, entry) in sourceEntries[..<overlapStart].enumerated() {
            if offset.isMultiple(of: 64) { try Task.checkCancellation() }
            guard remove(entry) else {
                try rebuild(from: entries)
                return
            }
        }
        try append(contentsOf: entries.dropFirst(overlapCount))
        sourceEntries = entries
    }

    private mutating func rebuild(from entries: [TrafficAttribution.Entry]) throws {
        let groupName = cachedGroupName
        let scopeName = cachedScopeName
        reset(groupName: groupName, scopeName: scopeName)
        try append(contentsOf: entries)
        sourceEntries = entries
    }

    private mutating func append<S: Sequence>(contentsOf entries: S) throws
    where S.Element == TrafficAttribution.Entry {
        for (offset, entry) in entries.enumerated() {
            if offset.isMultiple(of: 64) { try Task.checkCancellation() }
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

    private mutating func topRoutes() throws -> [ObservedRouteSummary] {
        guard routesDirty else { return cachedRoutes }

        var routes: [ObservedRouteSummary] = []
        routes.reserveCapacity(8)
        for (offset, aggregate) in routeAggregates.values.enumerated() {
            if offset.isMultiple(of: 64) { try Task.checkCancellation() }
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

private struct ObservedRouteSummary: Equatable, Identifiable, Sendable {
    struct Key: Hashable, Sendable {
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
