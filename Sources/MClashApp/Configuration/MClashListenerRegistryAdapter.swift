import Foundation
import MClashNetworkShared

/// Projects the persisted configuration entrances into the native listener
/// vocabulary. This adapter is deliberately one-way: imported profiles never
/// supply listener settings, and the legacy Mihomo composer remains free to
/// consume the original `Entrance` values during migration.
public enum MClashListenerRegistryAdapter {
    public static func registry(from entrances: [Entrance]) throws -> MClashListenerRegistry {
        let specs = try entrances.map { entrance in
            try MClashListenerSpec(
                id: entrance.id.rawValue,
                name: entrance.name,
                kind: MClashListenerKind(rawValue: entrance.kind.rawValue) ?? .http,
                enabled: entrance.enabled,
                bindAddress: entrance.kind == .appRouting || entrance.kind == .tun
                    ? "127.0.0.1" : entrance.bindAddress,
                port: entrance.kind == .appRouting || entrance.kind == .tun
                    ? nil : entrance.port,
                route: route(for: entrance.defaultAction)
            )
        }
        return try MClashListenerRegistry(listeners: specs)
    }

    private static func route(for action: RoutingAction) -> MClashListenerRoute {
        switch action {
        case .direct: .direct
        case .reject: .reject
        case let .proxyGroup(groupID): .outbound(.group(groupID.rawValue.uuidString))
        }
    }
}
