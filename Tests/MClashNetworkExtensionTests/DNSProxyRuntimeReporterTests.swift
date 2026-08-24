import Foundation
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
