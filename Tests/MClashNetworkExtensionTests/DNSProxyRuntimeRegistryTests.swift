import Foundation
import MClashNetworkShared
import Testing
@testable import MClashNetworkExtension

@Suite("DNS runtime registry")
struct DNSProxyRuntimeRegistryTests {
    @Test("A changed bootstrap is delivered to the live updater exactly once")
    func changedBootstrapTriggersLiveUpdater() throws {
        let registry = DNSProxyRuntimeRegistry()
        let first = try bootstrap(
            revision: 30,
            activationIdentifier: UUID(
                uuidString: "11111111-1111-1111-1111-111111111111"
            )!
        )
        let replacement = try bootstrap(
            revision: 31,
            activationIdentifier: UUID(
                uuidString: "22222222-2222-2222-2222-222222222222"
            )!,
            routeProxyEndpoints: [
                try endpoint(route: .profileRules, port: 17_892),
                try endpoint(
                    route: .profile(
                        RoutingProfileID(
                            UUID(
                                uuidString: "33333333-3333-3333-3333-333333333333"
                            )!
                        ),
                        target: .global
                    ),
                    port: 17_893
                ),
            ]
        )
        let recorder = BootstrapUpdateRecorder(result: true)

        #expect(registry.prepare(first))
        let token = registry.registerLiveUpdater { value in
            recorder.apply(value)
        }
        defer { registry.unregisterLiveUpdater(token) }

        #expect(registry.prepare(replacement))
        #expect(registry.prepare(replacement))
        #expect(recorder.values == [replacement])
        #expect(registry.snapshot()?.expectedRevision == 31)
    }

    @Test("A rejected live update makes prepare fail")
    func rejectedLiveUpdateFailsPrepare() throws {
        let registry = DNSProxyRuntimeRegistry()
        let first = try bootstrap(
            revision: 30,
            activationIdentifier: UUID(
                uuidString: "11111111-1111-1111-1111-111111111111"
            )!
        )
        let replacement = try bootstrap(
            revision: 31,
            activationIdentifier: UUID(
                uuidString: "22222222-2222-2222-2222-222222222222"
            )!
        )
        let recorder = BootstrapUpdateRecorder(result: false)

        #expect(registry.prepare(first))
        let token = registry.registerLiveUpdater { value in
            recorder.apply(value)
        }
        defer { registry.unregisterLiveUpdater(token) }

        #expect(!registry.prepare(replacement))
        #expect(recorder.values == [replacement])
    }

    @Test("A rejected live update is not committed as the active bootstrap")
    func rejectedLiveUpdateDoesNotCommitBootstrap() throws {
        let registry = DNSProxyRuntimeRegistry()
        let first = try bootstrap(
            revision: 30,
            activationIdentifier: UUID(
                uuidString: "11111111-1111-1111-1111-111111111111"
            )!
        )
        let replacement = try bootstrap(
            revision: 31,
            activationIdentifier: UUID(
                uuidString: "22222222-2222-2222-2222-222222222222"
            )!
        )
        let recorder = BootstrapUpdateRecorder(result: false)

        #expect(registry.prepare(first))
        let token = registry.registerLiveUpdater { value in
            recorder.apply(value)
        }
        defer { registry.unregisterLiveUpdater(token) }

        #expect(!registry.prepare(replacement))
        #expect(!registry.prepare(replacement))
        #expect(recorder.values == [replacement, replacement])
        #expect(registry.snapshot()?.expectedRevision == first.revision)
        #expect(try registry.resolveBootstrap(delivered: first) == first)
    }

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
        activationIdentifier: UUID,
        routeProxyEndpoints: [MihomoRouteProxyEndpoint]? = nil
    ) throws -> DNSProxyBootstrapConfiguration {
        try DNSProxyBootstrapConfiguration(
            revision: revision,
            activationIdentifier: activationIdentifier,
            profileRulesProxy: endpoint(route: .profileRules, port: 17_891),
            routeProxyEndpoints: routeProxyEndpoints
        )
    }

    private func endpoint(
        route: MihomoRoute,
        port: UInt16
    ) throws -> MihomoRouteProxyEndpoint {
        try MihomoRouteProxyEndpoint(
            route: route,
            host: "127.0.0.1",
            port: port
        )
    }
}

private final class BootstrapUpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let result: Bool
    private var storage: [DNSProxyBootstrapConfiguration] = []

    init(result: Bool) {
        self.result = result
    }

    var values: [DNSProxyBootstrapConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func apply(_ value: DNSProxyBootstrapConfiguration) -> Bool {
        lock.lock()
        storage.append(value)
        lock.unlock()
        return result
    }
}
