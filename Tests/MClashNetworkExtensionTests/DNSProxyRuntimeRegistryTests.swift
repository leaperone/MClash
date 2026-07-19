import Foundation
import MClashNetworkShared
import Testing
@testable import MClashNetworkExtension

@Suite("DNS runtime registry")
struct DNSProxyRuntimeRegistryTests {
    @Test("Re-preparing the active bootstrap preserves its heartbeat")
    func repeatedPrepareIsIdempotent() throws {
        let registry = DNSProxyRuntimeRegistry()
        let firstActivation = UUID(
            uuidString: "11111111-1111-1111-1111-111111111111"
        )!
        let first = try bootstrap(
            revision: 30,
            activationIdentifier: firstActivation
        )
        let now = Date(timeIntervalSince1970: 3_000)
        let status = DNSProxyRuntimeStatus(
            revision: 30,
            activationIdentifier: firstActivation,
            phase: .running,
            backendReady: true,
            startedAt: now,
            updatedAt: now,
            lastBackendAssociationAt: now
        )

        #expect(registry.prepare(first))
        try registry.publish(status)
        #expect(registry.prepare(first))
        #expect(registry.snapshot()?.status == status)

        let replacement = try bootstrap(
            revision: 31,
            activationIdentifier: UUID(
                uuidString: "22222222-2222-2222-2222-222222222222"
            )!
        )
        #expect(registry.prepare(replacement))
        let report = try #require(registry.snapshot())
        #expect(report.expectedRevision == 31)
        #expect(report.status == nil)
    }

    private func bootstrap(
        revision: UInt64,
        activationIdentifier: UUID
    ) throws -> DNSProxyBootstrapConfiguration {
        try DNSProxyBootstrapConfiguration(
            revision: revision,
            activationIdentifier: activationIdentifier,
            profileRulesProxy: MihomoRouteProxyEndpoint(
                route: .profileRules,
                host: "127.0.0.1",
                port: 17_891
            )
        )
    }
}
