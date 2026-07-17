import Foundation

/// A privacy-bounded description of the process that originated an App Routing flow.
///
/// Audit tokens, listener credentials, and designated requirements are deliberately
/// absent. Those values are useful while making a trusted decision inside the
/// Network Extension, but the activity channel does not need to export them.
public struct AppRoutingActivitySource: Codable, Hashable, Sendable {
    public let processIdentifier: Int32
    public let processStartTime: ProcessStartTime?
    public let userIdentifier: UInt32
    public let executablePath: String?
    public let bundleIdentifier: String?
    public let signingIdentifier: String?
    public let teamIdentifier: String?

    public init(
        processIdentifier: Int32,
        processStartTime: ProcessStartTime? = nil,
        userIdentifier: UInt32,
        executablePath: String? = nil,
        bundleIdentifier: String? = nil,
        signingIdentifier: String? = nil,
        teamIdentifier: String? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.processStartTime = processStartTime
        self.userIdentifier = userIdentifier
        self.executablePath = executablePath
        self.bundleIdentifier = bundleIdentifier
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

public struct AppRoutingActivityDestination: Codable, Hashable, Sendable {
    public let hostname: String?
    public let ipAddress: String?
    public let port: UInt16

    public init(
        hostname: String? = nil,
        ipAddress: String? = nil,
        port: UInt16
    ) {
        self.hostname = hostname
        self.ipAddress = ipAddress
        self.port = port
    }
}

public enum AppRoutingRelayState: String, Codable, Hashable, Sendable {
    /// Direct, rejected, or fail-open decisions do not create a relay.
    case notApplicable
    case pending
    case connecting
    case ready
    case relaying
    case completed
    case failed
}

/// The latest observable state for one flow handled by App Routing.
///
/// `decision` preserves the rule engine's original result. `configuredAction`
/// records what the matching rule requested, while `effectiveAction` records
/// what the provider actually did after availability checks and fallbacks. The
/// distinction prevents a requested Mihomo route that fell back to direct from
/// being presented as proxied traffic.
public struct AppRoutingActivity: Codable, Hashable, Sendable, Identifiable {
    public let flowIdentifier: UUID
    public var sequence: UInt64
    public let configurationRevision: UInt64
    public let startedAt: Date
    public var endedAt: Date?
    public let source: AppRoutingActivitySource
    public let destination: AppRoutingActivityDestination
    public let transportProtocol: TransportProtocol
    public let decision: FlowTrafficDecision
    public let configuredAction: CaptureAction
    public var effectiveAction: FlowTrafficDisposition
    public let matchedRuleIdentifier: String?
    public let cause: FlowTrafficDecisionReason
    public var relayState: AppRoutingRelayState
    public var relayError: String?
    public var relayLocalPort: UInt16?
    public var uploadBytes: UInt64
    public var downloadBytes: UInt64

    public var id: UUID { flowIdentifier }

    public init(
        flowIdentifier: UUID = UUID(),
        sequence: UInt64 = 0,
        configurationRevision: UInt64,
        startedAt: Date,
        endedAt: Date? = nil,
        source: AppRoutingActivitySource,
        destination: AppRoutingActivityDestination,
        transportProtocol: TransportProtocol,
        decision: FlowTrafficDecision,
        configuredAction: CaptureAction,
        effectiveAction: FlowTrafficDisposition,
        relayState: AppRoutingRelayState,
        relayError: String? = nil,
        relayLocalPort: UInt16? = nil,
        uploadBytes: UInt64 = 0,
        downloadBytes: UInt64 = 0
    ) {
        self.flowIdentifier = flowIdentifier
        self.sequence = sequence
        self.configurationRevision = configurationRevision
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.destination = destination
        self.transportProtocol = transportProtocol
        self.decision = decision
        self.configuredAction = configuredAction
        self.effectiveAction = effectiveAction
        matchedRuleIdentifier = Self.matchedRuleIdentifier(in: decision.reason)
        cause = decision.reason
        self.relayState = relayState
        self.relayError = relayError
        self.relayLocalPort = relayLocalPort
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
    }

    private static func matchedRuleIdentifier(
        in reason: FlowTrafficDecisionReason
    ) -> String? {
        switch reason {
        case let .rule(cause):
            return matchedRuleIdentifier(in: cause)
        case let .mihomoUnavailable(rule, _):
            return matchedRuleIdentifier(in: rule)
        case .captureDisabled, .configurationUnavailable, .contextUnavailable:
            return nil
        }
    }

    private static func matchedRuleIdentifier(in cause: RuleDecisionCause) -> String? {
        guard case let .matchedRule(identifier) = cause else { return nil }
        return identifier
    }
}

/// A cursor page from an activity ring. Activities are ordered by their most
/// recent sequence. Repeated upserts for the same flow are coalesced to its
/// latest state.
public struct AppRoutingActivityBatch: Codable, Hashable, Sendable {
    public let activities: [AppRoutingActivity]
    public let nextCursor: UInt64
    public let droppedBeforeSequence: UInt64?
    public let hasMore: Bool

    public init(
        activities: [AppRoutingActivity],
        nextCursor: UInt64,
        droppedBeforeSequence: UInt64?,
        hasMore: Bool
    ) {
        self.activities = activities
        self.nextCursor = nextCursor
        self.droppedBeforeSequence = droppedBeforeSequence
        self.hasMore = hasMore
    }
}

/// A lock-protected, bounded, last-update-ordered activity store.
///
/// Upserting an existing flow replaces its previous value, assigns a new
/// sequence, and moves it to the newest position. Capacity therefore bounds the
/// number of flow records, not the number of updates. Cursor consumers receive
/// only records changed after their cursor. When capacity eviction creates a
/// gap, `droppedBeforeSequence` tells the consumer that a resynchronization may
/// be required.
public final class BoundedAppRoutingActivityRing: @unchecked Sendable {
    public let capacity: Int

    private let lock = NSLock()
    private var storage: [AppRoutingActivity] = []
    private var nextSequence: UInt64 = 1
    private var droppedBefore: UInt64?

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public var count: Int {
        withLock { storage.count }
    }

    public var latestSequence: UInt64 {
        withLock { nextSequence - 1 }
    }

    public var droppedBeforeSequence: UInt64? {
        withLock { droppedBefore }
    }

    /// Inserts a flow or replaces its previous state and returns the stored
    /// value with the ring-assigned sequence.
    @discardableResult
    public func upsert(_ activity: AppRoutingActivity) -> AppRoutingActivity {
        withLock {
            precondition(nextSequence < UInt64.max, "App Routing activity sequence exhausted")

            if let existingIndex = storage.firstIndex(where: {
                $0.flowIdentifier == activity.flowIdentifier
            }) {
                storage.remove(at: existingIndex)
            }

            var stored = activity
            stored.sequence = nextSequence
            nextSequence += 1

            guard capacity > 0 else {
                markDropped(stored.sequence)
                return stored
            }

            storage.append(stored)
            if storage.count > capacity {
                let removed = storage.removeFirst()
                markDropped(removed.sequence)
            }
            return stored
        }
    }

    public func activity(for flowIdentifier: UUID) -> AppRoutingActivity? {
        withLock {
            storage.first { $0.flowIdentifier == flowIdentifier }
        }
    }

    /// Returns records whose most recent update is newer than `cursor`.
    /// Negative limits are treated as zero; limits above capacity are harmless.
    public func batch(after cursor: UInt64 = 0, limit: Int) -> AppRoutingActivityBatch {
        withLock {
            let boundedLimit = min(max(0, limit), capacity)
            let candidates = storage.filter { $0.sequence > cursor }
            let selected = Array(candidates.prefix(boundedLimit))
            return AppRoutingActivityBatch(
                activities: selected,
                nextCursor: selected.last?.sequence ?? cursor,
                droppedBeforeSequence: droppedBefore,
                hasMore: candidates.count > selected.count
            )
        }
    }

    /// Clears retained records without reusing sequences. Existing cursors can
    /// therefore detect that records were discarded.
    public func removeAll() {
        withLock {
            if let last = storage.last {
                markDropped(last.sequence)
            }
            storage.removeAll(keepingCapacity: true)
        }
    }

    private func markDropped(_ sequence: UInt64) {
        droppedBefore = max(droppedBefore ?? 0, sequence)
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
