import Foundation

/// Turns mihomo's cumulative per-connection counters into bounded traffic deltas.
public struct TrafficAttribution: Sendable {
    public struct Entry: Equatable, Sendable {
        public let timestamp: Date
        public let connectionID: String
        public let routing: RoutingExplanation
        public let uploadDelta: Int64
        public let downloadDelta: Int64

        public var explanation: RoutingExplanation { routing }
        public var upload: Int64 { uploadDelta }
        public var download: Int64 { downloadDelta }
        public var totalDelta: Int64 {
            let (total, overflow) = uploadDelta.addingReportingOverflow(downloadDelta)
            return overflow ? Int64.max : total
        }

        public init(
            timestamp: Date,
            connectionID: String,
            routing: RoutingExplanation,
            uploadDelta: Int64,
            downloadDelta: Int64
        ) {
            self.timestamp = timestamp
            self.connectionID = connectionID
            self.routing = routing
            self.uploadDelta = uploadDelta
            self.downloadDelta = downloadDelta
        }
    }

    public let window: TimeInterval
    public let maxEntries: Int
    public private(set) var entries: [Entry]

    private struct Baseline: Sendable {
        let upload: Int64
        let download: Int64
    }

    private var baselines: [String: Baseline]
    private var activeGeneration: Int?

    public init(window: TimeInterval = 5 * 60, maxEntries: Int = 500) {
        self.window = max(0, window)
        self.maxEntries = max(0, maxEntries)
        entries = []
        baselines = [:]
        activeGeneration = nil
    }

    /// Ingests one complete connection snapshot and returns only the new delta entries.
    @discardableResult
    public mutating func ingest(
        connections: [MihomoConnection],
        at timestamp: Date = Date(),
        generation: Int = 0
    ) -> [Entry] {
        if let activeGeneration, activeGeneration != generation {
            baselines.removeAll(keepingCapacity: true)
            entries.removeAll(keepingCapacity: true)
        }
        activeGeneration = generation

        prune(at: timestamp)

        let latestIndexes = connections.enumerated().reduce(into: [String: Int]()) { result, item in
            result[item.element.id] = item.offset
        }
        var nextBaselines: [String: Baseline] = [:]
        nextBaselines.reserveCapacity(latestIndexes.count)
        var additions: [Entry] = []

        for (index, connection) in connections.enumerated()
        where latestIndexes[connection.id] == index {
            let current = Baseline(
                upload: Self.normalizedCounter(connection.upload),
                download: Self.normalizedCounter(connection.download)
            )
            nextBaselines[connection.id] = current

            guard let previous = baselines[connection.id] else { continue }

            let uploadDelta = Self.delta(current.upload, since: previous.upload)
            let downloadDelta = Self.delta(current.download, since: previous.download)
            guard uploadDelta > 0 || downloadDelta > 0 else { continue }

            additions.append(
                Entry(
                    timestamp: timestamp,
                    connectionID: connection.id,
                    routing: RoutingExplanation(connection: connection),
                    uploadDelta: uploadDelta,
                    downloadDelta: downloadDelta
                )
            )
        }

        baselines = nextBaselines
        entries.append(contentsOf: additions)
        enforceEntryLimit()
        return additions
    }

    public mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        baselines.removeAll(keepingCapacity: true)
        activeGeneration = nil
    }

    private static func normalizedCounter(_ counter: Int64) -> Int64 {
        max(0, counter)
    }

    private static func delta(_ current: Int64, since previous: Int64) -> Int64 {
        guard current >= previous else { return 0 }
        return current - previous
    }

    private mutating func prune(at timestamp: Date) {
        let cutoff = timestamp.addingTimeInterval(-window)
        entries.removeAll { $0.timestamp < cutoff }
        enforceEntryLimit()
    }

    private mutating func enforceEntryLimit() {
        if maxEntries == 0 {
            entries.removeAll(keepingCapacity: true)
        } else if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }
}
