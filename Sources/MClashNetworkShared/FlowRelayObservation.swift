import Foundation

/// The connector-neutral record emitted by an inbound flow or an outbound
/// relay.  This is deliberately independent of Mihomo's API vocabulary so a
/// native connector can feed the traffic ledger without manufacturing a
/// loopback connection record.
public struct FlowRelayObservation: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case active
        case completed
        case rejected
        case failed
    }

    public enum Route: String, Codable, Sendable {
        case direct
        case relay
        case rejected
        case failOpen
        case unknown
    }

    public let id: String
    public let startedAt: Date?
    public let endedAt: Date?
    public let network: String?
    public let destinationHost: String?
    public let destinationIP: String?
    public let destinationPort: UInt16?
    public let process: String?
    public let processPath: String?
    public let inboundName: String?
    public let rule: String?
    public let rulePayload: String?
    public let routeChain: [String]
    public let providerChain: [String]
    public let connector: String?
    public let uploadBytes: UInt64
    public let downloadBytes: UInt64
    public let state: State
    public let route: Route
    public let failureReason: String?

    public init(
        id: String,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        network: String? = nil,
        destinationHost: String? = nil,
        destinationIP: String? = nil,
        destinationPort: UInt16? = nil,
        process: String? = nil,
        processPath: String? = nil,
        inboundName: String? = nil,
        rule: String? = nil,
        rulePayload: String? = nil,
        routeChain: [String] = [],
        providerChain: [String] = [],
        connector: String? = nil,
        uploadBytes: UInt64 = 0,
        downloadBytes: UInt64 = 0,
        state: State = .active,
        route: Route = .unknown,
        failureReason: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.network = network
        self.destinationHost = destinationHost
        self.destinationIP = destinationIP
        self.destinationPort = destinationPort
        self.process = process
        self.processPath = processPath
        self.inboundName = inboundName
        self.rule = rule
        self.rulePayload = rulePayload
        self.routeChain = routeChain
        self.providerChain = providerChain
        self.connector = connector
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
        self.state = state
        self.route = route
        self.failureReason = failureReason.map { String($0.prefix(256)) }
    }
}

/// A future native flow implementation can publish observations without
/// knowing how the app stores or presents them.
public protocol FlowRelayObservationSink: Sendable {
    func receive(_ observation: FlowRelayObservation)
}
