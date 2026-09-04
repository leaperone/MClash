import Foundation
import MClashNetworkShared

/// A stable, presentation-independent account of traffic observed by MClash.
///
/// The ledger deliberately distinguishes measured bytes from traffic that was
/// handed back to the operating system. Normal Direct and fail-open decisions
/// remain explicitly unmeasured rather than becoming a misleading zero. A
/// Direct fallback inside an already-owned flow is measured at confirmed
/// delivery boundaries.
struct FlowLedger: Sendable {
    private static let defaultAssociationWindow: TimeInterval = 15

    private(set) var entries: [FlowLedgerEntry]
    /// Cached route evidence used by persistent SwiftUI surfaces.
    ///
    /// Computing this while the ledger is already being assembled keeps route
    /// parsing off the main actor and prevents every view refresh from scanning
    /// all active and recently closed connections again.
    private(set) var latestNonDirectRouteAt: Date?
    /// Aggregates are built with the ledger on its detached worker. Keeping
    /// them here prevents views and automation polling from repeatedly doing
    /// full scans and sorts on the main actor.
    private(set) var applicationAggregates: [FlowLedgerApplicationAggregate]
    private(set) var routeAggregates: [FlowLedgerRouteAggregate]
    private(set) var outcomeAggregates: [FlowLedgerOutcomeAggregate]
    private(set) var completedEntries: [FlowLedgerEntry]
    private(set) var unmeasuredHandoffCount: Int

    init(
        activeConnections: [MihomoConnection],
        recentlyClosedConnections: [FlowLedgerClosedConnection] = [],
        appRoutingActivities: [AppRoutingActivity] = [],
        flowRelayObservations: [FlowRelayObservation] = [],
        captureOrigins: [String: FlowLedgerCaptureOrigin] = [:],
        defaultProfileID: ProfileID? = nil,
        associationWindow: TimeInterval = defaultAssociationWindow
    ) {
        let activeRecords = activeConnections.map {
            FlowLedgerConnectionRecord(connection: $0, state: .active)
        }
        let closedRecords = recentlyClosedConnections.map {
            FlowLedgerConnectionRecord(
                connection: $0.connection,
                state: .closed(at: $0.closedAt)
            )
        }
        self.init(
            connectionRecords: activeRecords + closedRecords,
            appRoutingActivities: appRoutingActivities,
            flowRelayObservations: flowRelayObservations,
            captureOrigins: captureOrigins,
            defaultProfileID: defaultProfileID,
            associationWindow: associationWindow
        )
    }

    init(
        connectionRecords: [FlowLedgerConnectionRecord],
        appRoutingActivities: [AppRoutingActivity] = [],
        flowRelayObservations: [FlowRelayObservation] = [],
        captureOrigins: [String: FlowLedgerCaptureOrigin] = [:],
        defaultProfileID: ProfileID? = nil,
        associationWindow: TimeInterval = defaultAssociationWindow
    ) {
        entries = []
        latestNonDirectRouteAt = nil
        applicationAggregates = []
        routeAggregates = []
        outcomeAggregates = []
        completedEntries = []
        unmeasuredHandoffCount = 0

        guard !Task<Never, Never>.isCancelled else { return }
        let deduplicatedConnections = Self.deduplicated(connectionRecords)
        let connectionStarts = Dictionary(
            uniqueKeysWithValues: deduplicatedConnections.compactMap { record in
                RuntimeTimestampParser.date(from: record.connection.start).map {
                    (record.connection.id, $0)
                }
            }
        )
        let connectionIndex = ConnectionIndex(
            records: deduplicatedConnections,
            connectionStarts: connectionStarts
        )
        var claimedConnectionIDs: Set<String> = []
        var builtEntries: [FlowLedgerEntry] = []
        builtEntries.reserveCapacity(
            deduplicatedConnections.count
                + appRoutingActivities.count
                + flowRelayObservations.count
        )

        // Native connectors publish observations directly.  They are projected
        // before legacy connections so the ledger remains useful when Mihomo
        // is absent, while the existing connection/activity association keeps
        // its historical behaviour unchanged.
        for observation in Self.deduplicated(flowRelayObservations) {
            guard !Task<Never, Never>.isCancelled else { return }
            builtEntries.append(
                Self.entry(
                    observation: observation,
                    defaultProfileID: defaultProfileID
                )
            )
        }

        // Activities with a relay source port get first choice of a connection.
        // This prevents a less precise destination/time association from claiming
        // a connection before its exact App Routing owner is considered.
        let orderedActivities = appRoutingActivities.sorted { lhs, rhs in
            let lhsHasRelayPort = lhs.relayLocalPort != nil
            let rhsHasRelayPort = rhs.relayLocalPort != nil
            if lhsHasRelayPort != rhsHasRelayPort { return lhsHasRelayPort }
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.flowIdentifier.uuidString < rhs.flowIdentifier.uuidString
        }

        for activity in orderedActivities {
            guard !Task<Never, Never>.isCancelled else { return }
            // This ledger currently receives connection snapshots from the
            // default Core. Never associate an auxiliary-profile activity
            // with a lookalike connection from that different Core.
            let canAssociateWithDefaultCore = switch activity.mclashTrafficTarget {
            case .defaultProfile:
                true
            case let .profile(profileID):
                profileID == defaultProfileID
            case .system:
                false
            }
            let match = canAssociateWithDefaultCore
                ? Self.connectionMatch(
                    for: activity,
                    in: connectionIndex,
                    excluding: claimedConnectionIDs,
                    associationWindow: max(0, associationWindow)
                )
                : nil
            if let connectionID = match?.record.connection.id {
                claimedConnectionIDs.insert(connectionID)
            }
            builtEntries.append(
                Self.entry(
                    activity: activity,
                    match: match,
                    defaultProfileID: defaultProfileID
                )
            )
        }

        for record in deduplicatedConnections
        where !claimedConnectionIDs.contains(record.connection.id) {
            guard !Task<Never, Never>.isCancelled else { return }
            builtEntries.append(
                Self.entry(
                    record: record,
                    startedAt: connectionStarts[record.connection.id],
                    captureOrigin: captureOrigins[record.connection.id],
                    defaultProfileID: defaultProfileID
                )
            )
        }

        entries = builtEntries.sorted(by: Self.entriesAreMoreRecent)
        latestNonDirectRouteAt = Self.latestNonDirectRouteDate(in: builtEntries)
        applicationAggregates = Self.makeApplicationAggregates(from: builtEntries)
        routeAggregates = Self.makeRouteAggregates(from: builtEntries)
        outcomeAggregates = Self.makeOutcomeAggregates(from: builtEntries)
        completedEntries = entries.filter { !$0.state.isActive }
        unmeasuredHandoffCount = builtEntries.count {
            $0.upload == .notMeasuredAfterHandoff
                || $0.download == .notMeasuredAfterHandoff
        }
    }

