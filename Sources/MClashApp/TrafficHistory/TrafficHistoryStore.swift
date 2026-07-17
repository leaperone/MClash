import Foundation
import SQLite3

actor TrafficHistoryStore {
    static let schemaVersion: Int32 = 1

    private static let maximumRecentCompletions = 1_000
    fileprivate static let busyTimeoutMilliseconds: Int32 = 5_000
    private static let minuteMilliseconds: Int64 = 60_000
    private static let maximumSQLiteInteger = Int64.max

    private let connection: TrafficHistorySQLiteConnection
    private let databaseURL: URL

    private init(database: OpaquePointer, databaseURL: URL) {
        connection = TrafficHistorySQLiteConnection(handle: database)
        self.databaseURL = databaseURL
    }

    private var database: OpaquePointer {
        connection.handle
    }

    static func open(
        layout: ProfileDirectoryLayout,
        initialRetention: TrafficHistoryRetention = .default,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> TrafficHistoryStoreOpenResult {
        open(
            databaseURL: layout.trafficHistoryDatabaseURL,
            initialRetention: initialRetention,
            now: now,
            fileManager: fileManager
        )
    }

    static func open(
        databaseURL: URL,
        initialRetention: TrafficHistoryRetention = .default,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> TrafficHistoryStoreOpenResult {
        let directoryURL = databaseURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            return .unavailable(.cannotCreatePrivateDirectory)
        }

        var handle: OpaquePointer?
        let openCode = sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let database = handle else {
            if let handle { sqlite3_close_v2(handle) }
            return .unavailable(.cannotOpenDatabase)
        }

        do {
            let existingVersion = try trafficHistoryScalarInt32(database, sql: "PRAGMA user_version")
            guard existingVersion <= schemaVersion else {
                sqlite3_close_v2(database)
                return .unavailable(
                    .newerSchema(found: existingVersion, supported: schemaVersion)
                )
            }

            try trafficHistoryConfigureConnection(database)
            if existingVersion == 0 {
                try trafficHistoryCreateV1Schema(
                    database,
                    retention: initialRetention,
                    now: now
                )
            }
            try trafficHistoryVerifyQuickCheck(database)
            try trafficHistorySecureFiles(databaseURL, fileManager: fileManager)
            return .ready(TrafficHistoryStore(database: database, databaseURL: databaseURL))
        } catch let failure as TrafficHistorySetupFailure {
            sqlite3_close_v2(database)
            switch failure {
            case .corrupted:
                return .unavailable(.corruptedDatabase)
            case .migration:
                return .unavailable(.migrationFailed)
            case .configuration:
                return .unavailable(.cannotOpenDatabase)
            }
        } catch {
            let setupFailure = trafficHistorySetupFailure(
                database,
                fallback: .configuration
            )
            let isCorrupted: Bool
            if case .corrupted = setupFailure {
                isCorrupted = true
            } else {
                isCorrupted = false
            }
            sqlite3_close_v2(database)
            return .unavailable(isCorrupted ? .corruptedDatabase : .cannotOpenDatabase)
        }
    }

    func baseline() throws -> TrafficHistoryBaseline {
        do {
            return try readBaseline()
        } catch {
            throw TrafficHistoryStoreError.queryFailed
        }
    }

    func retention() throws -> TrafficHistoryRetention {
        do {
            let value = try metadataInteger(for: "retention_days")
            return TrafficHistoryRetention(rawValue: Int(value)) ?? .default
        } catch {
            throw TrafficHistoryStoreError.queryFailed
        }
    }

    func sourceCheckpoint(
        for source: TrafficHistorySource
    ) throws -> TrafficHistorySourceCheckpoint? {
        do {
            let statement = try trafficHistoryPrepare(
                database,
                sql: "SELECT sequence FROM source_checkpoint WHERE source = ?"
            )
            defer { sqlite3_finalize(statement) }
            try trafficHistoryBindText(statement, index: 1, value: source.rawValue)
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                return TrafficHistorySourceCheckpoint(
                    source: source,
                    sequence: sqlite3_column_int64(statement, 0)
                )
            case SQLITE_DONE:
                return nil
            default:
                throw TrafficHistoryStoreError.queryFailed
            }
        } catch let error as TrafficHistoryStoreError {
            throw error
        } catch {
            throw TrafficHistoryStoreError.queryFailed
        }
    }

    func storageDiagnostics() throws -> TrafficHistoryStorageDiagnostics {
        do {
            let version = try trafficHistoryScalarInt32(database, sql: "PRAGMA user_version")
            let journalMode = try trafficHistoryScalarText(database, sql: "PRAGMA journal_mode")
            let synchronous = try trafficHistoryScalarInt32(database, sql: "PRAGMA synchronous")
            let foreignKeys = try trafficHistoryScalarInt32(database, sql: "PRAGMA foreign_keys")
            let busyTimeout = try trafficHistoryScalarInt32(database, sql: "PRAGMA busy_timeout")
            let quickCheck = try trafficHistoryScalarText(database, sql: "PRAGMA quick_check(1)")
            return TrafficHistoryStorageDiagnostics(
                schemaVersion: version,
                journalMode: journalMode.lowercased(),
                synchronousIsFull: synchronous == 2,
                foreignKeysEnabled: foreignKeys == 1,
                busyTimeoutMilliseconds: busyTimeout,
                quickCheckPassed: quickCheck == "ok"
            )
        } catch {
            throw TrafficHistoryStoreError.queryFailed
        }
    }

    /// Atomically records completed flows and advances the source cursor. A
    /// completion contributes to buckets only after its durable checkpoint is
    /// inserted, so replaying a batch after a crash cannot double count it.
    func ingest(
        _ completions: [TrafficHistoryCompletedFlow],
        sourceCheckpoint: TrafficHistorySourceCheckpoint? = nil
    ) throws -> TrafficHistoryIngestResult {
        guard completions.allSatisfy({ !$0.checkpointIdentifier.isEmpty }) else {
            throw TrafficHistoryStoreError.invalidCheckpointIdentifier
        }

        do {
            try trafficHistoryExecute(database, sql: "BEGIN IMMEDIATE")
            do {
                let baseline = try readBaseline()
                var inserted = 0
                var duplicates = 0
                var beforeBaseline = 0

                for completion in completions {
                    guard completion.completedAt >= baseline.startedAt else {
                        beforeBaseline += 1
                        continue
                    }
                    let wasInserted = try insertFlowCheckpoint(
                        completion,
                        generation: baseline.generation
                    )
                    guard wasInserted else {
                        duplicates += 1
                        continue
                    }

                    let applicationID = try applicationDimensionID(completion.application)
                    let routeID = try routeDimensionID(completion.route)
                    let bucket = Self.bucketStartMilliseconds(for: completion.completedAt)
                    let delta = TrafficHistoryStoredDelta(completion: completion)

                    try upsertBucket(
                        table: "total_bucket",
                        generation: baseline.generation,
                        bucketStart: bucket,
                        dimensionColumn: nil,
                        dimensionID: nil,
                        delta: delta
                    )
                    try upsertBucket(
                        table: "application_bucket",
                        generation: baseline.generation,
                        bucketStart: bucket,
                        dimensionColumn: "application_id",
                        dimensionID: applicationID,
                        delta: delta
                    )
                    try upsertBucket(
                        table: "route_bucket",
                        generation: baseline.generation,
                        bucketStart: bucket,
                        dimensionColumn: "route_id",
                        dimensionID: routeID,
                        delta: delta
                    )
                    try insertRecentCompletion(
                        completion,
                        generation: baseline.generation,
                        applicationID: applicationID,
                        routeID: routeID
                    )
                    inserted += 1
                }

                if let sourceCheckpoint {
                    try upsertSourceCheckpoint(sourceCheckpoint)
                }
                try trimRecentCompletions()
                try trafficHistoryExecute(database, sql: "COMMIT")
                try secureDatabaseFiles()
                return TrafficHistoryIngestResult(
                    insertedCount: inserted,
                    duplicateCount: duplicates,
                    beforeBaselineCount: beforeBaseline
                )
            } catch {
                try? trafficHistoryExecute(database, sql: "ROLLBACK")
                throw error
            }
        } catch let error as TrafficHistoryStoreError {
            throw error
        } catch {
            throw TrafficHistoryStoreError.writeFailed
        }
    }

    func snapshot(
        for period: TrafficHistoryPeriod,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> TrafficHistorySnapshot {
        let requestedStart: Date
        switch period {
        case .today:
            requestedStart = calendar.startOfDay(for: now)
        case .week:
            requestedStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.date(byAdding: .day, value: -7, to: now)
                ?? now
        }
        let interval = DateInterval(start: min(requestedStart, now), end: now)

        do {
            let baseline = try readBaseline()
            let queryStart = max(interval.start, baseline.startedAt)
            let lowerBound = Self.bucketStartMilliseconds(for: queryStart)
            let endMilliseconds = Self.dateMilliseconds(now)
            let upperBound = endMilliseconds == Int64.max
                ? Int64.max
                : endMilliseconds + 1
            let generation = baseline.generation

            let totals = try queryTotals(
                table: "total_bucket",
                generation: generation,
                lowerBound: lowerBound,
                upperBound: upperBound
            )
            let applications = try queryApplications(
                generation: generation,
                lowerBound: lowerBound,
                upperBound: upperBound
            )
            let routes = try queryRoutes(
                generation: generation,
                lowerBound: lowerBound,
                upperBound: upperBound
            )
            return TrafficHistorySnapshot(
                period: period,
                interval: interval,
                baseline: baseline,
                totals: totals,
                applications: applications,
                routes: routes
            )
        } catch {
            throw TrafficHistoryStoreError.queryFailed
        }
    }

    /// Starts a new history generation. Source cursors remain intact so a
    /// recorder does not replay an old source buffer after the user clears
    /// history; the new baseline rejects any pre-clear completion timestamp.
    @discardableResult
    func clear(at date: Date = Date()) throws -> TrafficHistoryBaseline {
        do {
            try trafficHistoryExecute(database, sql: "BEGIN IMMEDIATE")
            do {
                let current = try readBaseline()
                let nextGeneration = current.generation == Int64.max
                    ? 1
                    : current.generation + 1
                try setMetadataInteger(nextGeneration, for: "generation")
                try setMetadataInteger(Self.dateMilliseconds(date), for: "baseline_at_ms")
                for table in [
                    "total_bucket",
                    "application_bucket",
                    "route_bucket",
                    "flow_checkpoint",
                    "recent_completion",
                    "application_dimension",
                    "route_dimension",
                ] {
                    try trafficHistoryExecute(database, sql: "DELETE FROM \(table)")
                }
                try trafficHistoryExecute(database, sql: "COMMIT")
                try secureDatabaseFiles()
                return TrafficHistoryBaseline(generation: nextGeneration, startedAt: date)
            } catch {
                try? trafficHistoryExecute(database, sql: "ROLLBACK")
                throw error
            }
        } catch {
            throw TrafficHistoryStoreError.writeFailed
        }
    }

    func setRetention(
        _ retention: TrafficHistoryRetention,
        now: Date = Date()
    ) throws {
        do {
            try trafficHistoryExecute(database, sql: "BEGIN IMMEDIATE")
            do {
                try setMetadataInteger(Int64(retention.rawValue), for: "retention_days")
                try pruneInsideTransaction(retention: retention, now: now)
                try trafficHistoryExecute(database, sql: "COMMIT")
                try secureDatabaseFiles()
            } catch {
                try? trafficHistoryExecute(database, sql: "ROLLBACK")
                throw error
            }
        } catch {
            throw TrafficHistoryStoreError.maintenanceFailed
        }
    }

    func prune(now: Date = Date()) throws {
        do {
            let retention = try retention()
            try trafficHistoryExecute(database, sql: "BEGIN IMMEDIATE")
            do {
                try pruneInsideTransaction(retention: retention, now: now)
                try trafficHistoryExecute(database, sql: "COMMIT")
                try secureDatabaseFiles()
            } catch {
                try? trafficHistoryExecute(database, sql: "ROLLBACK")
                throw error
            }
        } catch {
            throw TrafficHistoryStoreError.maintenanceFailed
        }
    }

    func compact(now: Date = Date()) throws {
        do {
            try prune(now: now)
            try trafficHistoryExecute(database, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try trafficHistoryExecute(database, sql: "VACUUM")
            try trafficHistoryVerifyQuickCheck(database)
            try secureDatabaseFiles()
        } catch {
            throw TrafficHistoryStoreError.maintenanceFailed
        }
    }

    private func readBaseline() throws -> TrafficHistoryBaseline {
        let generation = try metadataInteger(for: "generation")
        let milliseconds = try metadataInteger(for: "baseline_at_ms")
        return TrafficHistoryBaseline(
            generation: generation,
            startedAt: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        )
    }

    private func metadataInteger(for key: String) throws -> Int64 {
        let statement = try trafficHistoryPrepare(
            database,
            sql: "SELECT integer_value FROM metadata WHERE key = ?"
        )
        defer { sqlite3_finalize(statement) }
        try trafficHistoryBindText(statement, index: 1, value: key)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw TrafficHistoryStoreError.queryFailed
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func setMetadataInteger(_ value: Int64, for key: String) throws {
        let statement = try trafficHistoryPrepare(
            database,
            sql: """
                INSERT INTO metadata(key, integer_value) VALUES(?, ?)
                ON CONFLICT(key) DO UPDATE SET integer_value = excluded.integer_value
                """
        )
        defer { sqlite3_finalize(statement) }
        try trafficHistoryBindText(statement, index: 1, value: key)
        sqlite3_bind_int64(statement, 2, value)
        try trafficHistoryStepDone(statement)
    }

    private func insertFlowCheckpoint(
        _ completion: TrafficHistoryCompletedFlow,
        generation: Int64
    ) throws -> Bool {
        let statement = try trafficHistoryPrepare(
            database,
            sql: """
                INSERT OR IGNORE INTO flow_checkpoint(
                    source, flow_identifier, completed_at_ms, generation
                ) VALUES(?, ?, ?, ?)
                """
        )
        defer { sqlite3_finalize(statement) }
        try trafficHistoryBindText(statement, index: 1, value: completion.source.rawValue)
        try trafficHistoryBindText(statement, index: 2, value: completion.checkpointIdentifier)
        sqlite3_bind_int64(statement, 3, Self.dateMilliseconds(completion.completedAt))
        sqlite3_bind_int64(statement, 4, generation)
        try trafficHistoryStepDone(statement)
        return sqlite3_changes(database) == 1
    }

    private func applicationDimensionID(
        _ application: TrafficHistoryApplication
    ) throws -> Int64 {
        let upsert = try trafficHistoryPrepare(
            database,
            sql: """
                INSERT INTO application_dimension(
                    storage_key, display_name, bundle_identifier, signing_identifier
                ) VALUES(?, ?, ?, ?)
                ON CONFLICT(storage_key) DO UPDATE SET
                    display_name = excluded.display_name,
                    bundle_identifier = excluded.bundle_identifier,
                    signing_identifier = excluded.signing_identifier
                """
        )
        defer { sqlite3_finalize(upsert) }
        try trafficHistoryBindText(upsert, index: 1, value: application.storageKey)
        try trafficHistoryBindText(upsert, index: 2, value: application.displayName)
        try trafficHistoryBindOptionalText(upsert, index: 3, value: application.bundleIdentifier)
        try trafficHistoryBindOptionalText(upsert, index: 4, value: application.signingIdentifier)
        try trafficHistoryStepDone(upsert)
        return try dimensionID(
            table: "application_dimension",
            storageKey: application.storageKey
        )
    }

    private func routeDimensionID(_ route: TrafficHistoryRoute) throws -> Int64 {
        let chainData = try JSONEncoder().encode(route.proxyChain)
        guard let chainJSON = String(data: chainData, encoding: .utf8) else {
            throw TrafficHistoryStoreError.writeFailed
        }
        let upsert = try trafficHistoryPrepare(
            database,
            sql: """
                INSERT INTO route_dimension(
                    storage_key, kind, display_name, rule_name, proxy_chain_json
                ) VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(storage_key) DO UPDATE SET
                    display_name = excluded.display_name,
                    rule_name = excluded.rule_name,
                    proxy_chain_json = excluded.proxy_chain_json
                """
        )
        defer { sqlite3_finalize(upsert) }
        try trafficHistoryBindText(upsert, index: 1, value: route.storageKey)
        try trafficHistoryBindText(upsert, index: 2, value: route.kind.rawValue)
        try trafficHistoryBindText(upsert, index: 3, value: route.displayName)
        try trafficHistoryBindOptionalText(upsert, index: 4, value: route.ruleName)
        try trafficHistoryBindText(upsert, index: 5, value: chainJSON)
        try trafficHistoryStepDone(upsert)
        return try dimensionID(table: "route_dimension", storageKey: route.storageKey)
    }

    private func dimensionID(table: String, storageKey: String) throws -> Int64 {
        let statement = try trafficHistoryPrepare(
            database,
            sql: "SELECT id FROM \(table) WHERE storage_key = ?"
        )
        defer { sqlite3_finalize(statement) }
        try trafficHistoryBindText(statement, index: 1, value: storageKey)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw TrafficHistoryStoreError.writeFailed
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func upsertBucket(
        table: String,
        generation: Int64,
        bucketStart: Int64,
        dimensionColumn: String?,
        dimensionID: Int64?,
        delta: TrafficHistoryStoredDelta
    ) throws {
        let dimensionInsert = dimensionColumn.map { ", \($0)" } ?? ""
        let dimensionPlaceholder = dimensionColumn == nil ? "" : ", ?"
        let conflictColumns = dimensionColumn.map { "generation, bucket_start_ms, \($0)" }
            ?? "generation, bucket_start_ms"
        let columns = TrafficHistoryStoredDelta.columnNames
        let updates = columns.map { column in
            """
            \(column) = CASE
                WHEN \(column) > \(Self.maximumSQLiteInteger) - excluded.\(column)
                    THEN \(Self.maximumSQLiteInteger)
                ELSE \(column) + excluded.\(column)
            END
            """
        }.joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let statement = try trafficHistoryPrepare(
            database,
            sql: """
                INSERT INTO \(table)(
                    generation, bucket_start_ms\(dimensionInsert), \(columns.joined(separator: ", "))
                ) VALUES(?, ?\(dimensionPlaceholder), \(placeholders))
                ON CONFLICT(\(conflictColumns)) DO UPDATE SET \(updates)
                """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, generation)
        sqlite3_bind_int64(statement, 2, bucketStart)
        var index: Int32 = 3
        if let dimensionID {
            sqlite3_bind_int64(statement, index, dimensionID)
            index += 1
        }
        for value in delta.values {
            sqlite3_bind_int64(statement, index, value)
            index += 1
        }
        try trafficHistoryStepDone(statement)
    }

    private func insertRecentCompletion(
        _ completion: TrafficHistoryCompletedFlow,
        generation: Int64,
        applicationID: Int64,
        routeID: Int64
    ) throws {
        let statement = try trafficHistoryPrepare(
            database,
            sql: """
                INSERT INTO recent_completion(
                    generation, source, flow_identifier, completed_at_ms,
                    application_id, route_id, outcome,
                    upload_kind, upload_bytes, download_kind, download_bytes
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, generation)
        try trafficHistoryBindText(statement, index: 2, value: completion.source.rawValue)
        try trafficHistoryBindText(statement, index: 3, value: completion.checkpointIdentifier)
        sqlite3_bind_int64(statement, 4, Self.dateMilliseconds(completion.completedAt))
        sqlite3_bind_int64(statement, 5, applicationID)
        sqlite3_bind_int64(statement, 6, routeID)
        try trafficHistoryBindText(statement, index: 7, value: completion.outcome.rawValue)
        let upload = TrafficHistoryStoredMeasurement(completion.upload)
        try trafficHistoryBindText(statement, index: 8, value: upload.kind)
        try trafficHistoryBindOptionalInt64(statement, index: 9, value: upload.bytes)
        let download = TrafficHistoryStoredMeasurement(completion.download)
        try trafficHistoryBindText(statement, index: 10, value: download.kind)
        try trafficHistoryBindOptionalInt64(statement, index: 11, value: download.bytes)
        try trafficHistoryStepDone(statement)
    }

    private func upsertSourceCheckpoint(
        _ checkpoint: TrafficHistorySourceCheckpoint
    ) throws {
        let statement = try trafficHistoryPrepare(
            database,
            sql: """
                INSERT INTO source_checkpoint(source, sequence, updated_at_ms)
                VALUES(?, ?, ?)
                ON CONFLICT(source) DO UPDATE SET
                    sequence = MAX(sequence, excluded.sequence),
                    updated_at_ms = excluded.updated_at_ms
                """
        )
        defer { sqlite3_finalize(statement) }
        try trafficHistoryBindText(statement, index: 1, value: checkpoint.source.rawValue)
        sqlite3_bind_int64(statement, 2, checkpoint.sequence)
        sqlite3_bind_int64(statement, 3, Self.dateMilliseconds(Date()))
        try trafficHistoryStepDone(statement)
    }

    private func trimRecentCompletions() throws {
        try trafficHistoryExecute(
            database,
            sql: """
                DELETE FROM recent_completion
                WHERE id NOT IN (
                    SELECT id FROM recent_completion
                    ORDER BY completed_at_ms DESC, id DESC
                    LIMIT \(Self.maximumRecentCompletions)
                )
                """
        )
    }

    private func queryTotals(
        table: String,
        generation: Int64,
        lowerBound: Int64,
        upperBound: Int64
    ) throws -> TrafficHistoryTotals {
        let statement = try trafficHistoryPrepare(
            database,
            sql: """
                SELECT \(TrafficHistoryStoredDelta.columnNames.joined(separator: ", "))
                FROM \(table)
                WHERE generation = ? AND bucket_start_ms >= ? AND bucket_start_ms < ?
                ORDER BY bucket_start_ms
                """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, generation)
        sqlite3_bind_int64(statement, 2, lowerBound)
        sqlite3_bind_int64(statement, 3, upperBound)
        var aggregate = TrafficHistoryStoredDelta.zero
        while sqlite3_step(statement) == SQLITE_ROW {
            aggregate.add(row: statement, startingAt: 0)
        }
        return aggregate.totals
    }

    private func queryApplications(
        generation: Int64,
        lowerBound: Int64,
        upperBound: Int64
    ) throws -> [TrafficHistoryApplicationSnapshot] {
        let statement = try trafficHistoryPrepare(
            database,
            sql: """
                SELECT d.display_name, d.bundle_identifier, d.signing_identifier,
                       \(TrafficHistoryStoredDelta.columnNames.map { "b.\($0)" }.joined(separator: ", "))
                FROM application_bucket b
                JOIN application_dimension d ON d.id = b.application_id
                WHERE b.generation = ? AND b.bucket_start_ms >= ? AND b.bucket_start_ms < ?
                ORDER BY d.id, b.bucket_start_ms
                """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, generation)
        sqlite3_bind_int64(statement, 2, lowerBound)
        sqlite3_bind_int64(statement, 3, upperBound)
        var order: [TrafficHistoryApplication.Identity] = []
        var applications: [TrafficHistoryApplication.Identity: TrafficHistoryApplication] = [:]
        var totals: [TrafficHistoryApplication.Identity: TrafficHistoryStoredDelta] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let displayName = trafficHistoryColumnText(statement, index: 0) ?? "Unattributed"
            let bundle = trafficHistoryColumnText(statement, index: 1)
            let signing = trafficHistoryColumnText(statement, index: 2)
            let identity: TrafficHistoryApplication.Identity
            if let bundle {
                identity = .bundleIdentifier(bundle)
            } else if let signing {
                identity = .signingIdentifier(signing)
            } else {
                identity = .unattributed
            }
            if applications[identity] == nil {
                order.append(identity)
                applications[identity] = TrafficHistoryApplication(
                    identity: identity,
                    displayName: displayName
                )
            }
            var aggregate = totals[identity] ?? .zero
            aggregate.add(row: statement, startingAt: 3)
            totals[identity] = aggregate
        }
        return order.compactMap { identity in
            guard let application = applications[identity], let aggregate = totals[identity] else {
                return nil
            }
            return TrafficHistoryApplicationSnapshot(
                application: application,
                totals: aggregate.totals
            )
        }.sorted { lhs, rhs in
            if lhs.totals.exactTotalBytes != rhs.totals.exactTotalBytes {
                return lhs.totals.exactTotalBytes > rhs.totals.exactTotalBytes
            }
            return lhs.application.displayName.localizedCaseInsensitiveCompare(
                rhs.application.displayName
            ) == .orderedAscending
        }
    }

    private func queryRoutes(
        generation: Int64,
        lowerBound: Int64,
        upperBound: Int64
    ) throws -> [TrafficHistoryRouteSnapshot] {
        let statement = try trafficHistoryPrepare(
            database,
            sql: """
                SELECT d.storage_key, d.kind, d.display_name, d.rule_name, d.proxy_chain_json,
                       \(TrafficHistoryStoredDelta.columnNames.map { "b.\($0)" }.joined(separator: ", "))
                FROM route_bucket b
                JOIN route_dimension d ON d.id = b.route_id
                WHERE b.generation = ? AND b.bucket_start_ms >= ? AND b.bucket_start_ms < ?
                ORDER BY d.id, b.bucket_start_ms
                """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, generation)
        sqlite3_bind_int64(statement, 2, lowerBound)
        sqlite3_bind_int64(statement, 3, upperBound)
        var order: [String] = []
        var routes: [String: TrafficHistoryRoute] = [:]
        var totals: [String: TrafficHistoryStoredDelta] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let storageKey = trafficHistoryColumnText(statement, index: 0),
                let rawKind = trafficHistoryColumnText(statement, index: 1),
                let kind = TrafficHistoryRouteKind(rawValue: rawKind)
            else { continue }
            if routes[storageKey] == nil {
                let displayName = trafficHistoryColumnText(statement, index: 2) ?? "Unresolved"
                let ruleName = trafficHistoryColumnText(statement, index: 3)
                let chainJSON = trafficHistoryColumnText(statement, index: 4) ?? "[]"
                let chain = (try? JSONDecoder().decode([String].self, from: Data(chainJSON.utf8))) ?? []
                order.append(storageKey)
                routes[storageKey] = TrafficHistoryRoute(
                    kind: kind,
                    displayName: displayName,
                    ruleName: ruleName,
                    proxyChain: chain
                )
            }
            var aggregate = totals[storageKey] ?? .zero
            aggregate.add(row: statement, startingAt: 5)
            totals[storageKey] = aggregate
        }
        return order.compactMap { key in
            guard let route = routes[key], let aggregate = totals[key] else { return nil }
            return TrafficHistoryRouteSnapshot(route: route, totals: aggregate.totals)
        }.sorted { lhs, rhs in
            if lhs.totals.exactTotalBytes != rhs.totals.exactTotalBytes {
                return lhs.totals.exactTotalBytes > rhs.totals.exactTotalBytes
            }
            return lhs.route.displayName.localizedCaseInsensitiveCompare(
                rhs.route.displayName
            ) == .orderedAscending
        }
    }

    private func pruneInsideTransaction(
        retention: TrafficHistoryRetention,
        now: Date
    ) throws {
        let cutoff = now.addingTimeInterval(-Double(retention.rawValue) * 86_400)
        let cutoffMilliseconds = Self.dateMilliseconds(cutoff)
        let bucketCutoff = Self.bucketStartMilliseconds(for: cutoff)
        for table in ["total_bucket", "application_bucket", "route_bucket"] {
            let statement = try trafficHistoryPrepare(
                database,
                sql: "DELETE FROM \(table) WHERE bucket_start_ms < ?"
            )
            sqlite3_bind_int64(statement, 1, bucketCutoff)
            do {
                try trafficHistoryStepDone(statement)
                sqlite3_finalize(statement)
            } catch {
                sqlite3_finalize(statement)
                throw error
            }
        }
        for table in ["flow_checkpoint", "recent_completion"] {
            let statement = try trafficHistoryPrepare(
                database,
                sql: "DELETE FROM \(table) WHERE completed_at_ms < ?"
            )
            sqlite3_bind_int64(statement, 1, cutoffMilliseconds)
            do {
                try trafficHistoryStepDone(statement)
                sqlite3_finalize(statement)
            } catch {
                sqlite3_finalize(statement)
                throw error
            }
        }
        try trafficHistoryExecute(
            database,
            sql: """
                DELETE FROM application_dimension
                WHERE NOT EXISTS (
                    SELECT 1 FROM application_bucket
                    WHERE application_id = application_dimension.id
                ) AND NOT EXISTS (
                    SELECT 1 FROM recent_completion
                    WHERE application_id = application_dimension.id
                )
                """
        )
        try trafficHistoryExecute(
            database,
            sql: """
                DELETE FROM route_dimension
                WHERE NOT EXISTS (
                    SELECT 1 FROM route_bucket
                    WHERE route_id = route_dimension.id
                ) AND NOT EXISTS (
                    SELECT 1 FROM recent_completion
                    WHERE route_id = route_dimension.id
                )
                """
        )
    }

    private func secureDatabaseFiles() throws {
        do {
            try trafficHistorySecureFiles(databaseURL, fileManager: .default)
        } catch {
            // The directory itself is already private. Sidecar modes are
            // best-effort because SQLite may remove them between operations.
        }
    }

    private static func dateMilliseconds(_ date: Date) -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite else { return value.sign == .minus ? Int64.min : Int64.max }
        if value >= Double(Int64.max) { return Int64.max }
        if value <= Double(Int64.min) { return Int64.min }
        return Int64(value.rounded(.down))
    }

    private static func bucketStartMilliseconds(for date: Date) -> Int64 {
        let milliseconds = dateMilliseconds(date)
        let remainder = milliseconds % minuteMilliseconds
        return remainder >= 0
            ? milliseconds - remainder
            : milliseconds - remainder - minuteMilliseconds
    }
}

/// SQLite is configured in serialized mode and the wrapper never escapes the
/// store actor. The unchecked conformance only permits actor deinitialization
/// to close the C handle safely.
private final class TrafficHistorySQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sqlite3_close_v2(handle)
    }
}

private enum TrafficHistorySetupFailure: Error {
    case configuration
    case migration
    case corrupted
}

private struct TrafficHistoryStoredMeasurement {
    let kind: String
    let bytes: Int64?

    init(_ measurement: TrafficHistoryMeasurement) {
        switch measurement {
        case let .exact(bytes):
            kind = "exact"
            self.bytes = bytes > UInt64(Int64.max) ? Int64.max : Int64(bytes)
        case .notMeasuredAfterHandoff:
            kind = "not_measured"
            bytes = nil
        case .notApplicable:
            kind = "not_applicable"
            bytes = nil
        }
    }
}

private struct TrafficHistoryStoredDelta {
    static let columnNames = [
        "flow_count",
        "exact_upload_bytes",
        "exact_download_bytes",
        "exact_upload_count",
        "exact_download_count",
        "not_measured_upload_count",
        "not_measured_download_count",
        "not_applicable_upload_count",
        "not_applicable_download_count",
    ]

    static let zero = TrafficHistoryStoredDelta(values: Array(repeating: 0, count: 9))

    private(set) var values: [Int64]

    init(completion: TrafficHistoryCompletedFlow) {
        let upload = TrafficHistoryStoredMeasurement(completion.upload)
        let download = TrafficHistoryStoredMeasurement(completion.download)
        values = [
            1,
            upload.bytes ?? 0,
            download.bytes ?? 0,
            upload.kind == "exact" ? 1 : 0,
            download.kind == "exact" ? 1 : 0,
            upload.kind == "not_measured" ? 1 : 0,
            download.kind == "not_measured" ? 1 : 0,
            upload.kind == "not_applicable" ? 1 : 0,
            download.kind == "not_applicable" ? 1 : 0,
        ]
    }

    private init(values: [Int64]) {
        self.values = values
    }

    mutating func add(row: OpaquePointer, startingAt start: Int32) {
        for offset in values.indices {
            let value = max(0, sqlite3_column_int64(row, start + Int32(offset)))
            values[offset] = trafficHistorySaturatingInt64Add(values[offset], value)
        }
    }

    var totals: TrafficHistoryTotals {
        TrafficHistoryTotals(
            completedFlowCount: UInt64(values[0]),
            exactUploadBytes: UInt64(values[1]),
            exactDownloadBytes: UInt64(values[2]),
            coverage: TrafficHistoryCoverage(
                exactDirectionCount: UInt64(
                    trafficHistorySaturatingInt64Add(values[3], values[4])
                ),
                notMeasuredDirectionCount: UInt64(
                    trafficHistorySaturatingInt64Add(values[5], values[6])
                ),
                notApplicableDirectionCount: UInt64(
                    trafficHistorySaturatingInt64Add(values[7], values[8])
                )
            )
        )
    }
}

private func trafficHistorySaturatingInt64Add(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    guard rhs > 0 else { return lhs }
    return lhs > Int64.max - rhs ? Int64.max : lhs + rhs
}

private func trafficHistoryConfigureConnection(_ database: OpaquePointer) throws {
    guard sqlite3_busy_timeout(database, TrafficHistoryStore.busyTimeoutMilliseconds) == SQLITE_OK else {
        throw TrafficHistorySetupFailure.configuration
    }
    do {
        try trafficHistoryExecute(database, sql: "PRAGMA journal_mode = WAL")
        try trafficHistoryExecute(database, sql: "PRAGMA synchronous = FULL")
        try trafficHistoryExecute(database, sql: "PRAGMA foreign_keys = ON")
        try trafficHistoryExecute(database, sql: "PRAGMA trusted_schema = OFF")
    } catch {
        throw trafficHistorySetupFailure(database, fallback: .configuration)
    }
}

private func trafficHistoryCreateV1Schema(
    _ database: OpaquePointer,
    retention: TrafficHistoryRetention,
    now: Date
) throws {
    do {
        try trafficHistoryExecute(database, sql: "BEGIN EXCLUSIVE")
        try trafficHistoryExecute(
            database,
            sql: """
                CREATE TABLE metadata(
                    key TEXT PRIMARY KEY NOT NULL,
                    integer_value INTEGER
                ) STRICT;

                CREATE TABLE total_bucket(
                    generation INTEGER NOT NULL,
                    bucket_start_ms INTEGER NOT NULL,
                    \(trafficHistoryMetricColumnDefinitions),
                    PRIMARY KEY(generation, bucket_start_ms)
                ) WITHOUT ROWID, STRICT;

                CREATE TABLE application_dimension(
                    id INTEGER PRIMARY KEY,
                    storage_key TEXT NOT NULL UNIQUE,
                    display_name TEXT NOT NULL,
                    bundle_identifier TEXT,
                    signing_identifier TEXT,
                    CHECK(length(storage_key) BETWEEN 1 AND 1024),
                    CHECK(length(display_name) BETWEEN 1 AND 255),
                    CHECK(bundle_identifier IS NULL OR length(bundle_identifier) <= 255),
                    CHECK(signing_identifier IS NULL OR length(signing_identifier) <= 255)
                ) STRICT;

                CREATE TABLE application_bucket(
                    generation INTEGER NOT NULL,
                    bucket_start_ms INTEGER NOT NULL,
                    application_id INTEGER NOT NULL REFERENCES application_dimension(id) ON DELETE CASCADE,
                    \(trafficHistoryMetricColumnDefinitions),
                    PRIMARY KEY(generation, bucket_start_ms, application_id)
                ) WITHOUT ROWID, STRICT;

                CREATE TABLE route_dimension(
                    id INTEGER PRIMARY KEY,
                    storage_key TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    rule_name TEXT,
                    proxy_chain_json TEXT NOT NULL,
                    CHECK(length(storage_key) BETWEEN 1 AND 8192),
                    CHECK(length(display_name) BETWEEN 1 AND 255),
                    CHECK(rule_name IS NULL OR length(rule_name) <= 255),
                    CHECK(length(proxy_chain_json) <= 8192)
                ) STRICT;

                CREATE TABLE route_bucket(
                    generation INTEGER NOT NULL,
                    bucket_start_ms INTEGER NOT NULL,
                    route_id INTEGER NOT NULL REFERENCES route_dimension(id) ON DELETE CASCADE,
                    \(trafficHistoryMetricColumnDefinitions),
                    PRIMARY KEY(generation, bucket_start_ms, route_id)
                ) WITHOUT ROWID, STRICT;

                CREATE TABLE flow_checkpoint(
                    source TEXT NOT NULL,
                    flow_identifier TEXT NOT NULL,
                    completed_at_ms INTEGER NOT NULL,
                    generation INTEGER NOT NULL,
                    PRIMARY KEY(source, flow_identifier),
                    CHECK(length(flow_identifier) BETWEEN 1 AND 255)
                ) WITHOUT ROWID, STRICT;
                CREATE INDEX flow_checkpoint_completed_at
                    ON flow_checkpoint(completed_at_ms);

                CREATE TABLE source_checkpoint(
                    source TEXT PRIMARY KEY NOT NULL,
                    sequence INTEGER NOT NULL CHECK(sequence >= 0),
                    updated_at_ms INTEGER NOT NULL
                ) WITHOUT ROWID, STRICT;

                CREATE TABLE recent_completion(
                    id INTEGER PRIMARY KEY,
                    generation INTEGER NOT NULL,
                    source TEXT NOT NULL,
                    flow_identifier TEXT NOT NULL,
                    completed_at_ms INTEGER NOT NULL,
                    application_id INTEGER NOT NULL REFERENCES application_dimension(id),
                    route_id INTEGER NOT NULL REFERENCES route_dimension(id),
                    outcome TEXT NOT NULL,
                    upload_kind TEXT NOT NULL CHECK(upload_kind IN ('exact', 'not_measured', 'not_applicable')),
                    upload_bytes INTEGER CHECK(upload_bytes IS NULL OR upload_bytes >= 0),
                    download_kind TEXT NOT NULL CHECK(download_kind IN ('exact', 'not_measured', 'not_applicable')),
                    download_bytes INTEGER CHECK(download_bytes IS NULL OR download_bytes >= 0),
                    UNIQUE(source, flow_identifier),
                    CHECK(length(flow_identifier) BETWEEN 1 AND 255),
                    CHECK((upload_kind = 'exact') = (upload_bytes IS NOT NULL)),
                    CHECK((download_kind = 'exact') = (download_bytes IS NOT NULL))
                ) STRICT;
                CREATE INDEX recent_completion_completed_at
                    ON recent_completion(completed_at_ms DESC);
                """
        )
        let baseline = Int64((now.timeIntervalSince1970 * 1_000).rounded(.down))
        try trafficHistoryExecute(
            database,
            sql: """
                INSERT INTO metadata(key, integer_value) VALUES
                    ('generation', 1),
                    ('baseline_at_ms', \(baseline)),
                    ('retention_days', \(retention.rawValue));
                PRAGMA user_version = \(TrafficHistoryStore.schemaVersion);
                """
        )
        try trafficHistoryExecute(database, sql: "COMMIT")
    } catch {
        try? trafficHistoryExecute(database, sql: "ROLLBACK")
        throw trafficHistorySetupFailure(database, fallback: .migration)
    }
}

private let trafficHistoryMetricColumnDefinitions = """
    flow_count INTEGER NOT NULL CHECK(flow_count >= 0),
    exact_upload_bytes INTEGER NOT NULL CHECK(exact_upload_bytes >= 0),
    exact_download_bytes INTEGER NOT NULL CHECK(exact_download_bytes >= 0),
    exact_upload_count INTEGER NOT NULL CHECK(exact_upload_count >= 0),
    exact_download_count INTEGER NOT NULL CHECK(exact_download_count >= 0),
    not_measured_upload_count INTEGER NOT NULL CHECK(not_measured_upload_count >= 0),
    not_measured_download_count INTEGER NOT NULL CHECK(not_measured_download_count >= 0),
    not_applicable_upload_count INTEGER NOT NULL CHECK(not_applicable_upload_count >= 0),
    not_applicable_download_count INTEGER NOT NULL CHECK(not_applicable_download_count >= 0)
    """

private func trafficHistoryVerifyQuickCheck(_ database: OpaquePointer) throws {
    do {
        let statement = try trafficHistoryPrepare(database, sql: "PRAGMA quick_check(1)")
        defer { sqlite3_finalize(statement) }
        guard
            sqlite3_step(statement) == SQLITE_ROW,
            trafficHistoryColumnText(statement, index: 0) == "ok"
        else {
            throw TrafficHistorySetupFailure.corrupted
        }
    } catch {
        throw trafficHistorySetupFailure(database, fallback: .corrupted)
    }
}

private func trafficHistorySetupFailure(
    _ database: OpaquePointer,
    fallback: TrafficHistorySetupFailure
) -> TrafficHistorySetupFailure {
    switch sqlite3_errcode(database) {
    case SQLITE_CORRUPT, SQLITE_NOTADB:
        return .corrupted
    default:
        return fallback
    }
}

private func trafficHistorySecureFiles(
    _ databaseURL: URL,
    fileManager: FileManager
) throws {
    let directory = databaseURL.deletingLastPathComponent()
    try fileManager.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
    )
    for url in [
        databaseURL,
        URL(fileURLWithPath: databaseURL.path + "-wal"),
        URL(fileURLWithPath: databaseURL.path + "-shm"),
    ] where fileManager.fileExists(atPath: url.path) {
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

private func trafficHistoryExecute(_ database: OpaquePointer, sql: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
    if let errorMessage { sqlite3_free(errorMessage) }
    guard result == SQLITE_OK else {
        throw TrafficHistoryStoreError.databaseUnavailable
    }
}

private func trafficHistoryScalarInt32(
    _ database: OpaquePointer,
    sql: String
) throws -> Int32 {
    let statement = try trafficHistoryPrepare(database, sql: sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw trafficHistorySetupFailure(database, fallback: .configuration)
    }
    return sqlite3_column_int(statement, 0)
}

private func trafficHistoryScalarText(
    _ database: OpaquePointer,
    sql: String
) throws -> String {
    let statement = try trafficHistoryPrepare(database, sql: sql)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let value = trafficHistoryColumnText(statement, index: 0) else {
        throw trafficHistorySetupFailure(database, fallback: .configuration)
    }
    return value
}

private func trafficHistoryPrepare(
    _ database: OpaquePointer,
    sql: String
) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw TrafficHistoryStoreError.databaseUnavailable
    }
    return statement
}

private func trafficHistoryStepDone(_ statement: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw TrafficHistoryStoreError.databaseUnavailable
    }
}

private func trafficHistoryBindText(
    _ statement: OpaquePointer,
    index: Int32,
    value: String
) throws {
    let result = value.withCString { pointer in
        sqlite3_bind_text(statement, index, pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    guard result == SQLITE_OK else { throw TrafficHistoryStoreError.databaseUnavailable }
}

private func trafficHistoryBindOptionalText(
    _ statement: OpaquePointer,
    index: Int32,
    value: String?
) throws {
    guard let value else {
        guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
            throw TrafficHistoryStoreError.databaseUnavailable
        }
        return
    }
    try trafficHistoryBindText(statement, index: index, value: value)
}

private func trafficHistoryBindOptionalInt64(
    _ statement: OpaquePointer,
    index: Int32,
    value: Int64?
) throws {
    let result = value.map { sqlite3_bind_int64(statement, index, $0) }
        ?? sqlite3_bind_null(statement, index)
    guard result == SQLITE_OK else { throw TrafficHistoryStoreError.databaseUnavailable }
}

private func trafficHistoryColumnText(
    _ statement: OpaquePointer,
    index: Int32
) -> String? {
    guard let text = sqlite3_column_text(statement, index) else { return nil }
    return String(cString: text)
}
