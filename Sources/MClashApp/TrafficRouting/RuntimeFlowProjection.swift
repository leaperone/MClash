import Foundation
import MClashNetworkShared

/// The route MClash configured for a flow, kept separate from what a runtime
/// can currently observe.
public struct ConfiguredRoutePath: Codable, Equatable, Sendable {
    public let entrance: String?
    public let mode: String?
    public let ruleIdentifier: String?
    public let group: String?
    public let node: String?

    public init(
        entrance: String? = nil,
        mode: String? = nil,
        ruleIdentifier: String? = nil,
        group: String? = nil,
        node: String? = nil
    ) {
        self.entrance = entrance
        self.mode = mode
        self.ruleIdentifier = ruleIdentifier
        self.group = group
        self.node = node
    }
}

public enum RuntimeFlowEvidence: String, Codable, Equatable, Sendable {
    case configuredOnly
    case appRoutingObserved
    case xrayAggregateOnly
}

/// A bounded presentation record. Optional observed fields remain absent when
/// the backend has aggregate telemetry but no per-flow inspection.
public struct RuntimeFlowProjection: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let configuredPath: ConfiguredRoutePath
    public let observedBackend: ProxyRuntimeBackend?
    public let evidence: RuntimeFlowEvidence
    public let startedAt: Date
    public let endedAt: Date?
    public let source: AppRoutingActivitySource?
    public let destination: AppRoutingActivityDestination?
    public let transportProtocol: TransportProtocol?
    public let uploadBytes: UInt64?
    public let downloadBytes: UInt64?

    public init(
        id: UUID,
        configuredPath: ConfiguredRoutePath,
        observedBackend: ProxyRuntimeBackend?,
        evidence: RuntimeFlowEvidence,
        startedAt: Date,
        endedAt: Date? = nil,
        source: AppRoutingActivitySource? = nil,
        destination: AppRoutingActivityDestination? = nil,
        transportProtocol: TransportProtocol? = nil,
        uploadBytes: UInt64? = nil,
        downloadBytes: UInt64? = nil
    ) {
        self.id = id
        self.configuredPath = configuredPath
        self.observedBackend = observedBackend
        self.evidence = evidence
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.source = source
        self.destination = destination
        self.transportProtocol = transportProtocol
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
    }

    public static func appRouting(
        _ activity: AppRoutingActivity,
        configuredPath: ConfiguredRoutePath = ConfiguredRoutePath()
    ) -> Self {
        Self(
            id: activity.flowIdentifier,
            configuredPath: configuredPath,
            observedBackend: activity.effectiveAction.backend,
            evidence: .appRoutingObserved,
            startedAt: activity.startedAt,
            endedAt: activity.endedAt,
            source: activity.source,
            destination: activity.destination,
            transportProtocol: activity.transportProtocol,
            uploadBytes: activity.payloadBytesAreMeasured == true ? activity.uploadBytes : nil,
            downloadBytes: activity.payloadBytesAreMeasured == true ? activity.downloadBytes : nil
        )
    }

    public static func xrayAggregate(
        uploadBytes: Int64,
        downloadBytes: Int64,
        sampledAt: Date,
        configuredPath: ConfiguredRoutePath = ConfiguredRoutePath()
    ) -> Self {
        Self(
            id: UUID(),
            configuredPath: configuredPath,
            observedBackend: .xray,
            evidence: .xrayAggregateOnly,
            startedAt: sampledAt,
            uploadBytes: UInt64(clamping: uploadBytes),
            downloadBytes: UInt64(clamping: downloadBytes)
        )
    }
}

private extension FlowTrafficDisposition {
    var backend: ProxyRuntimeBackend? {
        switch self {
        case .mihomo: .mihomoCompatibility
        case .direct, .reject, .failOpen: nil
        }
    }
}