    func recentEntries(limit: Int, since cutoff: Date? = nil) -> [FlowLedgerEntry] {
        guard limit > 0 else { return [] }
        return entries.lazy
            .filter { entry in
                guard let cutoff else { return true }
                return (entry.endedAt ?? entry.startedAt ?? .distantPast) >= cutoff
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Returns a stable page from the already ordered snapshot. Pagination is
    /// applied after the optional time filter, so loading another page does
    /// not reshuffle rows while live observations are being refreshed.
    func recentEntriesPage(
        limit: Int,
        offset: Int,
        since cutoff: Date? = nil
    ) -> [FlowLedgerEntry] {
        guard limit > 0, offset >= 0 else { return [] }
        return entries.lazy
            .filter { entry in
                guard let cutoff else { return true }
                return (entry.endedAt ?? entry.startedAt ?? .distantPast) >= cutoff
            }
            .dropFirst(offset)
            .prefix(limit)
            .map { $0 }
    }

    func entries(for profileID: ProfileID?) -> [FlowLedgerEntry] {
        guard let profileID else { return entries }
        return entries.filter { $0.profileID == profileID }
    }

    func entries(for target: ProfileTrafficTarget?) -> [FlowLedgerEntry] {
        guard let target else { return entries }
        return entries.filter { $0.trafficTarget == target }
    }

    func applicationAggregates(for profileID: ProfileID?) -> [FlowLedgerApplicationAggregate] {
        guard let profileID else { return applicationAggregates }
        return Self.makeApplicationAggregates(
            from: entries.filter { $0.profileID == profileID }
        )
    }

    func applicationAggregates(
        for target: ProfileTrafficTarget?
    ) -> [FlowLedgerApplicationAggregate] {
        guard let target else { return applicationAggregates }
        return Self.makeApplicationAggregates(
            from: entries.filter { $0.trafficTarget == target }
        )
    }

    func routeAggregates(for profileID: ProfileID?) -> [FlowLedgerRouteAggregate] {
        guard let profileID else { return routeAggregates }
        return Self.makeRouteAggregates(
            from: entries.filter { $0.profileID == profileID }
        )
    }

    func routeAggregates(
        for target: ProfileTrafficTarget?
    ) -> [FlowLedgerRouteAggregate] {
        guard let target else { return routeAggregates }
        return Self.makeRouteAggregates(
            from: entries.filter { $0.trafficTarget == target }
        )
    }

    func completedEntries(for profileID: ProfileID?) -> [FlowLedgerEntry] {
        guard let profileID else { return completedEntries }
        return completedEntries.filter { $0.profileID == profileID }
    }

    func completedEntries(for target: ProfileTrafficTarget?) -> [FlowLedgerEntry] {
        guard let target else { return completedEntries }
        return completedEntries.filter { $0.trafficTarget == target }
    }

    private static func makeApplicationAggregates(
        from entries: [FlowLedgerEntry]
    ) -> [FlowLedgerApplicationAggregate] {
        var aggregates: [FlowLedgerApplicationKey: FlowLedgerApplicationAggregate] = [:]
        for entry in entries {
            let key = entry.application.key
            var aggregate = aggregates[key]
                ?? FlowLedgerApplicationAggregate(application: entry.application)
            aggregate.add(entry)
            aggregates[key] = aggregate
        }
        return aggregates.values.sorted {
            if $0.traffic.exactTotalBytes != $1.traffic.exactTotalBytes {
                return $0.traffic.exactTotalBytes > $1.traffic.exactTotalBytes
            }
            if $0.entryCount != $1.entryCount { return $0.entryCount > $1.entryCount }
            return $0.application.displayName.localizedStandardCompare(
                $1.application.displayName
            ) == .orderedAscending
        }
    }

    private static func makeRouteAggregates(
        from entries: [FlowLedgerEntry]
    ) -> [FlowLedgerRouteAggregate] {
        var aggregates: [FlowLedgerRouteKey: FlowLedgerRouteAggregate] = [:]
        for entry in entries {
            let key = entry.routeKey
            var aggregate = aggregates[key] ?? FlowLedgerRouteAggregate(route: key)
            aggregate.add(entry)
            aggregates[key] = aggregate
        }
        return aggregates.values.sorted {
            if $0.traffic.exactTotalBytes != $1.traffic.exactTotalBytes {
                return $0.traffic.exactTotalBytes > $1.traffic.exactTotalBytes
            }
            if $0.entryCount != $1.entryCount { return $0.entryCount > $1.entryCount }
            return $0.route.sortKey < $1.route.sortKey
        }
    }

    private static func makeOutcomeAggregates(
        from entries: [FlowLedgerEntry]
    ) -> [FlowLedgerOutcomeAggregate] {
        var aggregates: [FlowLedgerOutcome: FlowLedgerOutcomeAggregate] = [:]
        for entry in entries {
            var aggregate = aggregates[entry.outcome]
                ?? FlowLedgerOutcomeAggregate(outcome: entry.outcome)
            aggregate.add(entry)
            aggregates[entry.outcome] = aggregate
        }
        return aggregates.values.sorted { $0.outcome.sortOrder < $1.outcome.sortOrder }
    }

    private struct ConnectionMatch {
        let record: FlowLedgerConnectionRecord
        let association: FlowLedgerAssociation
    }

    private struct IndexedConnection {
        let record: FlowLedgerConnectionRecord
        let startedAt: Date
    }

    private struct ConnectionDestinationKey: Hashable {
        let host: String
        let port: UInt16
    }

    private struct RelayConnectionKey: Hashable {
        let destination: ConnectionDestinationKey
        let sourcePort: UInt16
    }

    /// Narrows activity matching to connections which share a normalized
    /// destination before applying protocol/time/relay-port tie breaking.
    /// The previous implementation scanned every retained connection once per
    /// activity, which became quadratic at the 2,000-activity retention limit.
    private struct ConnectionIndex {
        private let byDestination: [ConnectionDestinationKey: [IndexedConnection]]
        private let byRelaySourcePort: [RelayConnectionKey: [IndexedConnection]]

        init(
            records: [FlowLedgerConnectionRecord],
            connectionStarts: [String: Date]
        ) {
            var index: [ConnectionDestinationKey: [IndexedConnection]] = [:]
            var relayIndex: [RelayConnectionKey: [IndexedConnection]] = [:]
            for record in records {
                guard !Task<Never, Never>.isCancelled,
                      FlowLedger.isAppRoutingInbound(record.connection.metadata.inboundName),
                      let portText = record.connection.metadata.destinationPort,
                      let port = UInt16(portText),
                      let startedAt = connectionStarts[record.connection.id]
                else { continue }

                let hosts = Set(
                    [
                        record.connection.metadata.host,
                        record.connection.metadata.sniffHost,
                        record.connection.metadata.destinationIP,
                        record.connection.metadata.remoteDestination,
                    ].compactMap(FlowLedger.normalizedHost)
                )
                let candidate = IndexedConnection(record: record, startedAt: startedAt)
                for host in hosts {
                    let destination = ConnectionDestinationKey(host: host, port: port)
                    index[destination, default: []]
                        .append(candidate)
                    if let sourcePortText = record.connection.metadata.sourcePort,
                       let sourcePort = UInt16(sourcePortText) {
                        relayIndex[
                            RelayConnectionKey(
                                destination: destination,
                                sourcePort: sourcePort
                            ),
                            default: []
                        ].append(candidate)
                    }
                }
            }
            byDestination = index
            byRelaySourcePort = relayIndex
        }

        func forEachCandidate(
            for activity: AppRoutingActivity,
            relaySourcePort: UInt16? = nil,
            _ body: (IndexedConnection) -> Void
        ) {
            guard activity.destination.port > 0 else { return }
            let hostname = FlowLedger.normalizedHost(activity.destination.hostname)
            let ipAddress = FlowLedger.normalizedHost(activity.destination.ipAddress)

            func visit(_ host: String?) {
                guard let host else { return }
                let destination = ConnectionDestinationKey(
                    host: host,
                    port: activity.destination.port
                )
                let candidates: [IndexedConnection]
                if let relaySourcePort {
                    candidates = byRelaySourcePort[
                        RelayConnectionKey(
                            destination: destination,
                            sourcePort: relaySourcePort
                        )
                    ] ?? []
                } else {
                    candidates = byDestination[destination] ?? []
                }
                for candidate in candidates {
                    body(candidate)
                }
            }

            visit(hostname)
            if ipAddress != hostname {
                visit(ipAddress)
            }
        }
    }

    private static func deduplicated(
        _ records: [FlowLedgerConnectionRecord]
    ) -> [FlowLedgerConnectionRecord] {
        var byIdentifier: [String: FlowLedgerConnectionRecord] = [:]
        for record in records {
            if let existing = byIdentifier[record.connection.id],
               existing.state.isActive,
               !record.state.isActive {
                continue
            }
            byIdentifier[record.connection.id] = record
        }
        return byIdentifier.values.sorted { $0.connection.id < $1.connection.id }
    }

    private static func deduplicated(
        _ observations: [FlowRelayObservation]
    ) -> [FlowRelayObservation] {
        // A connector can publish an active update followed by a terminal
        // update with the same id. Keep the terminal record, or otherwise the
        // latest record supplied by the caller, without requiring a Mihomo
        // connection as a de-duplication anchor.
        var byIdentifier: [String: FlowRelayObservation] = [:]
        for observation in observations {
            if let existing = byIdentifier[observation.id],
               Self.observationRank(existing.state) > Self.observationRank(observation.state) {
                continue
            }
            byIdentifier[observation.id] = observation
        }
        return byIdentifier.values.sorted {
            let lhsDate = $0.endedAt ?? $0.startedAt ?? .distantPast
            let rhsDate = $1.endedAt ?? $1.startedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return $0.id < $1.id
        }
    }

    private static func observationRank(
        _ state: FlowRelayObservation.State
    ) -> Int {
        switch state {
        case .active: 0
        case .completed, .rejected, .failed: 1
        }
    }

    private static func connectionMatch(
        for activity: AppRoutingActivity,
        in index: ConnectionIndex,
        excluding claimedConnectionIDs: Set<String>,
        associationWindow: TimeInterval
    ) -> ConnectionMatch? {
        guard case .outbound = activity.effectiveAction else { return nil }

        func preferredCandidate(
            relaySourcePort: UInt16? = nil
        ) -> (record: FlowLedgerConnectionRecord, delta: TimeInterval)? {
            var best: (
                record: FlowLedgerConnectionRecord,
                delta: TimeInterval
            )?
            index.forEachCandidate(
                for: activity,
                relaySourcePort: relaySourcePort
            ) { candidate in
                let record = candidate.record
                guard !Task<Never, Never>.isCancelled,
                      !claimedConnectionIDs.contains(record.connection.id),
                      transportMatches(activity, connection: record.connection)
                else { return }
                let delta = abs(candidate.startedAt.timeIntervalSince(activity.startedAt))
                guard delta <= associationWindow else { return }
                let eligible = (record: record, delta: delta)
                if let currentBest = best {
                    if candidateIsPreferred(eligible, currentBest) {
                        best = eligible
                    }
                } else {
                    best = eligible
                }
            }
            return best
        }

        if let relayLocalPort = activity.relayLocalPort {
            let exact = preferredCandidate(relaySourcePort: relayLocalPort)
            if let exact {
                return ConnectionMatch(
                    record: exact.record,
                    association: .exactRelayPort(connectionID: exact.record.connection.id)
                )
            }
        }

        guard let heuristic = preferredCandidate() else { return nil }
            return ConnectionMatch(
                record: heuristic.record,
                association: .destinationAndStartTime(
                connectionID: heuristic.record.connection.id,
                difference: heuristic.delta
                )
            )
    }

    private static func candidateIsPreferred(
        _ lhs: (record: FlowLedgerConnectionRecord, delta: TimeInterval),
        _ rhs: (record: FlowLedgerConnectionRecord, delta: TimeInterval)
    ) -> Bool {
        if lhs.delta != rhs.delta { return lhs.delta < rhs.delta }
        if lhs.record.state.isActive != rhs.record.state.isActive {
            return lhs.record.state.isActive
        }
        return lhs.record.connection.id < rhs.record.connection.id
    }

    private static func destinationMatches(
        _ activity: AppRoutingActivity,
        connection: MihomoConnection
    ) -> Bool {
        guard activity.destination.port > 0,
              connection.metadata.destinationPort == String(activity.destination.port)
        else { return false }

        let expected = Set(
            [activity.destination.hostname, activity.destination.ipAddress]
                .compactMap(normalizedHost)
        )
        let actual = Set(
            [
                connection.metadata.host,
                connection.metadata.sniffHost,
                connection.metadata.destinationIP,
                connection.metadata.remoteDestination,
            ].compactMap(normalizedHost)
        )
        return !expected.isEmpty && !actual.isEmpty && !expected.isDisjoint(with: actual)
    }

    private static func transportMatches(
        _ activity: AppRoutingActivity,
        connection: MihomoConnection
    ) -> Bool {
        guard let network = nonEmpty(connection.metadata.network)?.lowercased() else {
            return true
        }
        return network == activity.transportProtocol.rawValue
    }

    private static func isAppRoutingInbound(_ name: String?) -> Bool {
        name?.hasPrefix(
            NetworkExtensionMihomoListenerConfiguration.listenerNamePrefix
        ) == true
    }

    private static func entry(
        activity: AppRoutingActivity,
        match: ConnectionMatch?,
        defaultProfileID: ProfileID?
    ) -> FlowLedgerEntry {
        let outcome = outcome(activity)
        let state = state(activity)
        let matchedRoute = match.map { Self.route($0.record.connection) }
        let measurements = measurements(activity)
        let captureOrigin: FlowLedgerCaptureOrigin
        switch activity.effectiveCaptureOrigin {
        case .appRouting:
            captureOrigin = .appRouting
        case .dnsProxy:
            captureOrigin = .dnsProxy
        }

        return FlowLedgerEntry(
            id: .appRouting(activity.flowIdentifier),
            application: application(activity.source),
            captureOrigin: captureOrigin,
            destination: destination(activity.destination),
            appRoutingRule: nonEmpty(activity.matchedRuleIdentifier),
            outboundRoute: matchedRoute,
            trafficTarget: activity.mclashTrafficTarget,
            profileID: activity.mclashProfileID(defaultProfileID: defaultProfileID),
            association: match?.association ?? .none,
            state: state,
            outcome: outcome,
            startedAt: activity.startedAt,
            endedAt: activity.endedAt ?? match?.record.state.closedAt,
            upload: measurements.upload,
            download: measurements.download
        )
    }

    private static func entry(
        record: FlowLedgerConnectionRecord,
        startedAt: Date?,
        captureOrigin explicitOrigin: FlowLedgerCaptureOrigin?,
        defaultProfileID: ProfileID?
    ) -> FlowLedgerEntry {
        let connection = record.connection
        return FlowLedgerEntry(
            id: .legacyConnection(connection.id),
            application: application(connection.metadata),
            captureOrigin: explicitOrigin ?? inferredOrigin(connection.metadata),
            destination: destination(connection.metadata),
            appRoutingRule: nil,
            outboundRoute: route(connection),
            trafficTarget: .defaultProfile,
            profileID: defaultProfileID,
            association: .none,
            state: record.state.isActive ? .active : .completed,
            outcome: .viaOutbound,
            startedAt: startedAt,
            endedAt: record.state.closedAt,
            upload: .exact(normalizedBytes(connection.upload)),
            download: .exact(normalizedBytes(connection.download))
        )
    }

    private static func entry(
        observation: FlowRelayObservation,
        defaultProfileID: ProfileID?
    ) -> FlowLedgerEntry {
        let routeEvidence: FlowLedgerOutboundRoute? = {
            guard observation.route == .relay || !observation.routeChain.isEmpty else {
                return nil
            }
            return FlowLedgerOutboundRoute(
                rule: nonEmpty(observation.rule),
                rulePayload: nonEmpty(observation.rulePayload),
                chain: observation.routeChain,
                providerChain: observation.providerChain
            )
        }()
        let outcome: FlowLedgerOutcome = switch observation.route {
        case .direct: .direct
        case .rejected: .rejected
        case .failOpen: .failOpen
        case .relay: .viaOutbound
        case .unknown: observation.state == .failed ? .relayFailed : .viaOutbound
        }
        let state: FlowLedgerState = switch observation.state {
        case .active: .active
        case .completed: .completed
        case .rejected: .rejected
        case .failed: .failed(message: nonEmpty(observation.failureReason))
        }
        let upload: FlowLedgerByteMeasurement = switch observation.route {
        case .rejected: .notApplicable
        case .direct where observation.state == .active,
             .failOpen where observation.state == .active:
            .notMeasuredAfterHandoff
        default: .exact(observation.uploadBytes)
        }
        let download: FlowLedgerByteMeasurement = switch observation.route {
        case .rejected: .notApplicable
        case .direct where observation.state == .active,
             .failOpen where observation.state == .active:
            .notMeasuredAfterHandoff
        default: .exact(observation.downloadBytes)
        }
        return FlowLedgerEntry(
            id: .native(observation.id),
            application: application(observation),
            captureOrigin: captureOrigin(observation),
            destination: FlowLedgerDestination(
                hostname: nonEmpty(observation.destinationHost),
                ipAddress: nonEmpty(observation.destinationIP),
                port: observation.destinationPort
            ),
            appRoutingRule: nonEmpty(observation.rule),
            outboundRoute: routeEvidence,
            trafficTarget: .defaultProfile,
            profileID: defaultProfileID,
            association: .none,
            state: state,
            outcome: outcome,
            startedAt: observation.startedAt,
            endedAt: observation.endedAt,
            upload: upload,
            download: download
        )
    }

    private static func application(
        _ observation: FlowRelayObservation
    ) -> FlowLedgerApplication {
        let process = nonEmpty(observation.process)
        let path = nonEmpty(observation.processPath)
        guard let displayName = process ?? path.map({ ($0 as NSString).lastPathComponent }) else {
            return .unattributed
        }
        return FlowLedgerApplication(
            key: applicationKey(
                bundleIdentifier: nil,
                executablePath: path,
                processName: displayName
            ),
            displayName: displayName,
            bundleIdentifier: nil,
            executablePath: path,
            processIdentifier: nil,
            userIdentifier: nil,
            signingIdentifier: nil
        )
    }

    private static func captureOrigin(
        _ observation: FlowRelayObservation
    ) -> FlowLedgerCaptureOrigin {
        guard let inboundName = nonEmpty(observation.inboundName) else {
            return .unknown
        }
        if inboundName.hasPrefix(NetworkExtensionMihomoListenerConfiguration.listenerNamePrefix)
            || inboundName.hasPrefix("native-") {
            return .appRouting
        }
        return .localListener(name: inboundName)
    }

    private static func application(
        _ source: AppRoutingActivitySource
    ) -> FlowLedgerApplication {
        let bundleIdentifier = nonEmpty(source.bundleIdentifier)
        let executablePath = nonEmpty(source.executablePath)
        let signingIdentifier = nonEmpty(source.signingIdentifier)
        let displayName = executablePath.map {
            ($0 as NSString).lastPathComponent
        } ?? bundleIdentifier ?? signingIdentifier

        guard let displayName else { return .unattributed }
        return FlowLedgerApplication(
            key: applicationKey(
                bundleIdentifier: bundleIdentifier,
                executablePath: executablePath,
                processName: displayName
            ),
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            executablePath: executablePath,
            processIdentifier: source.processIdentifier > 0
                ? source.processIdentifier
                : nil,
            userIdentifier: source.userIdentifier,
            signingIdentifier: signingIdentifier
        )
    }

    private static func application(
        _ metadata: MihomoConnectionMetadata
    ) -> FlowLedgerApplication {
        let processName = nonEmpty(metadata.process)
        let executablePath = nonEmpty(metadata.processPath)
        guard let displayName = processName ?? executablePath.map({
            ($0 as NSString).lastPathComponent
        }) else {
            return .unattributed
        }
        return FlowLedgerApplication(
            key: applicationKey(
                bundleIdentifier: nil,
                executablePath: executablePath,
                processName: displayName
            ),
            displayName: displayName,
            bundleIdentifier: nil,
            executablePath: executablePath,
            processIdentifier: nil,
            userIdentifier: metadata.uid,
            signingIdentifier: nil
        )
    }

    private static func applicationKey(
        bundleIdentifier: String?,
        executablePath: String?,
        processName: String
    ) -> FlowLedgerApplicationKey {
        if let bundleIdentifier { return .bundleIdentifier(bundleIdentifier.lowercased()) }
        if let executablePath { return .executablePath(executablePath) }
        return .processName(processName.lowercased())
    }

    private static func inferredOrigin(
        _ metadata: MihomoConnectionMetadata
    ) -> FlowLedgerCaptureOrigin {
        if isAppRoutingInbound(metadata.inboundName) { return .appRouting }
        if let inboundName = nonEmpty(metadata.inboundName) {
            return .localListener(name: inboundName)
        }
        return .unknown
    }

    private static func destination(
        _ source: AppRoutingActivityDestination
    ) -> FlowLedgerDestination {
        FlowLedgerDestination(
            hostname: nonEmpty(source.hostname),
            ipAddress: nonEmpty(source.ipAddress),
            port: source.port > 0 ? source.port : nil
        )
    }

    private static func destination(
        _ metadata: MihomoConnectionMetadata
    ) -> FlowLedgerDestination {
        let port = nonEmpty(metadata.destinationPort).flatMap(UInt16.init)
        return FlowLedgerDestination(
            hostname: nonEmpty(metadata.host) ?? nonEmpty(metadata.sniffHost),
            ipAddress: nonEmpty(metadata.destinationIP),
            port: port
        )
    }

    private static func route(_ connection: MihomoConnection) -> FlowLedgerOutboundRoute {
        let explanation = RoutingExplanation(connection)
        return FlowLedgerOutboundRoute(
            rule: nonEmpty(connection.rule),
            rulePayload: nonEmpty(connection.rulePayload),
            chain: explanation.chains,
            providerChain: explanation.routeHops.map(\.provider)
        )
    }

    private static func outcome(_ activity: AppRoutingActivity) -> FlowLedgerOutcome {
        if activity.relayState == .failed { return .relayFailed }
        return switch activity.effectiveAction {
        case .direct: .direct
        case .reject: .rejected
        case .failOpen: .failOpen
        case .outbound: .viaOutbound
        }
    }

    private static func state(_ activity: AppRoutingActivity) -> FlowLedgerState {
        if activity.relayState == .failed {
            return .failed(message: nonEmpty(activity.relayError))
        }
        if case .reject = activity.effectiveAction { return .rejected }
        return switch activity.relayState {
        case .pending, .connecting, .ready, .relaying:
            .active
        case .completed, .notApplicable:
            .completed
        case .failed:
            .failed(message: nonEmpty(activity.relayError))
        }
    }

    private static func measurements(
        _ activity: AppRoutingActivity
    ) -> (upload: FlowLedgerByteMeasurement, download: FlowLedgerByteMeasurement) {
        switch activity.effectiveAction {
        case .direct where activity.payloadBytesAreMeasured == true:
            (.exact(activity.uploadBytes), .exact(activity.downloadBytes))
        case .direct, .failOpen:
            (.notMeasuredAfterHandoff, .notMeasuredAfterHandoff)
        case .reject:
            (.notApplicable, .notApplicable)
        case .outbound:
            (.exact(activity.uploadBytes), .exact(activity.downloadBytes))
        }
    }

    private static func latestNonDirectRouteDate(
        in entries: [FlowLedgerEntry]
    ) -> Date? {
        entries.lazy.compactMap { entry -> Date? in
            guard let terminal = entry.outboundRoute?.chain.last,
                  !isNonProxyTerminal(terminal) else {
                return nil
            }
            return entry.startedAt
        }.max()
    }

    private static func isNonProxyTerminal(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "DIRECT", "REJECT", "REJECT-DROP", "PASS": true
        default: false
        }
    }

    private static func normalizedHost(_ rawValue: String?) -> String? {
        guard var value = nonEmpty(rawValue)?.lowercased() else { return nil }
        if value.hasPrefix("[") && value.contains("]") {
            value = String(value.dropFirst().prefix { $0 != "]" })
        } else if value.filter({ $0 == ":" }).count == 1,
                  let separator = value.lastIndex(of: ":"),
                  UInt16(value[value.index(after: separator)...]) != nil {
            value = String(value[..<separator])
        }
        while value.hasSuffix(".") { value.removeLast() }
        return value.isEmpty ? nil : value
    }

    private static func normalizedBytes(_ bytes: Int64) -> UInt64 {
        UInt64(max(0, bytes))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func entriesAreMoreRecent(
        _ lhs: FlowLedgerEntry,
        _ rhs: FlowLedgerEntry
    ) -> Bool {
        let lhsDate = lhs.endedAt ?? lhs.startedAt ?? .distantPast
        let rhsDate = rhs.endedAt ?? rhs.startedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.id.sortKey < rhs.id.sortKey
    }
}

enum FlowLedgerEntryID: Hashable, Sendable {
    case appRouting(UUID)
    /// Identifier produced by the legacy connection snapshot adapter.
    case legacyConnection(String)
    case native(String)

    fileprivate var sortKey: String {
        switch self {
        case let .appRouting(id): "app:\(id.uuidString)"
        case let .legacyConnection(id): "mihomo:\(id)"
        case let .native(id): "native:\(id)"
        }
    }
}

struct FlowLedgerEntry: Hashable, Sendable, Identifiable {
    let id: FlowLedgerEntryID
    let application: FlowLedgerApplication
    let captureOrigin: FlowLedgerCaptureOrigin
    let destination: FlowLedgerDestination
    let appRoutingRule: String?
    let outboundRoute: FlowLedgerOutboundRoute?
    let trafficTarget: ProfileTrafficTarget
    /// Compatibility projection for consumers which still need the real
    /// Profile backing a virtual Default flow.
    let profileID: ProfileID?
    let association: FlowLedgerAssociation
    let state: FlowLedgerState
    let outcome: FlowLedgerOutcome
    let startedAt: Date?
    let endedAt: Date?
    let upload: FlowLedgerByteMeasurement
    let download: FlowLedgerByteMeasurement

    var routeKey: FlowLedgerRouteKey {
        switch outcome {
        case .direct: .direct
        case .rejected: .rejected
        case .failOpen: .failOpen
        case .relayFailed: .relayFailed(appRoutingRule: appRoutingRule)
        case .viaOutbound:
            if let outboundRoute {
                .outbound(
                    rule: outboundRoute.rule,
                    rulePayload: outboundRoute.rulePayload,
                    chain: outboundRoute.chain
                )
            } else {
                .unresolvedOutbound(appRoutingRule: appRoutingRule)
            }
        }
    }
}

enum FlowLedgerByteMeasurement: Hashable, Sendable {
    case exact(UInt64)
    case notMeasuredAfterHandoff
    case notApplicable
}

enum FlowLedgerCaptureOrigin: Hashable, Sendable {
    case systemProxy
    case appRouting
    case dnsProxy
    case localListener(name: String)
    case unknown
}

enum FlowLedgerAssociation: Hashable, Sendable {
    case exactRelayPort(connectionID: String)
    case destinationAndStartTime(connectionID: String, difference: TimeInterval)
    case none
}

enum FlowLedgerState: Hashable, Sendable {
    case active
    case completed
    case rejected
    case failed(message: String?)

    var isActive: Bool { self == .active }
}

enum FlowLedgerOutcome: String, CaseIterable, Hashable, Sendable {
    case viaOutbound
    case direct
    case rejected
    case failOpen
    case relayFailed

    fileprivate var sortOrder: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }
}

struct FlowLedgerDestination: Hashable, Sendable {
    let hostname: String?
    let ipAddress: String?
    let port: UInt16?
}

enum FlowLedgerApplicationKey: Hashable, Sendable {
    case bundleIdentifier(String)
    case executablePath(String)
    case processName(String)
    case unattributed
}

struct FlowLedgerApplication: Hashable, Sendable {
    static let unattributed = FlowLedgerApplication(
        key: .unattributed,
        displayName: "Unattributed",
        bundleIdentifier: nil,
        executablePath: nil,
        processIdentifier: nil,
        userIdentifier: nil,
        signingIdentifier: nil
    )

