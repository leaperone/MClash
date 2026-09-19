import Foundation
import Testing
@testable import MClashApp

@Suite("Automation group health checks")
struct ConfigurationAutomationHealthCheckTests {
    @Test func presentationAndRoundTripPreserveCustomSettings() throws {
        let group = ProxyGroup(name: "Auto", type: .urlTest, healthCheck: {
            var value = ProxyGroupPolicySettings()
            value.testURL = URL(string: "http://127.0.0.1:8080/health")!
            value.expectedStatus = "200"
            value.probeInterval = 12.5
            value.failureThreshold = 4
            return value
        }())
        let dto = ConfigurationAutomationProxyGroup(group)
        let data = try JSONEncoder().encode(dto)
        let decoded = try JSONDecoder().decode(ConfigurationAutomationProxyGroup.self, from: data)
        let applied = try decoded.applying(to: group)
        #expect(applied.healthCheck?.testURL == group.healthCheck?.testURL)
        #expect(applied.healthCheck?.expectedStatus == "200")
        #expect(applied.healthCheck?.probeInterval == 12.5)
        #expect(applied.healthCheck?.failureThreshold == 4)
        var rename = decoded
        rename.healthCheck = nil
        rename.name = "Renamed group"
        #expect(try rename.applying(to: group).healthCheck == group.healthCheck)
    }

    @Test func invalidExplicitSettingsAreRejected() throws {
        let group = ProxyGroup(name: "Auto", type: .fallback)
        var dto = ConfigurationAutomationProxyGroup(group)
        var health = ProxyGroupPolicySettings()
        health.probeTimeout = 0
        dto.healthCheck = health
        #expect(throws: ConfigurationAutomationError.self) { try dto.applying(to: group) }
    }
}
