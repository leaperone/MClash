import Foundation
import MClashNetworkShared
import Testing

@Suite("App Routing activity telemetry")
struct AppRoutingActivityTests {
    @Test("Activity is Codable, Hashable, and omits sensitive process material")
    func activityRoundTripAndPrivacyBoundary() throws {
        var activity = makeActivity(
            flowIdentifier: UUID(uuidString: "D54CF072-2153-4CD8-BB79-B467628B66FA")!,
            ruleIdentifier: "Browser Proxy"
        )
        activity.relayState = .relaying
        activity.relayLocalPort = 51_234
        activity.uploadBytes = 123
        activity.downloadBytes = 456

        let data = try JSONEncoder().encode(activity)
        let decoded = try JSONDecoder().decode(AppRoutingActivity.self, from: data)
        #expect(decoded == activity)
        #expect(Set([activity, decoded]).count == 1)
        #expect(decoded.matchedRuleIdentifier == "Browser Proxy")
        #expect(decoded.cause == activity.decision.reason)

        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("auditToken"))
        #expect(!json.contains("password"))
        #expect(!json.contains("designatedRequirement"))
        #expect(!json.contains("not-a-telemetry-secret"))
    }

    @Test("Matched rule is derived from regular and unavailable decisions")
    func matchedRuleDerivation() {
        let unavailable = FlowTrafficDecision(
            disposition: .direct,
            reason: .mihomoUnavailable(
                rule: .matchedRule("Fallback Rule"),
                fallback: .direct
            )
        )
        let activity = makeActivity(
            decision: unavailable,
            configuredAction: .mihomo(.profileRules),
            effectiveAction: .direct
        )
        #expect(activity.matchedRuleIdentifier == "Fallback Rule")
        #expect(activity.configuredAction == .mihomo(.profileRules))
        #expect(activity.effectiveAction == .direct)

        let defaultDirect = makeActivity(
            decision: FlowTrafficDecision(
                disposition: .direct,
                reason: .rule(.defaultDirect)
            ),
            configuredAction: .direct,
            effectiveAction: .direct
        )
        #expect(defaultDirect.matchedRuleIdentifier == nil)
    }

    @Test("Upsert coalesces a flow, assigns sequences, and moves it newest")
    func upsertCoalescesAndOrders() {
        let ring = BoundedAppRoutingActivityRing(capacity: 3)
        let firstID = UUID()
        let secondID = UUID()

        let first = ring.upsert(makeActivity(flowIdentifier: firstID))
        let second = ring.upsert(makeActivity(flowIdentifier: secondID))
        var update = first
        update.relayState = .relaying
        update.uploadBytes = 90
        let updated = ring.upsert(update)

        #expect(first.sequence == 1)
        #expect(second.sequence == 2)
        #expect(updated.sequence == 3)
        #expect(ring.count == 2)
        #expect(ring.activity(for: firstID) == updated)
        #expect(ring.batch(limit: 10).activities.map(\.flowIdentifier) == [secondID, firstID])
        #expect(ring.droppedBeforeSequence == nil)
    }

    @Test("Capacity eviction reports an exact dropped-before watermark")
    func capacityAndDroppedWatermark() {
        let ring = BoundedAppRoutingActivityRing(capacity: 2)
        let first = ring.upsert(makeActivity())
        let second = ring.upsert(makeActivity())
        let third = ring.upsert(makeActivity())

        #expect(ring.count == 2)
        #expect(ring.activity(for: first.flowIdentifier) == nil)
        #expect(ring.droppedBeforeSequence == first.sequence)

        let batch = ring.batch(after: 0, limit: 10)
        #expect(batch.activities.map(\.sequence) == [second.sequence, third.sequence])
        #expect(batch.droppedBeforeSequence == first.sequence)
        #expect(batch.nextCursor == third.sequence)
        #expect(!batch.hasMore)
    }

    @Test("Cursor and limit page changed records without duplication")
    func cursorPagination() {
        let ring = BoundedAppRoutingActivityRing(capacity: 5)
        for _ in 0..<5 {
            ring.upsert(makeActivity())
        }

        let first = ring.batch(limit: 2)
        let second = ring.batch(after: first.nextCursor, limit: 2)
        let third = ring.batch(after: second.nextCursor, limit: 2)

        #expect(first.activities.map(\.sequence) == [1, 2])
        #expect(first.hasMore)
        #expect(second.activities.map(\.sequence) == [3, 4])
        #expect(second.hasMore)
        #expect(third.activities.map(\.sequence) == [5])
        #expect(!third.hasMore)
        #expect(Set((first.activities + second.activities + third.activities).map(\.flowIdentifier)).count == 5)

        let noChange = ring.batch(after: third.nextCursor, limit: 2)
        #expect(noChange.activities.isEmpty)
        #expect(noChange.nextCursor == third.nextCursor)
        #expect(!noChange.hasMore)
    }

    @Test("Zero capacity and non-positive limits remain bounded")
    func zeroCapacityAndLimits() {
        let disabled = BoundedAppRoutingActivityRing(capacity: 0)
        let stored = disabled.upsert(makeActivity())
        #expect(disabled.count == 0)
        #expect(disabled.latestSequence == 1)
        #expect(disabled.droppedBeforeSequence == stored.sequence)
        #expect(disabled.batch(limit: 10).activities.isEmpty)

        let ring = BoundedAppRoutingActivityRing(capacity: 2)
        ring.upsert(makeActivity())
        #expect(ring.batch(limit: 0).activities.isEmpty)
        #expect(ring.batch(limit: -1).activities.isEmpty)
    }

    @Test("Clearing retains cursor monotonicity and reports discarded records")
    func removeAllMaintainsCursorSafety() {
        let ring = BoundedAppRoutingActivityRing(capacity: 3)
        ring.upsert(makeActivity())
        let second = ring.upsert(makeActivity())
        ring.removeAll()

        #expect(ring.count == 0)
        #expect(ring.latestSequence == second.sequence)
        #expect(ring.droppedBeforeSequence == second.sequence)

        let next = ring.upsert(makeActivity())
        #expect(next.sequence == second.sequence + 1)
    }

    @Test("Concurrent upserts preserve uniqueness, order, and the hard bound")
    func concurrentUpserts() {
        let ring = BoundedAppRoutingActivityRing(capacity: 64)
        let identifiers = (0..<16).map { _ in UUID() }

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            var activity = makeActivity(flowIdentifier: identifiers[index % identifiers.count])
            activity.uploadBytes = UInt64(index)
            ring.upsert(activity)
        }

        let batch = ring.batch(limit: 64)
        let sequences = batch.activities.map(\.sequence)
        #expect(ring.count == identifiers.count)
        #expect(ring.latestSequence == 1_000)
        #expect(sequences == sequences.sorted())
        #expect(Set(batch.activities.map(\.flowIdentifier)).count == identifiers.count)
        #expect(batch.activities.allSatisfy { $0.sequence > 0 })
    }

    @Test("Batch itself has a stable wire representation")
    func batchRoundTrip() throws {
        let ring = BoundedAppRoutingActivityRing(capacity: 1)
        ring.upsert(makeActivity())
        let batch = ring.batch(limit: 1)
        let data = try JSONEncoder().encode(batch)
        #expect(try JSONDecoder().decode(AppRoutingActivityBatch.self, from: data) == batch)
    }

    private func makeActivity(
        flowIdentifier: UUID = UUID(),
        ruleIdentifier: String = "Proxy Browser",
        decision: FlowTrafficDecision? = nil,
        configuredAction: CaptureAction = .mihomo(.profileRules),
        effectiveAction: FlowTrafficDisposition = .mihomo(.profileRules)
    ) -> AppRoutingActivity {
        let decision = decision ?? FlowTrafficDecision(
            disposition: effectiveAction,
            reason: .rule(.matchedRule(ruleIdentifier))
        )
        return AppRoutingActivity(
            flowIdentifier: flowIdentifier,
            configurationRevision: 42,
            startedAt: Date(timeIntervalSince1970: 1_721_200_000),
            source: AppRoutingActivitySource(
                processIdentifier: 1_234,
                processStartTime: try! ProcessStartTime(seconds: 100, microseconds: 5),
                userIdentifier: 501,
                executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
                bundleIdentifier: "com.example.browser",
                signingIdentifier: "com.example.browser",
                teamIdentifier: "TEAM123"
            ),
            destination: AppRoutingActivityDestination(
                hostname: "example.com",
                ipAddress: "203.0.113.8",
                port: 443
            ),
            transportProtocol: .tcp,
            decision: decision,
            configuredAction: configuredAction,
            effectiveAction: effectiveAction,
            relayState: .connecting,
            relayError: nil,
            relayLocalPort: nil
        )
    }
}
