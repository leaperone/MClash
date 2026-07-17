import Foundation
import MClashNetworkShared
import Testing
@testable import MClashApp

@Suite("Unified flow ledger")
struct FlowLedgerTests {
    private let baseDate = Date(timeIntervalSince1970: 1_784_166_400)

    @Test("Relay source port wins over a closer heuristic candidate")
    func exactRelayPortWins() throws {
        let activity = appActivity(
            relayLocalPort: 55_001,
            startedAt: baseDate,
            upload: 12,
            download: 34
        )
        let exact = try connection(
            id: "exact",
            sourcePort: 55_001,
            start: baseDate.addingTimeInterval(8)
        )
        let closerButWrongPort = try connection(
            id: "closer",
            sourcePort: 55_002,
            start: baseDate.addingTimeInterval(1),
            rule: "WrongRule",
            chains: ["Wrong Node"]
        )

        let ledger = FlowLedger(
            activeConnections: [closerButWrongPort, exact],
            appRoutingActivities: [activity]
        )

        #expect(ledger.entries.count == 2)
        let merged = try #require(ledger.entries.first { $0.id == .appRouting(activity.id) })
        #expect(merged.association == .exactRelayPort(connectionID: "exact"))
        #expect(merged.mihomoRoute?.rule == "DomainSuffix")
        #expect(merged.mihomoRoute?.chain == ["Proxy Group", "Node A"])
        #expect(merged.application.displayName == "ExampleApp")
        #expect(merged.captureOrigin == .appRouting)
        #expect(merged.appRoutingRule == "Example Apps")
        #expect(merged.upload == .exact(12))
        #expect(merged.download == .exact(34))
        #expect(ledger.entries.contains { $0.id == .mihomo("closer") })
        #expect(!ledger.entries.contains { $0.id == .mihomo("exact") })
    }

