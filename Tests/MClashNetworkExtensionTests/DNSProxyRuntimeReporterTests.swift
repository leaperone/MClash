import Foundation
import MClashNetworkShared
import Testing
@testable import MClashNetworkExtension

@Suite("DNS runtime reporter")
struct DNSProxyRuntimeReporterTests {
    @Test("Resuming heartbeat immediately refreshes a stale status")
    func resumeHeartbeatRefreshesImmediately() throws {
        let registry = DNSProxyRuntimeRegistry()
        let staleDate = Date(timeIntervalSince1970: 1)
        let reporter = try DNSProxyRuntimeReporter(
            revision: 1,
            activationIdentifier: UUID(),
            now: staleDate,
            registry: registry
        )
        reporter.resumeHeartbeat()
        defer { reporter.stop() }

        let status = try #require(registry.snapshot()?.status)
        #expect(status.updatedAt > staleDate)
        #expect(status.isFresh(at: Date()))

        reporter.pauseHeartbeat()
        reporter.pauseHeartbeat()
        reporter.resumeHeartbeat()
    }
}

@Suite("DNS backend probe")
struct MihomoUDPAssociationProbeTests {
    @Test("Cancellation before start remains effective")
    func cancellationBeforeStartIsSticky() async throws {
        let endpoint = try MihomoRouteProxyEndpoint(
            route: .profileRules,
            host: "127.0.0.1",
            port: 1
        )
        let proxy = try #require(ProviderSOCKSConfiguration(routeEndpoint: endpoint))
        let probe = MihomoUDPAssociationProbe()

        probe.cancel()
        let error: Error? = await withCheckedContinuation { continuation in
            probe.start(proxy: proxy) { error in
                continuation.resume(returning: error)
            }
        }

        guard let error = error as? UDPFlowSessionError,
              case .cancelled = error else {
            Issue.record("Expected a cancelled probe, received \(String(describing: error))")
            return
        }
    }
}