    let key: FlowLedgerApplicationKey
    let displayName: String
    let bundleIdentifier: String?
    let executablePath: String?
    let processIdentifier: Int32?
    let userIdentifier: UInt32?
    let signingIdentifier: String?

    var isAttributed: Bool { key != .unattributed }
}

struct FlowLedgerOutboundRoute: Hashable, Sendable {
    let rule: String?
    let rulePayload: String?
    /// Root-to-leaf route order suitable for user-facing explanation.
    let chain: [String]
    let providerChain: [String?]
}

enum FlowLedgerRouteKey: Hashable, Sendable {
    case outbound(rule: String?, rulePayload: String?, chain: [String])
    case unresolvedOutbound(appRoutingRule: String?)
    case direct
    case rejected
    case failOpen
    case relayFailed(appRoutingRule: String?)

    fileprivate var sortKey: String {
        switch self {
        case let .outbound(rule, payload, chain):
            "outbound:\(rule ?? ""):\(payload ?? ""):\(chain.joined(separator: "→"))"
        case let .unresolvedOutbound(rule): "outbound-unresolved:\(rule ?? "")"
        case .direct: "direct"
        case .rejected: "rejected"
        case .failOpen: "fail-open"
        case let .relayFailed(rule): "relay-failed:\(rule ?? "")"
        }
    }
}

struct FlowLedgerClosedConnection: Sendable {
    let connection: MihomoConnection
    let closedAt: Date
}

struct FlowLedgerConnectionRecord: Sendable {
    enum State: Sendable {
        case active
        case closed(at: Date)

