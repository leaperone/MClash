import Foundation
import MClashNetworkShared
import Testing
@testable import MClashNetworkExtension

@Suite("Native route bootstrap")
struct NativeRouteValidationTests {
    @Test("A node-only bootstrap does not require a Mihomo SOCKS catalog")
    func nodeOnlyBootstrapIsAccepted() throws {
        let snapshot = try CaptureConfigurationSnapshot(revision: 1, rules: [])
        let target = try OutboundNodeTarget(
            protocolName: "vless",
            host: "node.example.com",
            port: 443,
            parameters: ["uuid": "00000000-0000-0000-0000-000000000001"]
        )
        let route = OutboundRoute.profileRules
        let catalog = try OutboundNodeTargetCatalog(
            entries: [OutboundNodeTargetEntry(route: route, target: target)]
        )
        let configuration: [String: Any] = [
            ProviderConfigurationKey.captureEnabled: true,
            ProviderConfigurationKey.captureConfigurationSnapshot:
                try JSONEncoder().encode(snapshot),
            ProviderConfigurationKey.outboundNodeTargetCatalog:
                try catalog.encoded()
        ]

        #expect(NetworkExtensionFlowDecisionCoordinator().validates(configuration: configuration))
        #expect(ProviderSOCKSConfiguration.routeCatalog(providerConfiguration: configuration) == nil)
    }

    @Test("A node-only bootstrap accepts unsupported targets for flow-level fail-closed")
    func unsupportedNodeOnlyBootstrapIsRejected() throws {
        let snapshot = try CaptureConfigurationSnapshot(revision: 1, rules: [])
        let target = try OutboundNodeTarget(
            protocolName: "quic",
            host: "node.example.com",
            port: 443
        )
        let catalog = try OutboundNodeTargetCatalog(
            entries: [OutboundNodeTargetEntry(route: .profileRules, target: target)]
        )
        let configuration: [String: Any] = [
            ProviderConfigurationKey.captureEnabled: true,
            ProviderConfigurationKey.captureConfigurationSnapshot:
                try JSONEncoder().encode(snapshot),
            ProviderConfigurationKey.outboundNodeTargetCatalog:
                try catalog.encoded()
        ]

        #expect(NetworkExtensionFlowDecisionCoordinator().validates(configuration: configuration))
    }

    @Test("Native catalog remains authoritative over a legacy Mihomo rescue")
    func nativeCatalogCannotBeRescuedByLegacyRoute() throws {
        let snapshot = try CaptureConfigurationSnapshot(revision: 2, rules: [])
        let unsupported = try OutboundNodeTarget(protocolName: "quic", host: "node.example.com", port: 443)
        let native = try OutboundNodeTargetCatalog(entries: [
            OutboundNodeTargetEntry(route: .profileRules, target: unsupported)
        ])
        let legacy = try JSONEncoder().encode([
            try MihomoRouteProxyEndpoint(route: .profileRules, host: "127.0.0.1", port: 18080)
        ])
        let configuration: [String: Any] = [
            ProviderConfigurationKey.captureEnabled: true,
            ProviderConfigurationKey.captureConfigurationSnapshot: try JSONEncoder().encode(snapshot),
            ProviderConfigurationKey.outboundNodeTargetCatalog: try native.encoded(),
            ProviderConfigurationKey.mihomoRouteProxyCatalog: legacy
        ]
        #expect(!NetworkExtensionFlowDecisionCoordinator().validates(configuration: configuration))
    }
}
