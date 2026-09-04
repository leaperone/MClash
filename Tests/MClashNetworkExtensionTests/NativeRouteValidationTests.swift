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

    @Test("Native catalog remains authoritative alongside a legacy catalog")
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
        let coordinator = NetworkExtensionFlowDecisionCoordinator()
        #expect(coordinator.validates(configuration: configuration))
        coordinator.load(configuration: configuration)
        #expect(coordinator.outboundNodeTarget(for: .profileRules) == unsupported)
    }

    @Test("Native flow normalization terminates Direct, Reject, and unavailable routes")
    func nativeFlowNormalizationFailsClosed() throws {
        let direct = FlowTrafficDecision(
            disposition: .direct,
            reason: .rule(.defaultDirect)
        )
        let reject = FlowTrafficDecision(
            disposition: .reject,
            reason: .rule(.defaultDirect)
        )
        let outbound = FlowTrafficDecision(
            disposition: .outbound(.profileRules),
            reason: .rule(.matchedRule("native-route"))
        )
        let supported = try OutboundNodeTarget(
            protocolName: "vless",
            host: "node.example.com",
            port: 443,
            parameters: ["uuid": "00000000-0000-0000-0000-000000000001"]
        )
        let unsupported = try OutboundNodeTarget(
            protocolName: "quic",
            host: "node.example.com",
            port: 443
        )

        #expect(NetworkExtensionFlowDecisionCoordinator.normalizedNativeDecision(
            direct, target: nil, transportProtocol: .tcp
        ) == direct)
        #expect(NetworkExtensionFlowDecisionCoordinator.normalizedNativeDecision(
            reject, target: nil, transportProtocol: .tcp
        ) == reject)
        #expect(NetworkExtensionFlowDecisionCoordinator.normalizedNativeDecision(
            outbound, target: supported, transportProtocol: .tcp
        ) == outbound)

        for target in [nil, unsupported] as [OutboundNodeTarget?] {
            let normalized = NetworkExtensionFlowDecisionCoordinator.normalizedNativeDecision(
                outbound,
                target: target,
                transportProtocol: .tcp
            )
            #expect(normalized.disposition == .reject)
            #expect(normalized.reason == .outboundUnavailable(
                rule: .matchedRule("native-route"),
                fallback: .reject
            ))
        }
    }

    @Test("An explicit native backend cannot be rescued by legacy fields")
    func explicitNativeBackendRequiresNativeCatalog() throws {
        let snapshot = try CaptureConfigurationSnapshot(revision: 3, rules: [])
        let legacy = try JSONEncoder().encode([
            try MihomoRouteProxyEndpoint(
                route: .profileRules,
                host: "127.0.0.1",
                port: 18080
            )
        ])
        let base: [String: Any] = [
            ProviderConfigurationKey.captureEnabled: true,
            ProviderConfigurationKey.captureBackend: NetworkCaptureBackend.native.rawValue,
            ProviderConfigurationKey.captureConfigurationSnapshot: try JSONEncoder().encode(snapshot),
            ProviderConfigurationKey.mihomoRouteProxyCatalog: legacy,
        ]

        #expect(!NetworkExtensionFlowDecisionCoordinator().validates(configuration: base))
        var malformed = base
        malformed[ProviderConfigurationKey.outboundNodeTargetCatalog] = Data("not-json".utf8)
        #expect(!NetworkExtensionFlowDecisionCoordinator().validates(configuration: malformed))
    }
}
