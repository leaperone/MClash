import Foundation

enum TrafficHistoryRetention: Int, CaseIterable, Sendable {
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90

    static let `default`: Self = .thirtyDays
}

enum TrafficHistoryMeasurement: Hashable, Sendable {
    case exact(UInt64)
    case notMeasuredAfterHandoff
    case notApplicable
}

enum TrafficHistorySource: String, CaseIterable, Sendable {
    case mihomo
    case appRouting
}

enum TrafficHistoryOutcome: String, CaseIterable, Sendable {
    case viaMihomo
    case direct
    case rejected
    case failOpen
    case relayFailed
    case unresolved
}

/// A deliberately narrow application identity for persistence. Process IDs,
/// user IDs and executable paths are intentionally absent from this type.
struct TrafficHistoryApplication: Hashable, Sendable {
    enum Identity: Hashable, Sendable {
        case bundleIdentifier(String)
        case signingIdentifier(String)
        case unattributed
    }

    let identity: Identity
    let displayName: String

    init(identity: Identity, displayName: String) {
        self.identity = identity.normalized
        self.displayName = trafficHistorySanitizeLabel(displayName, fallback: "Unattributed")
    }

    static let unattributed = TrafficHistoryApplication(
        identity: .unattributed,
        displayName: "Unattributed"
    )

    var storageKey: String {
        switch identity {
        case let .bundleIdentifier(value): "bundle:\(value)"
        case let .signingIdentifier(value): "signing:\(value)"
        case .unattributed: "unattributed"
        }
    }

    var bundleIdentifier: String? {
        guard case let .bundleIdentifier(value) = identity else { return nil }
        return value
    }

    var signingIdentifier: String? {
        guard case let .signingIdentifier(value) = identity else { return nil }
        return value
    }
}

private extension TrafficHistoryApplication.Identity {
    var normalized: Self {
        switch self {
        case let .bundleIdentifier(value):
            let value = trafficHistorySanitizeIdentifier(value)
            return value.isEmpty ? .unattributed : .bundleIdentifier(value)
        case let .signingIdentifier(value):
            let value = trafficHistorySanitizeIdentifier(value)
            return value.isEmpty ? .unattributed : .signingIdentifier(value)
        case .unattributed:
            return .unattributed
        }
    }
}

enum TrafficHistoryRouteKind: String, CaseIterable, Sendable {
    case mihomo
    case direct
    case rejected
    case failOpen
    case relayFailed
    case unresolved
}

/// A route explanation without destination data or rule payloads. Rule names
/// and proxy group/node names are useful operational labels; arbitrary rule
/// payload text is intentionally not accepted.
struct TrafficHistoryRoute: Hashable, Sendable {
    let kind: TrafficHistoryRouteKind
    let displayName: String
    let ruleName: String?
    let proxyChain: [String]

    init(
        kind: TrafficHistoryRouteKind,
        displayName: String,
        ruleName: String? = nil,
        proxyChain: [String] = []
    ) {
        self.kind = kind
        self.displayName = trafficHistorySanitizeLabel(displayName, fallback: kind.defaultLabel)
        self.ruleName = ruleName.flatMap {
            let value = trafficHistorySanitizeLabel($0, fallback: "")
            return value.isEmpty ? nil : value
        }
        self.proxyChain = Array(proxyChain.prefix(16)).compactMap {
            let value = trafficHistorySanitizeLabel($0, fallback: "")
            return value.isEmpty ? nil : value
        }
    }

    static let unresolved = TrafficHistoryRoute(kind: .unresolved, displayName: "Unresolved")

    var storageKey: String {
        ([kind.rawValue, ruleName ?? ""] + proxyChain).joined(separator: "\u{1f}")
    }
}

private extension TrafficHistoryRouteKind {
    var defaultLabel: String {
        switch self {
        case .mihomo: "Mihomo"
        case .direct: "Direct"
        case .rejected: "Rejected"
        case .failOpen: "Fail-open"
        case .relayFailed: "Relay failed"
        case .unresolved: "Unresolved"
        }
    }
}

struct TrafficHistoryCompletedFlow: Hashable, Sendable {
    /// An opaque source-local identifier used only for durable de-duplication.
    let checkpointIdentifier: String
    let source: TrafficHistorySource
    let completedAt: Date
    let application: TrafficHistoryApplication
    let route: TrafficHistoryRoute
    let outcome: TrafficHistoryOutcome
    let upload: TrafficHistoryMeasurement
    let download: TrafficHistoryMeasurement

    init(
        checkpointIdentifier: String,
        source: TrafficHistorySource,
        completedAt: Date,
        application: TrafficHistoryApplication = .unattributed,
        route: TrafficHistoryRoute = .unresolved,
        outcome: TrafficHistoryOutcome,
        upload: TrafficHistoryMeasurement,
        download: TrafficHistoryMeasurement
    ) {
        self.checkpointIdentifier = trafficHistorySanitizeCheckpoint(checkpointIdentifier)
        self.source = source
        self.completedAt = completedAt
        self.application = application
        self.route = route
        self.outcome = outcome
        self.upload = upload
        self.download = download
    }
}

