import Foundation
import MClashNetworkShared

/// Compatibility boundary for the existing Mihomo connection API. New
/// connectors should emit `FlowRelayObservation` directly instead of adding
/// more Mihomo-shaped fields to the ledger.
enum MihomoFlowObservationAdapter {
    static func observation(
        for connection: MihomoConnection,
        state: FlowRelayObservation.State = .active,
        endedAt: Date? = nil
    ) -> FlowRelayObservation {
        let metadata = connection.metadata
        let route: FlowRelayObservation.Route
        if connection.chains.isEmpty {
            route = .unknown
        } else {
            route = .relay
        }
        let connector = connection.chains.last
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return FlowRelayObservation(
            id: connection.id,
            startedAt: RuntimeTimestampParser.date(from: connection.start),
            endedAt: endedAt,
            network: metadata.network,
            destinationHost: metadata.host ?? metadata.sniffHost,
            destinationIP: metadata.destinationIP,
            destinationPort: metadata.destinationPort.flatMap(UInt16.init),
            process: metadata.process,
            processPath: metadata.processPath,
            inboundName: metadata.inboundName,
            rule: connection.rule,
            rulePayload: connection.rulePayload,
            routeChain: connection.chains,
            providerChain: connection.providerChains,
            connector: connector,
            uploadBytes: UInt64(max(0, connection.upload)),
            downloadBytes: UInt64(max(0, connection.download)),
            state: state,
            route: route
        )
    }

    static func observations(
        from connections: [MihomoConnection]
    ) -> [FlowRelayObservation] {
        connections.map { observation(for: $0) }
    }
}
