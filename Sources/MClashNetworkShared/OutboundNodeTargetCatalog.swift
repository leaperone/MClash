import Foundation

/// Connector-neutral mapping from a selected outbound route to node material.
/// It is intentionally separate from listener endpoints: a node target is the
/// remote protocol connection, not a local Mihomo SOCKS port.
public struct OutboundNodeTargetEntry: Codable, Equatable, Sendable {
    public let route: OutboundRoute
    public let target: OutboundNodeTarget

    public init(route: OutboundRoute, target: OutboundNodeTarget) {
        self.route = route
        self.target = target
    }
}

public enum OutboundNodeTargetCatalogError: Error, Equatable, Sendable {
    case empty
    case duplicateRoute
    case oversized
}

public struct OutboundNodeTargetCatalog: Codable, Equatable, Sendable {
    public static let maximumEntries = 512
    public static let maximumEncodedBytes = 256 * 1_024

    public let entries: [OutboundNodeTargetEntry]

    public init(entries: [OutboundNodeTargetEntry]) throws {
        guard !entries.isEmpty else { throw OutboundNodeTargetCatalogError.empty }
        guard entries.count <= Self.maximumEntries else {
            throw OutboundNodeTargetCatalogError.oversized
        }
        var routes = Set<OutboundRoute>()
        guard entries.allSatisfy({ routes.insert($0.route).inserted }) else {
            throw OutboundNodeTargetCatalogError.duplicateRoute
        }
        self.entries = entries
    }

    public func target(for route: OutboundRoute) -> OutboundNodeTarget? {
        entries.first(where: { $0.route == route })?.target
    }

    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumEncodedBytes else {
            throw OutboundNodeTargetCatalogError.oversized
        }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else {
            throw OutboundNodeTargetCatalogError.oversized
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
