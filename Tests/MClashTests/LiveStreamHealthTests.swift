import Foundation
import Testing
@testable import MClashApp

@Suite("Live stream freshness")
struct LiveStreamHealthTests {
    @Test("A silent live stream becomes stale without discarding its last sample")
    func silentStreamBecomesStale() {
        let sampleTime = Date(timeIntervalSince1970: 100)
        let staleTime = Date(timeIntervalSince1970: 110)
        var health = LiveStreamHealth.connecting()
        health.received(at: sampleTime)

        health.becameStale(reason: "No update arrived before the deadline.", at: staleTime)

        #expect(health.phase == .stale)
        #expect(health.lastReceivedAt == sampleTime)
        #expect(health.lastFailureAt == staleTime)
        #expect(health.lastError == "No update arrived before the deadline.")
        #expect(!health.hasCurrentData)
    }

    @Test("Inactive streams are not mislabeled stale by the watchdog")
    func inactiveStreamRemainsInactive() {
        let date = Date(timeIntervalSince1970: 200)
        var health = LiveStreamHealth.inactive

        health.becameStale(reason: "No update arrived before the deadline.", at: date)

        #expect(health == .inactive)
    }
}
