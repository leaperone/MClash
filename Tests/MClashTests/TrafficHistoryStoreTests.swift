import Foundation
import SQLite3
import Testing
@testable import MClashApp

@Suite("Traffic history store")
struct TrafficHistoryStoreTests {
    private let baseDate = Date(timeIntervalSince1970: 1_784_166_400)

    @Test("Schema is private, durable, healthy, and contains no sensitive traffic columns")
    func privateHealthySchema() async throws {
        let fixture = try Fixture(now: baseDate)
        let diagnostics = try await fixture.store.storageDiagnostics()

        #expect(diagnostics.schemaVersion == 1)
        #expect(diagnostics.journalMode == "wal")
        #expect(diagnostics.synchronousIsFull)
        #expect(diagnostics.foreignKeysEnabled)
        #expect(diagnostics.busyTimeoutMilliseconds == 5_000)
        #expect(diagnostics.quickCheckPassed)

        let expectedTables: Set<String> = [
            "metadata",
            "total_bucket",
            "application_dimension",
            "application_bucket",
            "route_dimension",
            "route_bucket",
            "flow_checkpoint",
            "source_checkpoint",
            "recent_completion",
        ]
        let tables = try sqliteTextColumn(
            at: fixture.layout.trafficHistoryDatabaseURL,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table'",
            column: 0
        )
        #expect(expectedTables.isSubset(of: Set(tables)))

        let allColumns = try expectedTables.flatMap { table in
            try sqliteTextColumn(
                at: fixture.layout.trafficHistoryDatabaseURL,
                sql: "SELECT name FROM pragma_table_info('\(table)')",
                column: 0
            )
        }
        let forbiddenColumns: Set<String> = [
            "hostname", "domain", "ip", "ip_address", "port", "pid", "uid",
            "path", "executable_path", "rule_payload", "error", "raw_error",
            "secret", "token", "password",
        ]
        #expect(forbiddenColumns.isDisjoint(with: Set(allColumns)))

        let directoryMode = try posixMode(fixture.layout.trafficHistoryDirectory)
        let databaseMode = try posixMode(fixture.layout.trafficHistoryDatabaseURL)
        #expect(directoryMode == 0o700)
        #expect(databaseMode == 0o600)

        let rawCheckpoint = "do-not-persist-secret-token"
        _ = try await fixture.store.ingest([
            completion(id: rawCheckpoint, at: baseDate.addingTimeInterval(1))
        ])
        try await fixture.store.compact(now: baseDate.addingTimeInterval(2))
        let checkpointBytes = Data(rawCheckpoint.utf8)
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: fixture.layout.trafficHistoryDatabaseURL.path + suffix)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let storedData = try Data(contentsOf: url)
            #expect(storedData.range(of: checkpointBytes) == nil)
            #expect(try posixMode(url) == 0o600)
        }
    }

    @Test("Atomic ingestion de-duplicates checkpoints and preserves measurement semantics")
    func ingestionAndCoverage() async throws {
        let fixture = try Fixture(now: baseDate.addingTimeInterval(-3_600))
        let app = TrafficHistoryApplication(
            identity: .bundleIdentifier("com.example.browser"),
            displayName: "Browser"
        )
        let route = TrafficHistoryRoute(
            kind: .mihomo,
            displayName: "Proxy Group → Node A",
            ruleName: "DomainSuffix",
            proxyChain: ["Proxy Group", "Node A"]
        )
        let exact = completion(
            id: "flow-1",
            at: baseDate,
            application: app,
            route: route,
            upload: .exact(120),
            download: .exact(880)
        )
        let handoff = completion(
            id: "flow-2",
            at: baseDate.addingTimeInterval(1),
            application: app,
            route: TrafficHistoryRoute(kind: .direct, displayName: "Direct"),
            outcome: .direct,
            upload: .notMeasuredAfterHandoff,
            download: .notMeasuredAfterHandoff
        )
        let rejected = completion(
            id: "flow-3",
            at: baseDate.addingTimeInterval(2),
            route: TrafficHistoryRoute(kind: .rejected, displayName: "Rejected"),
            outcome: .rejected,
            upload: .notApplicable,
            download: .notApplicable
        )

        let first = try await fixture.store.ingest(
            [exact, handoff, rejected],
            sourceCheckpoint: TrafficHistorySourceCheckpoint(source: .mihomo, sequence: 9)
        )
        let replay = try await fixture.store.ingest(
            [exact, handoff],
            sourceCheckpoint: TrafficHistorySourceCheckpoint(source: .mihomo, sequence: 8)
        )
        #expect(first == TrafficHistoryIngestResult(
            insertedCount: 3,
            duplicateCount: 0,
            beforeBaselineCount: 0
        ))
        #expect(replay.insertedCount == 0)
        #expect(replay.duplicateCount == 2)

        let snapshot = try await fixture.store.snapshot(
            for: .today,
            now: baseDate.addingTimeInterval(60),
            calendar: utcCalendar
        )
        #expect(snapshot.totals.completedFlowCount == 3)
        #expect(snapshot.totals.exactUploadBytes == 120)
        #expect(snapshot.totals.exactDownloadBytes == 880)
        #expect(snapshot.totals.coverage.exactDirectionCount == 2)
        #expect(snapshot.totals.coverage.notMeasuredDirectionCount == 2)
        #expect(snapshot.totals.coverage.notApplicableDirectionCount == 2)
        #expect(snapshot.totals.coverage.measuredFraction == 0.5)
        #expect(snapshot.applications.first?.application.displayName == "Browser")
        #expect(snapshot.routes.contains { $0.route.proxyChain == ["Proxy Group", "Node A"] })
        #expect(
            try await fixture.store.sourceCheckpoint(for: .mihomo)?.sequence == 9
        )

        let reopened = try readyStore(
            TrafficHistoryStore.open(layout: fixture.layout, now: baseDate)
        )
        let persisted = try await reopened.snapshot(
            for: .week,
            now: baseDate.addingTimeInterval(60),
            calendar: utcCalendar
        )
        #expect(persisted.totals.completedFlowCount == 3)
    }

    @Test("Integer aggregation saturates instead of overflowing or becoming negative")
    func saturatingAggregation() async throws {
        let fixture = try Fixture(now: baseDate.addingTimeInterval(-60))
        let first = completion(
            id: "huge-1",
            at: baseDate,
            upload: .exact(.max),
            download: .exact(.max)
        )
        let second = completion(
            id: "huge-2",
            at: baseDate.addingTimeInterval(1),
            upload: .exact(.max),
            download: .exact(.max)
        )
        _ = try await fixture.store.ingest([first, second])
        let snapshot = try await fixture.store.snapshot(
            for: .today,
            now: baseDate.addingTimeInterval(60),
            calendar: utcCalendar
        )
        #expect(snapshot.totals.exactUploadBytes == UInt64(Int64.max))
        #expect(snapshot.totals.exactDownloadBytes == UInt64(Int64.max))
        #expect(snapshot.totals.exactTotalBytes == UInt64.max - 1)
        #expect(snapshot.totals.completedFlowCount == 2)
    }

    @Test("Invalid checkpoint input rejects the whole batch before any aggregate changes")
    func invalidCheckpointIsAtomic() async throws {
        let fixture = try Fixture(now: baseDate.addingTimeInterval(-60))
        let valid = completion(id: "valid", at: baseDate)
        let invalid = completion(id: " \n\t ", at: baseDate.addingTimeInterval(1))
        do {
            _ = try await fixture.store.ingest([valid, invalid])
            Issue.record("Expected the invalid checkpoint batch to fail")
        } catch let error as TrafficHistoryStoreError {
            #expect(error == .invalidCheckpointIdentifier)
        }
        let snapshot = try await fixture.store.snapshot(
            for: .today,
            now: baseDate.addingTimeInterval(60),
            calendar: utcCalendar
        )
        #expect(snapshot.totals.completedFlowCount == 0)
    }

    @Test("Clear advances generation, rejects replay before baseline, and keeps source cursor")
    func clearGenerationAndBaseline() async throws {
        let fixture = try Fixture(now: baseDate.addingTimeInterval(-3_600))
        _ = try await fixture.store.ingest(
            [completion(id: "before-clear", at: baseDate)],
            sourceCheckpoint: TrafficHistorySourceCheckpoint(source: .mihomo, sequence: 44)
        )
        let clearDate = baseDate.addingTimeInterval(120)
        let baseline = try await fixture.store.clear(at: clearDate)
        #expect(baseline.generation == 2)
        #expect(baseline.startedAt == clearDate)

        let result = try await fixture.store.ingest([
            completion(id: "old-replay", at: baseDate),
            completion(id: "after-clear", at: clearDate.addingTimeInterval(1)),
        ])
        #expect(result.insertedCount == 1)
        #expect(result.beforeBaselineCount == 1)
        #expect(try await fixture.store.sourceCheckpoint(for: .mihomo)?.sequence == 44)

        let snapshot = try await fixture.store.snapshot(
            for: .today,
            now: clearDate.addingTimeInterval(60),
            calendar: utcCalendar
        )
        #expect(snapshot.baseline.generation == 2)
        #expect(snapshot.totals.completedFlowCount == 1)
    }

    @Test("Retention supports 7, 30, and 90 days and pruning removes expired buckets")
    func retentionAndPruning() async throws {
        let fixture = try Fixture(now: baseDate.addingTimeInterval(-100 * 86_400))
        let old = completion(
            id: "old",
            at: baseDate.addingTimeInterval(-20 * 86_400),
            upload: .exact(10),
            download: .exact(20)
        )
        let recent = completion(
            id: "recent",
            at: baseDate,
            upload: .exact(30),
            download: .exact(40)
        )
        _ = try await fixture.store.ingest([old, recent])
        #expect(try await fixture.store.retention() == .thirtyDays)
        #expect(
            try sqliteIntScalar(
                at: fixture.layout.trafficHistoryDatabaseURL,
                sql: "SELECT COUNT(*) FROM flow_checkpoint"
            ) == 2
        )

        try await fixture.store.setRetention(.sevenDays, now: baseDate.addingTimeInterval(60))
        #expect(try await fixture.store.retention() == .sevenDays)
        try await fixture.store.compact(now: baseDate.addingTimeInterval(60))

        let week = try await fixture.store.snapshot(
            for: .week,
            now: baseDate.addingTimeInterval(60),
            calendar: utcCalendar
        )
        #expect(week.totals.completedFlowCount == 1)
        #expect(week.totals.exactTotalBytes == 70)
        #expect(
            try sqliteIntScalar(
                at: fixture.layout.trafficHistoryDatabaseURL,
                sql: "SELECT COUNT(*) FROM flow_checkpoint"
            ) == 1
        )

        try await fixture.store.setRetention(.ninetyDays, now: baseDate)
        #expect(try await fixture.store.retention() == .ninetyDays)
        try await fixture.store.setRetention(.thirtyDays, now: baseDate)
        #expect(try await fixture.store.retention() == .thirtyDays)

        let reopened = try readyStore(
            TrafficHistoryStore.open(
                layout: fixture.layout,
                initialRetention: .sevenDays,
                now: baseDate
            )
        )
        #expect(try await reopened.retention() == .thirtyDays)
    }

    @Test("Newer and corrupted databases return explicit unavailable states")
    func explicitUnavailableStates() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ProfileDirectoryLayout(rootDirectory: root)
        try FileManager.default.createDirectory(
            at: layout.trafficHistoryDirectory,
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        #expect(sqlite3_open(layout.trafficHistoryDatabaseURL.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA user_version = 99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        switch TrafficHistoryStore.open(layout: layout, now: baseDate) {
        case let .unavailable(reason):
            #expect(reason == .newerSchema(found: 99, supported: 1))
        case .ready:
            Issue.record("A newer schema must not be opened as empty history")
        }

        try FileManager.default.removeItem(at: layout.trafficHistoryDatabaseURL)
        try Data("not a sqlite database".utf8).write(to: layout.trafficHistoryDatabaseURL)
        switch TrafficHistoryStore.open(layout: layout, now: baseDate) {
        case let .unavailable(reason):
            #expect(reason == .corruptedDatabase)
        case .ready:
            Issue.record("A corrupted database must not be opened as empty history")
        }
    }

    private func completion(
        id: String,
        at date: Date,
        application: TrafficHistoryApplication = .unattributed,
        route: TrafficHistoryRoute = .unresolved,
        outcome: TrafficHistoryOutcome = .viaMihomo,
        upload: TrafficHistoryMeasurement = .exact(1),
        download: TrafficHistoryMeasurement = .exact(2)
    ) -> TrafficHistoryCompletedFlow {
        TrafficHistoryCompletedFlow(
            checkpointIdentifier: id,
            source: .mihomo,
            completedAt: date,
            application: application,
            route: route,
            outcome: outcome,
            upload: upload,
            download: download
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }
}

