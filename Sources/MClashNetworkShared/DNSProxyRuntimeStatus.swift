import Foundation

/// Shared container locations used by the host app and Network Extension.
///
/// DNS runtime status deliberately lives outside the user-owned profile tree:
/// a system extension cannot rely on the host app's Application Support
/// sandbox, while both signed components are entitled for this App Group.
public enum MClashNetworkExtensionSharedContainer {
    public static let identifier = "5UAHRS482C.one.leaper.mclash"
    public static let dnsProxyStatusFileName = "dns-proxy-status.json"

    public static func dnsProxyStatusURL(
        appGroupIdentifier: String = identifier,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw DNSProxyStatusFileError.appGroupContainerUnavailable(
                identifier: appGroupIdentifier
            )
        }
        return containerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MClash", isDirectory: true)
            .appendingPathComponent("NetworkExtension", isDirectory: true)
            .appendingPathComponent(dnsProxyStatusFileName, isDirectory: false)
    }
}

public enum DNSProxyRuntimePhase: String, Codable, CaseIterable, Sendable {
    case starting
    case running
    case stopping
    case stopped
    case failed
}

/// Coarse, privacy-safe failure information suitable for crossing the process
/// boundary. Free-form error text is intentionally excluded so a destination,
/// DNS question, payload, or credential cannot accidentally be persisted.
public enum DNSProxyFailureCategory: String, Codable, CaseIterable, Sendable {
    case invalidConfiguration
    case sharedContainerUnavailable
    case backendUnavailable
    case tcpRelayFailed
    case udpRelayFailed
    case flowConversionFailed
    case statusPersistenceFailed
    case cancelled
    case unknown
}

