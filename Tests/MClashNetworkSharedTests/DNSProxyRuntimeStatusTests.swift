import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("DNS proxy runtime status")
struct DNSProxyRuntimeStatusTests {
    @Test("Status round-trips atomically with private file permissions")
    func atomicRoundTrip() throws {
        let fixture = makeFileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let status = makeStatus()

        try fixture.file.write(status)

        #expect(try fixture.file.read() == status)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.file.statusURL.path
        )
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)

        let entries = try FileManager.default.contentsOfDirectory(
            at: fixture.file.statusURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        #expect(entries.map(\.lastPathComponent) == ["dns-proxy-status.json"])
    }

    @Test("Persisted schema contains aggregate runtime truth and no sensitive fields")
    func privacySafeSchema() throws {
        let fixture = makeFileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.file.write(makeStatus())

        let data = try Data(contentsOf: fixture.file.statusURL)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(Set(object.keys) == Set([
            "schemaVersion",
            "revision",
            "activationIdentifier",
            "providerInstanceIdentifier",
            "phase",
            "backendReady",
            "activeTCPFlows",
            "activeUDPFlows",
            "totalFlows",
            "completedFlows",
            "failedFlows",
            "uploadBytes",
            "downloadBytes",
            "startedAt",
            "updatedAt",
            "lastBackendAssociationAt",
            "lastQueryForwardedAt",
            "lastResponseDeliveredAt",
            "lastFailureAt",
            "failureCategory",
        ]))

        let encoded = try #require(String(data: data, encoding: .utf8)).lowercased()
        for forbidden in [
            "domain", "hostname", "destination", "address", "payload",
            "credential", "username", "password", "processidentifier",
        ] {
            #expect(!encoded.contains(forbidden))
        }
    }

    @Test("Freshness accepts the boundary and rejects an older heartbeat")
    func heartbeatFreshness() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var status = makeStatus(startedAt: start, updatedAt: start)

        #expect(status.isFresh(at: start.addingTimeInterval(6), maximumAge: 6))
        #expect(!status.isFresh(at: start.addingTimeInterval(6.001), maximumAge: 6))
        #expect(!status.isFresh(at: start, maximumAge: -.infinity))

        let heartbeat = start.addingTimeInterval(2)
        status.recordHeartbeat(at: heartbeat)
        #expect(status.updatedAt == heartbeat)
        try status.validate(
            expectedRevision: status.revision,
            activationIdentifier: status.activationIdentifier,
            at: heartbeat.addingTimeInterval(6),
            maximumAge: 6
        )

        #expect(
            throws: DNSProxyRuntimeStatusValidationError.staleHeartbeat(
                updatedAt: heartbeat,
                evaluatedAt: heartbeat.addingTimeInterval(6.001),
                maximumAge: 6
            )
        ) {
            try status.validate(
                expectedRevision: status.revision,
                activationIdentifier: status.activationIdentifier,
                at: heartbeat.addingTimeInterval(6.001),
                maximumAge: 6
            )
        }
    }

    @Test("Revision and activation UUID must both match")
    func activationIdentityValidation() throws {
        let status = makeStatus()
        let otherActivation = UUID()

        #expect(
            throws: DNSProxyRuntimeStatusValidationError.revisionMismatch(
                expected: status.revision + 1,
                actual: status.revision
            )
        ) {
            try status.validate(
                expectedRevision: status.revision + 1,
                activationIdentifier: status.activationIdentifier
            )
        }
        #expect(
            throws: DNSProxyRuntimeStatusValidationError.activationMismatch(
                expected: otherActivation,
                actual: status.activationIdentifier
            )
        ) {
            try status.validate(
                expectedRevision: status.revision,
                activationIdentifier: otherActivation
            )
        }
        #expect(throws: DNSProxyRuntimeStatusValidationError.invalidMaximumHeartbeatAge) {
            try status.validate(
                expectedRevision: status.revision,
                activationIdentifier: status.activationIdentifier,
                maximumAge: .nan
            )
        }
    }

    @Test("File validation combines persisted data, revision, activation, and freshness")
    func validatedRead() throws {
        let fixture = makeFileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let start = Date(timeIntervalSince1970: 2_000)
        let status = makeStatus(startedAt: start, updatedAt: start.addingTimeInterval(2))
        try fixture.file.write(status)

        let value = try fixture.file.readValidated(
            expectedRevision: status.revision,
            activationIdentifier: status.activationIdentifier,
            at: start.addingTimeInterval(8),
            maximumAge: 6
        )
        #expect(value == status)

        #expect(
            throws: DNSProxyRuntimeStatusValidationError.staleHeartbeat(
                updatedAt: status.updatedAt,
                evaluatedAt: start.addingTimeInterval(8.001),
                maximumAge: 6
            )
        ) {
            try fixture.file.readValidated(
                expectedRevision: status.revision,
                activationIdentifier: status.activationIdentifier,
                at: start.addingTimeInterval(8.001),
                maximumAge: 6
            )
        }
    }

    @Test("Flow, lifecycle, and timestamp invariants reject corrupt snapshots")
    func statusInvariants() throws {
        var inconsistent = makeStatus()
        inconsistent.totalFlows = 1
        #expect(throws: DNSProxyRuntimeStatusValidationError.flowCountInvariantViolation) {
            try inconsistent.validate()
        }

        var missingFailure = makeStatus()
        missingFailure.backendReady = false
        missingFailure.lastFailureAt = nil
        missingFailure.failureCategory = nil
        #expect(throws: DNSProxyRuntimeStatusValidationError.missingFailureCategory) {
            try missingFailure.validate()
        }

        var terminalBackend = makeStatus()
        terminalBackend.phase = .stopped
        #expect(throws: DNSProxyRuntimeStatusValidationError.terminalPhaseBackendReady) {
            try terminalBackend.validate()
        }

        var badTimestamp = makeStatus()
        badTimestamp.updatedAt = badTimestamp.startedAt.addingTimeInterval(-1)
        #expect(throws: DNSProxyRuntimeStatusValidationError.updatedBeforeStart) {
            try badTimestamp.validate()
        }

        var eventBeforeStart = makeStatus()
        eventBeforeStart.lastResponseDeliveredAt = eventBeforeStart.startedAt
            .addingTimeInterval(-1)
        #expect(throws: DNSProxyRuntimeStatusValidationError.eventBeforeStart) {
            try eventBeforeStart.validate()
        }

        var incompleteFailure = makeStatus()
        incompleteFailure.lastFailureAt = nil
        #expect(throws: DNSProxyRuntimeStatusValidationError.incompleteFailureRecord) {
            try incompleteFailure.validate()
        }
    }

    @Test("Invalid updates never replace the last valid atomic document")
    func failedWritePreservesStatus() throws {
        let fixture = makeFileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = makeStatus()
        try fixture.file.write(original)

        var invalid = original
        invalid.activeTCPFlows = invalid.totalFlows + 1
        #expect(throws: DNSProxyRuntimeStatusValidationError.flowCountInvariantViolation) {
            try fixture.file.write(invalid)
        }
        #expect(try fixture.file.read() == original)
    }

    @Test("Documents larger than 64 KiB are rejected before decoding")
    func documentSizeLimit() throws {
        let fixture = makeFileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.file.statusURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let oversized = Data(
            repeating: 0x20,
            count: DNSProxyStatusFile.maximumDocumentSize + 1
        )
        try oversized.write(to: fixture.file.statusURL)

        #expect(
            throws: DNSProxyStatusFileError.documentTooLarge(
                actual: oversized.count,
                maximum: DNSProxyStatusFile.maximumDocumentSize
            )
        ) {
            try fixture.file.read()
        }
    }

    @Test("Unsupported schema is rejected before full document decoding")
    func unsupportedSchema() throws {
        let fixture = makeFileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.file.statusURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"schemaVersion\":3}".utf8).write(to: fixture.file.statusURL)

        #expect(
            throws: DNSProxyRuntimeStatusValidationError.unsupportedSchemaVersion(3)
        ) {
            try fixture.file.read()
        }
    }

    @Test("Status removal is idempotent and a missing status is explicit")
    func removal() throws {
        let fixture = makeFileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.file.write(makeStatus())

        try fixture.file.remove()
        try fixture.file.remove()
        #expect(throws: DNSProxyStatusFileError.documentMissing) {
            try fixture.file.read()
        }
    }

    private func makeStatus(
        startedAt: Date = Date(timeIntervalSince1970: 1_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_004)
    ) -> DNSProxyRuntimeStatus {
        let lastBackendAssociationAt = max(
            startedAt,
            updatedAt.addingTimeInterval(-1)
        )
        let lastFailureAt = max(
            startedAt,
            updatedAt.addingTimeInterval(-2)
        )
        return DNSProxyRuntimeStatus(
            revision: 42,
            activationIdentifier: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            providerInstanceIdentifier: UUID(
                uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
            )!,
            phase: .running,
            backendReady: true,
            activeTCPFlows: 2,
            activeUDPFlows: 1,
            totalFlows: 8,
            completedFlows: 4,
            failedFlows: 1,
            uploadBytes: 1_024,
            downloadBytes: 2_048,
            startedAt: startedAt,
            updatedAt: updatedAt,
            lastBackendAssociationAt: lastBackendAssociationAt,
            lastQueryForwardedAt: lastBackendAssociationAt,
            lastResponseDeliveredAt: lastBackendAssociationAt,
            lastFailureAt: lastFailureAt,
            failureCategory: .tcpRelayFailed
        )
    }

    private func makeFileFixture() -> (root: URL, file: DNSProxyStatusFile) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mclash-dns-status-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let url = root
            .appendingPathComponent("NetworkExtension", isDirectory: true)
            .appendingPathComponent("dns-proxy-status.json", isDirectory: false)
        return (root, DNSProxyStatusFile(statusURL: url))
    }
}