private struct Fixture {
    let root: URL
    let layout: ProfileDirectoryLayout
    let store: TrafficHistoryStore

    init(now: Date) throws {
        root = temporaryDirectory()
        layout = ProfileDirectoryLayout(rootDirectory: root.appendingPathComponent("MClash"))
        store = try readyStore(TrafficHistoryStore.open(layout: layout, now: now))
    }

    // Temporary directories are intentionally left until process exit. Closing
    // an actor-owned SQLite handle is asynchronous with its final release, so
    // eager deletion here would make test teardown race the actor deinitializer.
}

private func readyStore(_ result: TrafficHistoryStoreOpenResult) throws -> TrafficHistoryStore {
    switch result {
    case let .ready(store):
        return store
    case let .unavailable(reason):
        Issue.record("Traffic history store unavailable: \(reason)")
        throw TrafficHistoryStoreError.databaseUnavailable
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("MClash-TrafficHistory-\(UUID().uuidString)", isDirectory: true)
}

private func posixMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

private func sqliteTextColumn(at url: URL, sql: String, column: Int32) throws -> [String] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw TrafficHistoryStoreError.queryFailed
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw TrafficHistoryStoreError.queryFailed
    }
    defer { sqlite3_finalize(statement) }
    var values: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        if let value = sqlite3_column_text(statement, column) {
            values.append(String(cString: value))
        }
    }
    return values
}

private func sqliteIntScalar(at url: URL, sql: String) throws -> Int64 {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        throw TrafficHistoryStoreError.queryFailed
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw TrafficHistoryStoreError.queryFailed
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw TrafficHistoryStoreError.queryFailed
    }
    return sqlite3_column_int64(statement, 0)
}