    @Test("Destination and start time provide a bounded fallback association")
    func heuristicAssociationWithoutRelayPort() throws {
        let activity = appActivity(relayLocalPort: nil, startedAt: baseDate)
        let matching = try connection(
            id: "matching",
            sourcePort: 44_000,
            start: baseDate.addingTimeInterval(3)
        )

        let ledger = FlowLedger(
            activeConnections: [matching],
            appRoutingActivities: [activity]
        )
        let entry = try #require(ledger.entries.first)

        #expect(
            entry.association
                == .destinationAndStartTime(connectionID: "matching")
        )
    }

    @Test("Destination mismatch never consumes an unrelated Mihomo connection")
    func mismatchRemainsSeparate() throws {
        let activity = appActivity(relayLocalPort: 55_001, startedAt: baseDate)
        let unrelated = try connection(
            id: "unrelated",
            host: "different.example",
            destinationIP: "9.9.9.9",
            sourcePort: 55_001,
            start: baseDate
        )

        let ledger = FlowLedger(
            activeConnections: [unrelated],
            appRoutingActivities: [activity]
        )

        #expect(ledger.entries.count == 2)
        #expect(
            ledger.entries.first { $0.id == .appRouting(activity.id) }?.association
                == FlowLedgerAssociation.none
        )
        #expect(ledger.entries.contains { $0.id == .mihomo("unrelated") })
    }

    @Test("Handoff and rejection never masquerade as measured zero bytes")
    func byteMeasurementSemantics() throws {
        let direct = appActivity(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            disposition: .direct,
            relayState: .notApplicable
        )
        let failOpen = appActivity(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            disposition: .failOpen,
            relayState: .notApplicable
        )
        let rejected = appActivity(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            disposition: .reject,
            relayState: .notApplicable
        )
        let proxiedZero = appActivity(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            disposition: .mihomo(.profileRules),
            relayState: .relaying
        )

        let ledger = FlowLedger(
            activeConnections: [],
            appRoutingActivities: [direct, failOpen, rejected, proxiedZero]
        )

        #expect(entry(direct.id, in: ledger).upload == .notMeasuredAfterHandoff)
        #expect(entry(failOpen.id, in: ledger).download == .notMeasuredAfterHandoff)
        #expect(entry(rejected.id, in: ledger).upload == .notApplicable)
        #expect(entry(proxiedZero.id, in: ledger).upload == .exact(0))
        #expect(entry(proxiedZero.id, in: ledger).download == .exact(0))
    }

    @Test("Mihomo traffic without process metadata is retained as Unattributed")
    func unattributedMihomoTrafficIsRetained() throws {
        let connection = try self.connection(
            id: "unattributed",
            inboundName: "Mixed",
            process: nil,
            processPath: nil,
            upload: 123,
            download: 456
        )
        let ledger = FlowLedger(activeConnections: [connection])
        let entry = try #require(ledger.entries.first)

        #expect(entry.application == .unattributed)
        #expect(entry.captureOrigin == .localListener(name: "Mixed"))
        #expect(entry.upload == .exact(123))
        #expect(entry.download == .exact(456))
        #expect(ledger.applicationAggregates.first?.application.key == .unattributed)
        #expect(ledger.applicationAggregates.first?.traffic.exactTotalBytes == 579)
    }

    @Test("Aggregates preserve measured, unmeasured, and inapplicable traffic")
    func aggregatesByApplicationRouteAndOutcome() throws {
        let proxied = appActivity(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            relayLocalPort: 55_011,
            upload: 100,
            download: 900
        )
        let direct = appActivity(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            disposition: .direct,
            relayState: .notApplicable
        )
        let rejected = appActivity(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            disposition: .reject,
            relayState: .notApplicable
        )
        let connection = try self.connection(
            id: "proxied",
            sourcePort: 55_011,
            start: baseDate
        )
        let ledger = FlowLedger(
            activeConnections: [connection],
            appRoutingActivities: [proxied, direct, rejected]
        )

        let application = try #require(
            ledger.applicationAggregates.first {
                $0.application.key == .bundleIdentifier("com.example.app")
            }
        )
        #expect(application.entryCount == 3)
        #expect(application.traffic.exactTotalBytes == 1_000)
        #expect(application.traffic.notMeasuredAfterHandoffCount == 1)
        #expect(application.traffic.notApplicableCount == 1)

        #expect(ledger.routeAggregates.contains { aggregate in
            guard case let .mihomo(rule, payload, chain) = aggregate.route else {
                return false
            }
            return rule == "DomainSuffix"
                && payload == "example.com"
                && chain == ["Proxy Group", "Node A"]
                && aggregate.traffic.exactTotalBytes == 1_000
        })
        #expect(
            ledger.outcomeAggregates.first { $0.outcome == .viaMihomo }?.entryCount
                == 1
        )
        #expect(
            ledger.outcomeAggregates.first { $0.outcome == .direct }?
                .traffic.notMeasuredAfterHandoffCount == 1
        )
        #expect(
            ledger.outcomeAggregates.first { $0.outcome == .rejected }?
                .traffic.notApplicableCount == 1
        )
    }

    @Test("Closed state, end time, and recent limiting are deterministic")
    func recentlyClosedAndRecentEntries() throws {
        let older = try connection(
            id: "older",
            start: baseDate.addingTimeInterval(-100)
        )
        let newer = try connection(
            id: "newer",
            start: baseDate.addingTimeInterval(-20)
        )
        let closedAt = baseDate.addingTimeInterval(-10)
        let ledger = FlowLedger(
            activeConnections: [newer],
            recentlyClosedConnections: [
                FlowLedgerClosedConnection(connection: older, closedAt: closedAt)
            ]
        )

        let closed = try #require(ledger.entries.first { $0.id == .mihomo("older") })
        #expect(closed.state == .completed)
        #expect(closed.endedAt == closedAt)
        #expect(ledger.recentEntries(limit: 1).map(\.id) == [.mihomo("older")])
        #expect(
            ledger.recentEntries(limit: 10, since: baseDate).isEmpty
        )
    }

    private func entry(_ id: UUID, in ledger: FlowLedger) -> FlowLedgerEntry {
        guard let entry = ledger.entries.first(where: { $0.id == .appRouting(id) }) else {
            Issue.record("Missing App Routing ledger entry \(id)")
            fatalError("Missing expected ledger entry")
        }
        return entry
    }

    private func appActivity(
        id: UUID = UUID(),
        disposition: FlowTrafficDisposition = .mihomo(.profileRules),
        relayState: AppRoutingRelayState = .relaying,
        relayLocalPort: UInt16? = 55_001,
        startedAt: Date? = nil,
        upload: UInt64 = 0,
        download: UInt64 = 0
    ) -> AppRoutingActivity {
        let decision = FlowTrafficDecision(
            disposition: disposition,
            reason: .rule(.matchedRule("Example Apps"))
        )
        return AppRoutingActivity(
            flowIdentifier: id,
            configurationRevision: 7,
            startedAt: startedAt ?? baseDate,
            endedAt: relayState == .completed || relayState == .notApplicable
                ? (startedAt ?? baseDate).addingTimeInterval(2)
                : nil,
            source: AppRoutingActivitySource(
                processIdentifier: 42,
                userIdentifier: 501,
                executablePath: "/Applications/Example.app/Contents/MacOS/ExampleApp",
                bundleIdentifier: "com.example.app",
                signingIdentifier: "com.example.app",
                teamIdentifier: "TEAM123"
            ),
            destination: AppRoutingActivityDestination(
                hostname: "example.com",
                ipAddress: "1.1.1.1",
                port: 443
            ),
            transportProtocol: .tcp,
            decision: decision,
            configuredAction: configuredAction(disposition),
            effectiveAction: disposition,
            relayState: relayState,
            relayLocalPort: relayLocalPort,
            uploadBytes: upload,
            downloadBytes: download
        )
    }

    private func configuredAction(_ disposition: FlowTrafficDisposition) -> CaptureAction {
        switch disposition {
        case .direct, .failOpen: .direct
        case .reject: .reject
        case let .mihomo(route): .mihomo(route)
        }
    }

    private func connection(
        id: String,
        host: String = "example.com",
        destinationIP: String = "1.1.1.1",
        destinationPort: UInt16 = 443,
        sourcePort: UInt16 = 55_001,
        inboundName: String = NetworkExtensionMihomoListenerConfiguration.ipv4ListenerName,
        network: String = "tcp",
        process: String? = "mihomo",
        processPath: String? = "/Applications/MClash.app/Contents/MacOS/mihomo",
        start: Date? = nil,
        upload: Int64 = 0,
        download: Int64 = 0,
        rule: String = "DomainSuffix",
        rulePayload: String = "example.com",
        chains: [String] = ["Node A", "Proxy Group"]
    ) throws -> MihomoConnection {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let metadata: [String: Any] = [
            "host": host,
            "destinationIP": destinationIP,
            "destinationPort": String(destinationPort),
            "sourcePort": String(sourcePort),
            "inboundName": inboundName,
            "network": network,
            "process": process ?? NSNull(),
            "processPath": processPath ?? NSNull(),
        ]
        let object: [String: Any] = [
            "id": id,
            "metadata": metadata,
            "upload": upload,
            "download": download,
            "start": formatter.string(from: start ?? baseDate),
            "chains": chains,
            "providerChains": ["provider-a", ""],
            "rule": rule,
            "rulePayload": rulePayload,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MihomoConnection.self, from: data)
    }
}
