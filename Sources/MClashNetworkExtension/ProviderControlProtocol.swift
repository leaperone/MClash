import Foundation
import MClashNetworkShared

/// Versioned messages exchanged between the host app and the transparent
/// provider through `NETunnelProviderSession.sendProviderMessage`.
///
/// The DNS provider cannot receive provider messages. Its initial revision is
/// supplied through `NEDNSProxyProviderProtocol.providerConfiguration` instead.
enum ProviderControlCommand: String, Codable, Sendable {
    case status
    case applyConfiguration
    case quiesce
    case activity
    case clearActivity
}

struct ProviderControlRequest: Codable, Sendable {
    static let currentProtocolVersion = 2

    let protocolVersion: Int
    let command: ProviderControlCommand
    let revision: UInt64?
    let captureEnabled: Bool?
    let failOpen: Bool?
    let captureConfigurationSnapshot: Data?
    let mihomoRouteProxyCatalog: Data?
    let mihomoSOCKSHost: String?
    let mihomoSOCKSPort: UInt16?
    let mihomoSOCKSUsername: String?
    let mihomoSOCKSPassword: String?
    let activityCursor: UInt64?
    let activityLimit: Int?
}

struct ProviderControlResponse: Codable, Sendable {
    let protocolVersion: Int
    let accepted: Bool
    let provider: String
    let revision: UInt64
    let running: Bool
    let captureEnabled: Bool
    let failOpen: Bool
    let message: String?
    let activityBatch: AppRoutingActivityBatch?
}

enum ProviderConfigurationKey {
    static let revision = "revision"
    static let captureEnabled = "captureEnabled"
    static let failOpen = "failOpen"
    static let activationIdentifier = "activationIdentifier"
    /// JSON-encoded `CaptureConfigurationSnapshot` stored as `Data`/`NSData`.
    static let captureConfigurationSnapshot = "captureConfigurationSnapshot"
    /// JSON-encoded `[MihomoRouteProxyEndpoint]` stored as `Data`/`NSData`.
    static let mihomoRouteProxyCatalog = "mihomoRouteProxyCatalog"
    static let mihomoSOCKSHost = "mihomoSOCKSHost"
    static let mihomoSOCKSPort = "mihomoSOCKSPort"
    static let mihomoSOCKSUsername = "mihomoSOCKSUsername"
    static let mihomoSOCKSPassword = "mihomoSOCKSPassword"
}

enum ProviderControlCodec {
    static func decode(_ data: Data) throws -> ProviderControlRequest {
        try JSONDecoder().decode(ProviderControlRequest.self, from: data)
    }

    static func encode(_ response: ProviderControlResponse) -> Data? {
        try? JSONEncoder().encode(response)
    }
}