struct TrafficHistorySourceCheckpoint: Hashable, Sendable {
    let source: TrafficHistorySource
    let sequence: Int64

    init(source: TrafficHistorySource, sequence: Int64) {
        self.source = source
        self.sequence = max(0, sequence)
    }
}

struct TrafficHistoryIngestResult: Equatable, Sendable {
    let insertedCount: Int
    let duplicateCount: Int
    let beforeBaselineCount: Int
}

enum TrafficHistoryPeriod: Equatable, Sendable {
    case today
    case week
}

struct TrafficHistoryCoverage: Equatable, Sendable {
    let exactDirectionCount: UInt64
    let notMeasuredDirectionCount: UInt64
    let notApplicableDirectionCount: UInt64

    var measurableDirectionCount: UInt64 {
        trafficHistorySaturatingAdd(exactDirectionCount, notMeasuredDirectionCount)
    }

    /// Coverage excludes directions where payload bytes do not apply, such as
    /// rejected flows. `nil` means there was no measurable traffic.
    var measuredFraction: Double? {
        let denominator = measurableDirectionCount
        guard denominator > 0 else { return nil }
        return Double(exactDirectionCount) / Double(denominator)
    }
}

struct TrafficHistoryTotals: Equatable, Sendable {
    let completedFlowCount: UInt64
    let exactUploadBytes: UInt64
    let exactDownloadBytes: UInt64
    let coverage: TrafficHistoryCoverage

    var exactTotalBytes: UInt64 {
        trafficHistorySaturatingAdd(exactUploadBytes, exactDownloadBytes)
    }
}

struct TrafficHistoryApplicationSnapshot: Equatable, Sendable, Identifiable {
    let application: TrafficHistoryApplication
    let totals: TrafficHistoryTotals

    var id: TrafficHistoryApplication.Identity { application.identity }
}

struct TrafficHistoryRouteSnapshot: Equatable, Sendable, Identifiable {
    let route: TrafficHistoryRoute
    let totals: TrafficHistoryTotals

    var id: String { route.storageKey }
}

struct TrafficHistorySnapshot: Equatable, Sendable {
    let period: TrafficHistoryPeriod
    let interval: DateInterval
    let baseline: TrafficHistoryBaseline
    let totals: TrafficHistoryTotals
    let applications: [TrafficHistoryApplicationSnapshot]
    let routes: [TrafficHistoryRouteSnapshot]
}

struct TrafficHistoryBaseline: Equatable, Sendable {
    let generation: Int64
    let startedAt: Date
}

struct TrafficHistoryStorageDiagnostics: Equatable, Sendable {
    let schemaVersion: Int32
    let journalMode: String
    let synchronousIsFull: Bool
    let foreignKeysEnabled: Bool
    let busyTimeoutMilliseconds: Int32
    let quickCheckPassed: Bool
}

enum TrafficHistoryStoreUnavailableReason: Equatable, Sendable {
    case cannotCreatePrivateDirectory
    case cannotOpenDatabase
    case corruptedDatabase
    case newerSchema(found: Int32, supported: Int32)
    case migrationFailed
}

enum TrafficHistoryStoreOpenResult: Sendable {
    case ready(TrafficHistoryStore)
    case unavailable(TrafficHistoryStoreUnavailableReason)
}

enum TrafficHistoryStoreError: Error, Equatable, Sendable {
    case databaseUnavailable
    case invalidCheckpointIdentifier
    case writeFailed
    case queryFailed
    case maintenanceFailed
}

func trafficHistorySaturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : result
}

private func trafficHistorySanitizeIdentifier(_ value: String) -> String {
    String(
        value.unicodeScalars
            .filter {
                !CharacterSet.controlCharacters.contains($0)
                    && !CharacterSet.whitespacesAndNewlines.contains($0)
            }
            .prefix(255)
    )
}

private func trafficHistorySanitizeLabel(_ value: String, fallback: String) -> String {
    let filtered = String(
        value.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
    )
    let normalized = filtered
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    return String((normalized.isEmpty ? fallback : normalized).prefix(255))
}

private func trafficHistorySanitizeCheckpoint(_ value: String) -> String {
    let filtered = trafficHistorySanitizeIdentifier(value)
    guard !filtered.isEmpty else { return "" }
    // Persist only a stable opaque digest. Source connection identifiers are
    // useful for de-duplication but have no user-facing value and must not
    // become a path for accidentally retaining a token-like source value.
    let bytes = Array(filtered.utf8)
    let first = trafficHistoryFNV1a(bytes, seed: 0xcbf29ce484222325)
    let second = trafficHistoryFNV1a(bytes.reversed(), seed: 0x84222325cbf29ce4)
    return String(format: "%016llx%016llx", first, second)
}

private func trafficHistoryFNV1a<S: Sequence>(
    _ bytes: S,
    seed: UInt64
) -> UInt64 where S.Element == UInt8 {
    bytes.reduce(seed) { hash, byte in
        (hash ^ UInt64(byte)) &* 0x100000001b3
    }
}
