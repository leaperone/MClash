import Foundation
import Testing
@testable import MClashApp

@Suite("Traffic routing attribution")
struct TrafficRoutingTests {
    @Test
    func destinationUsesHostSniffHostIPAddressThenFallback() throws {
        let host = RoutingExplanation(
            try connection(host: " example.com ", sniffHost: "sniff.test", destinationIP: "1.1.1.1")
        )
        let sniff = RoutingExplanation(
            try connection(host: "  ", sniffHost: " sniff.test ", destinationIP: "1.1.1.1")
        )
        let ip = RoutingExplanation(
            try connection(host: nil, sniffHost: "\n", destinationIP: " 1.1.1.1 ")
        )
        let unknown = RoutingExplanation(
            try connection(host: nil, sniffHost: nil, destinationIP: " ")
        )

        #expect(host.destination == "example.com")
        #expect(host.destinationSource == .host)
        #expect(sniff.destination == "sniff.test")
        #expect(sniff.destinationSource == .sniffHost)
        #expect(ip.destination == "1.1.1.1")
        #expect(ip.destinationSource == .destinationIP)
        #expect(unknown.destination == "Unknown destination")
        #expect(unknown.destinationSource == .unknown)
    }

    @Test
    func explanationReversesLeafFirstRouteAndPreservesMetadata() throws {
        let explanation = RoutingExplanation(
            try connection(
                upload: 120,
                download: 340,
                chains: [" Node A ", "Auto"],
                providerChains: [" provider-a ", ""],
                rule: "DomainSuffix",
                rulePayload: "example.com"
            )
        )

        #expect(explanation.chains == ["Auto", "Node A"])
        #expect(explanation.providerChains == ["", "provider-a"])
        #expect(
            explanation.routeHops == [
                .init(name: "Auto"),
                .init(name: "Node A", provider: "provider-a")
            ]
        )
        #expect(explanation.rule == "DomainSuffix")
        #expect(explanation.rulePayload == "example.com")
        #expect(explanation.upload == 120)
        #expect(explanation.download == 340)
    }

    @Test
    func firstFrameAndNewConnectionsOnlyEstablishBaselines() throws {
        var attribution = TrafficAttribution()
        let first = try connection(id: "a", upload: 100, download: 200)
        let newConnection = try connection(id: "b", upload: 900, download: 800)

        #expect(attribution.ingest(connections: [first]).isEmpty)
        #expect(attribution.ingest(connections: [first, newConnection]).isEmpty)
        #expect(attribution.entries.isEmpty)
    }

    @Test
    func subsequentFramesAttributeIndependentConnectionDeltas() throws {
        var attribution = TrafficAttribution()
        attribution.ingest(connections: [
            try connection(id: "a", upload: 10, download: 20),
            try connection(id: "b", upload: 100, download: 200)
        ])

        let additions = attribution.ingest(connections: [
            try connection(id: "a", upload: 13, download: 28),
            try connection(id: "b", upload: 111, download: 205)
        ])

        #expect(additions.map(\.connectionID) == ["a", "b"])
        #expect(additions.map(\.uploadDelta) == [3, 11])
        #expect(additions.map(\.downloadDelta) == [8, 5])
    }

    @Test
    func disappearedConnectionReappearsWithANewBaseline() throws {
        var attribution = TrafficAttribution()
        attribution.ingest(connections: [try connection(id: "a", upload: 10)])
        attribution.ingest(connections: [])

        #expect(
            attribution.ingest(connections: [try connection(id: "a", upload: 100)]).isEmpty
        )
        let additions = attribution.ingest(
            connections: [try connection(id: "a", upload: 105)]
        )
        #expect(additions.map(\.uploadDelta) == [5])
    }

    @Test
    func resettingEitherCounterDoesNotCreateFalseTraffic() throws {
        var attribution = TrafficAttribution()
        attribution.ingest(
            connections: [try connection(upload: 100, download: 100)]
        )

        let uploadReset = attribution.ingest(
            connections: [try connection(upload: 10, download: 110)]
        )
        let downloadReset = attribution.ingest(
            connections: [try connection(upload: 15, download: 5)]
        )

        #expect(uploadReset.first?.uploadDelta == 0)
        #expect(uploadReset.first?.downloadDelta == 10)
        #expect(downloadReset.first?.uploadDelta == 5)
        #expect(downloadReset.first?.downloadDelta == 0)
    }

    @Test
    func generationChangeClearsHistoryAndBaselines() throws {
        var attribution = TrafficAttribution()
        attribution.ingest(
            connections: [try connection(upload: 10)],
            generation: 1
        )
        attribution.ingest(
            connections: [try connection(upload: 15)],
            generation: 1
        )
        #expect(attribution.entries.count == 1)

        let firstNewGeneration = attribution.ingest(
            connections: [try connection(upload: 1_000)],
            generation: 2
        )
        #expect(firstNewGeneration.isEmpty)
        #expect(attribution.entries.isEmpty)

        let next = attribution.ingest(
            connections: [try connection(upload: 1_004)],
            generation: 2
        )
        #expect(next.first?.uploadDelta == 4)
    }

    @Test
    func timeWindowPrunesOldEntriesEvenWhenNoTrafficArrives() throws {
        var attribution = TrafficAttribution(window: 10)
        let start = Date(timeIntervalSince1970: 1_000)
        attribution.ingest(
            connections: [try connection(upload: 0)],
            at: start
        )
        attribution.ingest(
            connections: [try connection(upload: 1)],
            at: start.addingTimeInterval(1)
        )
        #expect(attribution.entries.count == 1)

        attribution.ingest(
            connections: [try connection(upload: 1)],
            at: start.addingTimeInterval(12)
        )
        #expect(attribution.entries.isEmpty)
    }

    @Test
    func entryLimitKeepsOnlyMostRecentAttributions() throws {
        var attribution = TrafficAttribution(maxEntries: 2)
        attribution.ingest(connections: [try connection(upload: 0)])
        attribution.ingest(connections: [try connection(upload: 1)])
        attribution.ingest(connections: [try connection(upload: 3)])
        attribution.ingest(connections: [try connection(upload: 6)])

        #expect(attribution.entries.map(\.uploadDelta) == [2, 3])
    }

    @Test
    func zeroDeltaDoesNotCreateAnEntryAndCurrentRoutingIsCaptured() throws {
        var attribution = TrafficAttribution()
        attribution.ingest(
            connections: [try connection(upload: 10, chains: ["Old node"])]
        )
        #expect(
            attribution.ingest(
                connections: [try connection(upload: 10, chains: ["Unused node"])]
            ).isEmpty
        )

        let additions = attribution.ingest(
            connections: [try connection(upload: 12, chains: ["Current node"])]
        )
        #expect(additions.first?.routing.chains == ["Current node"])
    }

    @Test
    func negativeCountersAndDuplicateIDsAreHandledDefensively() throws {
        var attribution = TrafficAttribution()
        attribution.ingest(connections: [try connection(upload: -10, download: -20)])
        let normalized = attribution.ingest(
            connections: [try connection(upload: 5, download: 7)]
        )
        #expect(normalized.first?.uploadDelta == 5)
        #expect(normalized.first?.downloadDelta == 7)

        let duplicate = attribution.ingest(connections: [
            try connection(upload: 6, download: 8),
            try connection(upload: 9, download: 11)
        ])
        #expect(duplicate.count == 1)
        #expect(duplicate.first?.uploadDelta == 4)
        #expect(duplicate.first?.downloadDelta == 4)
    }

    private func connection(
        id: String = "connection-1",
        host: String? = "example.com",
        sniffHost: String? = nil,
        destinationIP: String? = "1.1.1.1",
        upload: Int64 = 0,
        download: Int64 = 0,
        chains: [String] = [],
        providerChains: [String] = [],
        rule: String = "MATCH",
        rulePayload: String = ""
    ) throws -> MihomoConnection {
        let metadata: [String: Any] = [
            "host": host ?? NSNull(),
            "sniffHost": sniffHost ?? NSNull(),
            "destinationIP": destinationIP ?? NSNull()
        ]
        let object: [String: Any] = [
            "id": id,
            "metadata": metadata,
            "upload": upload,
            "download": download,
            "start": "2026-07-16T08:00:00+08:00",
            "chains": chains,
            "providerChains": providerChains,
            "rule": rule,
            "rulePayload": rulePayload
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MihomoConnection.self, from: data)
    }
}