/// Bounded operational truth published by the DNS provider.
///
/// The model contains only lifecycle, aggregate counters, and timestamps. It
/// must never grow fields for query names, destination endpoints, packet
/// payloads, process identity, or proxy credentials.
public struct DNSProxyRuntimeStatus: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let defaultMaximumHeartbeatAge: TimeInterval = 6

    public let schemaVersion: Int
    public let revision: UInt64
    public let activationIdentifier: UUID
    public let providerInstanceIdentifier: UUID

    public var phase: DNSProxyRuntimePhase
    public var backendReady: Bool
    public var activeTCPFlows: UInt64
    public var activeUDPFlows: UInt64
    public var totalFlows: UInt64
    public var completedFlows: UInt64
    public var failedFlows: UInt64
    public var uploadBytes: UInt64
    public var downloadBytes: UInt64

    public let startedAt: Date
    /// The provider heartbeat timestamp. Hosts use this field for freshness,
    /// even when no DNS flow is currently active.
    public var updatedAt: Date
    /// Latest successful private SOCKS5 UDP association probe. This proves
    /// reachability of the Mihomo listener, not that a DNS answer was received.
    public var lastBackendAssociationAt: Date?
    /// Latest application payload accepted by the private relay.
    public var lastQueryForwardedAt: Date?
    /// Latest response payload delivered back to a DNS client.
    public var lastResponseDeliveredAt: Date?
    public var lastFailureAt: Date?
    public var failureCategory: DNSProxyFailureCategory?

    public init(
        revision: UInt64,
        activationIdentifier: UUID,
        providerInstanceIdentifier: UUID = UUID(),
        phase: DNSProxyRuntimePhase,
        backendReady: Bool,
        activeTCPFlows: UInt64 = 0,
        activeUDPFlows: UInt64 = 0,
        totalFlows: UInt64 = 0,
        completedFlows: UInt64 = 0,
        failedFlows: UInt64 = 0,
        uploadBytes: UInt64 = 0,
        downloadBytes: UInt64 = 0,
        startedAt: Date,
        updatedAt: Date? = nil,
        lastBackendAssociationAt: Date? = nil,
        lastQueryForwardedAt: Date? = nil,
        lastResponseDeliveredAt: Date? = nil,
        lastFailureAt: Date? = nil,
        failureCategory: DNSProxyFailureCategory? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.revision = revision
        self.activationIdentifier = activationIdentifier
        self.providerInstanceIdentifier = providerInstanceIdentifier
        self.phase = phase
        self.backendReady = backendReady
        self.activeTCPFlows = activeTCPFlows
        self.activeUDPFlows = activeUDPFlows
        self.totalFlows = totalFlows
        self.completedFlows = completedFlows
        self.failedFlows = failedFlows
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
        self.lastBackendAssociationAt = lastBackendAssociationAt
        self.lastQueryForwardedAt = lastQueryForwardedAt
        self.lastResponseDeliveredAt = lastResponseDeliveredAt
        self.lastFailureAt = lastFailureAt
        self.failureCategory = failureCategory
    }

    public var activeFlows: UInt64 {
        let (value, overflow) = activeTCPFlows.addingReportingOverflow(activeUDPFlows)
        return overflow ? .max : value
    }

    public var isOperational: Bool {
        phase == .running && backendReady
    }

    public mutating func recordHeartbeat(at date: Date = Date()) {
        updatedAt = date
    }

    public func isFresh(
        at date: Date = Date(),
        maximumAge: TimeInterval = Self.defaultMaximumHeartbeatAge
    ) -> Bool {
        guard maximumAge.isFinite, maximumAge >= 0 else { return false }
        return date.timeIntervalSince(updatedAt) <= maximumAge
    }

    /// Validates both document invariants and the activation-specific runtime
    /// expectation held by the host. A matching revision alone is insufficient
    /// because an old provider process can publish the same saved revision.
    public func validate(
        expectedRevision: UInt64,
        activationIdentifier expectedActivationIdentifier: UUID,
        at date: Date = Date(),
        maximumAge: TimeInterval = Self.defaultMaximumHeartbeatAge
    ) throws {
        try validate()
        guard revision == expectedRevision else {
            throw DNSProxyRuntimeStatusValidationError.revisionMismatch(
                expected: expectedRevision,
                actual: revision
            )
        }
        guard activationIdentifier == expectedActivationIdentifier else {
            throw DNSProxyRuntimeStatusValidationError.activationMismatch(
                expected: expectedActivationIdentifier,
                actual: activationIdentifier
            )
        }
        guard maximumAge.isFinite, maximumAge >= 0 else {
            throw DNSProxyRuntimeStatusValidationError.invalidMaximumHeartbeatAge
        }
        guard isFresh(at: date, maximumAge: maximumAge) else {
            throw DNSProxyRuntimeStatusValidationError.staleHeartbeat(
                updatedAt: updatedAt,
                evaluatedAt: date,
                maximumAge: maximumAge
            )
        }
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DNSProxyRuntimeStatusValidationError.unsupportedSchemaVersion(
                schemaVersion
            )
        }
        guard revision > 0 else {
            throw DNSProxyRuntimeStatusValidationError.invalidRevision(revision)
        }

        let (activeFlowCount, activeOverflow) = activeTCPFlows.addingReportingOverflow(
            activeUDPFlows
        )
        guard !activeOverflow, activeFlowCount <= totalFlows else {
            throw DNSProxyRuntimeStatusValidationError.flowCountInvariantViolation
        }
        let (terminalFlowCount, terminalOverflow) = completedFlows.addingReportingOverflow(
            failedFlows
        )
        guard !terminalOverflow else {
            throw DNSProxyRuntimeStatusValidationError.flowCountInvariantViolation
        }
        let (accountedFlowCount, accountedOverflow) = terminalFlowCount
            .addingReportingOverflow(activeFlowCount)
        guard !accountedOverflow, accountedFlowCount <= totalFlows else {
            throw DNSProxyRuntimeStatusValidationError.flowCountInvariantViolation
        }

        guard updatedAt >= startedAt else {
            throw DNSProxyRuntimeStatusValidationError.updatedBeforeStart
        }
        for event in [
            lastBackendAssociationAt,
            lastQueryForwardedAt,
            lastResponseDeliveredAt,
        ].compactMap({ $0 }) where event > updatedAt {
            throw DNSProxyRuntimeStatusValidationError.eventAfterHeartbeat
        }
        if let lastFailureAt, lastFailureAt > updatedAt {
            throw DNSProxyRuntimeStatusValidationError.eventAfterHeartbeat
        }
        for event in [
            lastBackendAssociationAt,
            lastQueryForwardedAt,
            lastResponseDeliveredAt,
        ].compactMap({ $0 }) where event < startedAt {
            throw DNSProxyRuntimeStatusValidationError.eventBeforeStart
        }
        if let lastFailureAt, lastFailureAt < startedAt {
            throw DNSProxyRuntimeStatusValidationError.eventBeforeStart
        }
        guard (lastFailureAt == nil) == (failureCategory == nil) else {
            throw DNSProxyRuntimeStatusValidationError.incompleteFailureRecord
        }

        if phase == .failed || (phase == .running && !backendReady) {
            guard failureCategory != nil else {
                throw DNSProxyRuntimeStatusValidationError.missingFailureCategory
            }
        }
        if phase == .stopped || phase == .failed {
            guard !backendReady else {
                throw DNSProxyRuntimeStatusValidationError.terminalPhaseBackendReady
            }
        }
        if phase == .stopped {
            guard activeFlowCount == 0 else {
                throw DNSProxyRuntimeStatusValidationError.stoppedWithActiveFlows
            }
        }
    }
}

public enum DNSProxyRuntimeStatusValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidRevision(UInt64)
    case flowCountInvariantViolation
    case updatedBeforeStart
    case eventBeforeStart
    case eventAfterHeartbeat
    case incompleteFailureRecord
    case missingFailureCategory
    case terminalPhaseBackendReady
    case stoppedWithActiveFlows
    case revisionMismatch(expected: UInt64, actual: UInt64)
    case activationMismatch(expected: UUID, actual: UUID)
    case invalidMaximumHeartbeatAge
    case staleHeartbeat(updatedAt: Date, evaluatedAt: Date, maximumAge: TimeInterval)
}

extension DNSProxyRuntimeStatusValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "DNS proxy status uses unsupported schema version \(version)."
        case let .invalidRevision(revision):
            "DNS proxy status revision must be greater than zero; received \(revision)."
        case .flowCountInvariantViolation:
            "DNS proxy status flow counters are inconsistent."
        case .updatedBeforeStart:
            "DNS proxy status heartbeat predates provider startup."
        case .eventBeforeStart:
            "DNS proxy status contains an event older than provider startup."
        case .eventAfterHeartbeat:
            "DNS proxy status contains an event newer than its heartbeat."
        case .incompleteFailureRecord:
            "DNS proxy status must record failure time and category together."
        case .missingFailureCategory:
            "DNS proxy status does not identify its runtime failure category."
        case .terminalPhaseBackendReady:
            "A stopped or failed DNS proxy cannot report its backend as ready."
        case .stoppedWithActiveFlows:
            "A stopped DNS proxy cannot report active flows."
        case let .revisionMismatch(expected, actual):
            "DNS proxy status revision \(actual) does not match expected revision \(expected)."
        case .activationMismatch:
            "DNS proxy status was published by a different activation."
        case .invalidMaximumHeartbeatAge:
            "DNS proxy heartbeat maximum age must be a finite, nonnegative interval."
        case let .staleHeartbeat(updatedAt, evaluatedAt, maximumAge):
            "DNS proxy heartbeat from \(updatedAt) is older than \(maximumAge) seconds at \(evaluatedAt)."
        }
    }
}

/// Synchronous, lock-protected storage usable from Network Extension callback
/// queues as well as the host. `Data.write(.atomic)` publishes each complete
/// JSON document with a rename so readers never observe a partial heartbeat.
public final class DNSProxyStatusFile: @unchecked Sendable {
    public static let maximumDocumentSize = 64 * 1_024

    public let statusURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()
    private let decoder = JSONDecoder()