        fileprivate var isActive: Bool {
            if case .active = self { return true }
            return false
        }

        fileprivate var closedAt: Date? {
            guard case let .closed(at) = self else { return nil }
            return at
        }
    }

    let connection: MihomoConnection
    let state: State
}

struct FlowLedgerTrafficAggregate: Hashable, Sendable {
    private(set) var exactUploadBytes: UInt64 = 0
    private(set) var exactDownloadBytes: UInt64 = 0
    private(set) var notMeasuredAfterHandoffCount = 0
    private(set) var notApplicableCount = 0

    var exactTotalBytes: UInt64 {
        let (total, overflow) = exactUploadBytes.addingReportingOverflow(exactDownloadBytes)
        return overflow ? .max : total
    }

    fileprivate mutating func add(_ entry: FlowLedgerEntry) {
        exactUploadBytes = saturatingAdd(exactUploadBytes, entry.upload.exactBytes)
        exactDownloadBytes = saturatingAdd(exactDownloadBytes, entry.download.exactBytes)
        if entry.upload == .notMeasuredAfterHandoff
            || entry.download == .notMeasuredAfterHandoff {
            notMeasuredAfterHandoffCount += 1
        }
        if entry.upload == .notApplicable || entry.download == .notApplicable {
            notApplicableCount += 1
        }
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}

private extension FlowLedgerByteMeasurement {
    var exactBytes: UInt64 {
        guard case let .exact(bytes) = self else { return 0 }
        return bytes
    }
}

struct FlowLedgerApplicationAggregate: Hashable, Sendable, Identifiable {
    let application: FlowLedgerApplication
    private(set) var entryCount = 0
    private(set) var activeCount = 0
    private(set) var traffic = FlowLedgerTrafficAggregate()

    var id: FlowLedgerApplicationKey { application.key }

    fileprivate mutating func add(_ entry: FlowLedgerEntry) {
        entryCount += 1
        if entry.state.isActive { activeCount += 1 }
        traffic.add(entry)
    }
}

struct FlowLedgerRouteAggregate: Hashable, Sendable, Identifiable {
    let route: FlowLedgerRouteKey
    private(set) var entryCount = 0
    private(set) var activeCount = 0
    private(set) var traffic = FlowLedgerTrafficAggregate()

    var id: FlowLedgerRouteKey { route }

    fileprivate mutating func add(_ entry: FlowLedgerEntry) {
        entryCount += 1
        if entry.state.isActive { activeCount += 1 }
        traffic.add(entry)
    }
}

struct FlowLedgerOutcomeAggregate: Hashable, Sendable {
    let outcome: FlowLedgerOutcome
    private(set) var entryCount = 0
    private(set) var activeCount = 0
    private(set) var traffic = FlowLedgerTrafficAggregate()

    fileprivate mutating func add(_ entry: FlowLedgerEntry) {
        entryCount += 1
        if entry.state.isActive { activeCount += 1 }
        traffic.add(entry)
    }
}
