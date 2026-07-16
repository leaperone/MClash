import Foundation

/// A stable, presentation-ready explanation of how mihomo routed a connection.
public struct RoutingExplanation: Equatable, Sendable {
    public enum DestinationSource: String, Codable, Equatable, Sendable {
        case host
        case sniffHost
        case destinationIP
        case unknown
    }

    public struct RouteHop: Equatable, Sendable {
        public let name: String
        public let provider: String?

        public init(name: String, provider: String? = nil) {
            self.name = name
            self.provider = provider
        }
    }

    public let destination: String
    public let destinationSource: DestinationSource
    public let rule: String
    public let rulePayload: String
    public let chains: [String]
    public let providerChains: [String]
    public let routeHops: [RouteHop]
    public let upload: Int64
    public let download: Int64

    public init(connection: MihomoConnection) {
        if let host = Self.nonEmpty(connection.metadata.host) {
            destination = host
            destinationSource = .host
        } else if let sniffHost = Self.nonEmpty(connection.metadata.sniffHost) {
            destination = sniffHost
            destinationSource = .sniffHost
        } else if let destinationIP = Self.nonEmpty(connection.metadata.destinationIP) {
            destination = destinationIP
            destinationSource = .destinationIP
        } else {
            destination = "Unknown destination"
            destinationSource = .unknown
        }

        rule = connection.rule
        rulePayload = connection.rulePayload
        upload = connection.upload
        download = connection.download

        let leafToRootHops: [RouteHop] = connection.chains.enumerated().compactMap { element in
            let (index, value) = element
            guard let name = Self.nonEmpty(value) else { return nil }
            let provider = connection.providerChains.indices.contains(index)
                ? Self.nonEmpty(connection.providerChains[index])
                : nil
            return RouteHop(name: name, provider: provider)
        }

        routeHops = leafToRootHops.reversed()
        chains = routeHops.map(\.name)
        providerChains = connection.providerChains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reversed()
    }

    public init(_ connection: MihomoConnection) {
        self.init(connection: connection)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