    public convenience init(
        appGroupIdentifier: String = MClashNetworkExtensionSharedContainer.identifier,
        fileManager: FileManager = .default
    ) throws {
        try self.init(
            statusURL: MClashNetworkExtensionSharedContainer.dnsProxyStatusURL(
                appGroupIdentifier: appGroupIdentifier,
                fileManager: fileManager
            ),
            fileManager: fileManager
        )
    }

    /// The direct URL initializer exists for deterministic tests and for tools
    /// that have already resolved the entitled App Group container.
    public init(
        statusURL: URL,
        fileManager: FileManager = .default
    ) {
        self.statusURL = statusURL.standardizedFileURL
        self.fileManager = fileManager
    }

    public func write(_ status: DNSProxyRuntimeStatus) throws {
        try status.validate()
        try withLock {
            // JSONEncoder is not documented as safe for concurrent use. Keep
            // one encoder per atomic publication instead of sharing it across
            // Network Extension callback queues.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(status)
            guard data.count <= Self.maximumDocumentSize else {
                throw DNSProxyStatusFileError.documentTooLarge(
                    actual: data.count,
                    maximum: Self.maximumDocumentSize
                )
            }

            let directory = statusURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try data.write(to: statusURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: statusURL.path
            )
        }
    }

    public func read() throws -> DNSProxyRuntimeStatus {
        try withLock {
            guard fileManager.fileExists(atPath: statusURL.path) else {
                throw DNSProxyStatusFileError.documentMissing
            }
            if let fileSize = try fileManager.attributesOfItem(
                atPath: statusURL.path
            )[.size] as? NSNumber,
               fileSize.uint64Value > UInt64(Self.maximumDocumentSize) {
                throw DNSProxyStatusFileError.documentTooLarge(
                    actual: Int(clamping: fileSize.uint64Value),
                    maximum: Self.maximumDocumentSize
                )
            }

            let handle = try FileHandle(forReadingFrom: statusURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maximumDocumentSize + 1) ?? Data()
            guard data.count <= Self.maximumDocumentSize else {
                throw DNSProxyStatusFileError.documentTooLarge(
                    actual: data.count,
                    maximum: Self.maximumDocumentSize
                )
            }
            let probe = try decoder.decode(SchemaVersionProbe.self, from: data)
            guard probe.schemaVersion == DNSProxyRuntimeStatus.currentSchemaVersion else {
                throw DNSProxyRuntimeStatusValidationError.unsupportedSchemaVersion(
                    probe.schemaVersion
                )
            }
            let status = try decoder.decode(DNSProxyRuntimeStatus.self, from: data)
            try status.validate()
            return status
        }
    }

    public func readValidated(
        expectedRevision: UInt64,
        activationIdentifier: UUID,
        at date: Date = Date(),
        maximumAge: TimeInterval = DNSProxyRuntimeStatus.defaultMaximumHeartbeatAge
    ) throws -> DNSProxyRuntimeStatus {
        let status = try read()
        try status.validate(
            expectedRevision: expectedRevision,
            activationIdentifier: activationIdentifier,
            at: date,
            maximumAge: maximumAge
        )
        return status
    }

    /// Idempotent removal is useful before a new activation. Correctness does
    /// not depend on deletion because the activation UUID also rejects stale
    /// documents left by a crashed provider.
    public func remove() throws {
        try withLock {
            guard fileManager.fileExists(atPath: statusURL.path) else { return }
            try fileManager.removeItem(at: statusURL)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private struct SchemaVersionProbe: Decodable {
        let schemaVersion: Int
    }
}

public enum DNSProxyStatusFileError: Error, Equatable, Sendable {
    case appGroupContainerUnavailable(identifier: String)
    case documentMissing
    case documentTooLarge(actual: Int, maximum: Int)
}

extension DNSProxyStatusFileError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .appGroupContainerUnavailable(identifier):
            "The shared App Group container \(identifier) is unavailable."
        case .documentMissing:
            "DNS proxy runtime status has not been published yet."
        case let .documentTooLarge(actual, maximum):
            "DNS proxy runtime status is \(actual) bytes; the maximum is \(maximum)."
        }
    }
}
