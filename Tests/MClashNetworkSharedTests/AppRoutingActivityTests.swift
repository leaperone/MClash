import Foundation
import MClashNetworkShared
import Testing

@Suite("App Routing activity telemetry")
struct AppRoutingActivityTests {
    @Test("Activity is Codable, Hashable, and omits sensitive process material")
    func activityRoundTripAndPrivacyBoundary() throws {
        let evidence = CaptureRuleDecisionEvidence(
            outcome: .matchedRule,
            source: .application(RuleApplicationSourceEvidence(
                signingIdentifier: "com.example.browser",
                teamIdentifier: "TEAM123",
                bundleIdentifier: "com.example.browser"
            )),
            destination: .host(RuleHostDestinationEvidence(kind: .suffix, value: "example.com")),
            transportProtocol: .exact(.tcp),
            destinationPort: .range(try PortRange(443))
        )
        var activity = makeActivity(
            flowIdentifier: UUID(uuidString: "D54CF072-2153-4CD8-BB79-B467628B66FA")!,
            ruleIdentifier: "Browser Proxy",
            decision: FlowTrafficDecision(
                disposition: .mihomo(.profileRules),
                reason: .rule(.matchedRule("Browser Proxy")),
                ruleEvidence: evidence
            )
        )
        activity.relayState = .relaying
        activity.relayNote = "Mihomo setup failed before payload; Direct fallback is active."
        activity.relayLocalPort = 51_234
        activity.uploadBytes = 123
        activity.downloadBytes = 456

        let data = try JSONEncoder().encode(activity)
        let decoded = try JSONDecoder().decode(AppRoutingActivity.self, from: data)
        #expect(decoded == activity)
        #expect(Set([activity, decoded]).count == 1)
        #expect(decoded.matchedRuleIdentifier == "Browser Proxy")
        #expect(decoded.cause == activity.decision.reason)
        #expect(decoded.ruleEvidence == evidence)
        #expect(decoded.relayNote == activity.relayNote)

        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("auditToken"))
        #expect(!json.contains("password"))
        #expect(!json.contains("designatedRequirement"))
        #expect(!json.contains("not-a-telemetry-secret"))
    }

    @Test("Legacy activity without structured rule evidence still decodes")
    func legacyActivityWithoutRuleEvidenceDecodes() throws {
        let evidence = CaptureRuleDecisionEvidence(
            outcome: .matchedRule,
            source: .userID(501),
            destination: .unconstrained,
            transportProtocol: .exact(.tcp),
            destinationPort: .unconstrained
        )
        let activity = makeActivity(decision: FlowTrafficDecision(
            disposition: .mihomo(.profileRules),
            reason: .rule(.matchedRule("Proxy Browser")),
            ruleEvidence: evidence
        ))
        let encoded = try JSONEncoder().encode(activity)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var decision = try #require(object["decision"] as? [String: Any])
        decision.removeValue(forKey: "ruleEvidence")
        object["decision"] = decision
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AppRoutingActivity.self, from: legacyData)
        #expect(decoded.ruleEvidence == nil)
        #expect(decoded.matchedRuleIdentifier == "Proxy Browser")
        #expect(decoded.effectiveAction == .mihomo(.profileRules))
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
        let first = ring.upsert(makeTerminalActivity())
        let second = ring.upsert(makeTerminalActivity())
        let third = ring.upsert(makeTerminalActivity())

        #expect(ring.count == 2)
        #expect(ring.activeCount == 0)
        #expect(ring.historyCount == 2)
        #expect(ring.activity(for: first.flowIdentifier) == nil)
        #expect(ring.droppedBeforeSequence == first.sequence)

        let batch = ring.batch(after: 0, limit: 10)
        #expect(batch.activities.map(\.sequence) == [second.sequence, third.sequence])
        #expect(batch.droppedBeforeSequence == first.sequence)
        #expect(batch.nextCursor == third.sequence)
        #expect(!batch.hasMore)
    }

    @Test("Active flow survives short-flow history pressure and remains updatable")
    func activeFlowSurvivesHistoryPressure() {
        let ring = BoundedAppRoutingActivityRing(capacity: 3)
        let activeIdentifier = UUID()
        let initial = ring.upsert(makeActivity(flowIdentifier: activeIdentifier))

        for _ in 0..<20 {
            ring.upsert(makeTerminalActivity())
        }

        #expect(ring.count == 3)
        #expect(ring.activeCount == 1)
        #expect(ring.historyCount == 2)
        #expect(ring.activity(for: activeIdentifier) == initial)

        var update = initial
        update.relayState = .relaying
        update.uploadBytes = 12_345
        update.downloadBytes = 67_890
        let stored = ring.upsert(update)

        #expect(ring.activity(for: activeIdentifier) == stored)
        #expect(stored.sequence == 22)
        #expect(stored.uploadBytes == 12_345)
        #expect(stored.downloadBytes == 67_890)
    }

    @Test("Concurrent active flows may exceed history capacity without eviction")
    func activeFlowsMayTemporarilyExceedCapacity() {
        let ring = BoundedAppRoutingActivityRing(capacity: 2)
        let identifiers = (0..<4).map { _ in UUID() }
        identifiers.forEach { ring.upsert(makeActivity(flowIdentifier: $0)) }

        #expect(ring.count == 4)
        #expect(ring.activeCount == 4)
        #expect(ring.historyCount == 0)
        #expect(identifiers.allSatisfy { ring.activity(for: $0) != nil })

        var completed = ring.activity(for: identifiers[0])!
        completed.relayState = .completed
        completed.endedAt = Date(timeIntervalSince1970: 1_721_200_100)
        ring.upsert(completed)

        #expect(ring.activeCount == 3)
        #expect(ring.historyCount == 0)
        #expect(ring.activity(for: identifiers[0]) == nil)
        #expect(identifiers.dropFirst().allSatisfy { ring.activity(for: $0) != nil })
    }

    @Test("Final state migrates an active flow to bounded history with exact counters")
    func finalStateIsExactAndRetained() {
        let ring = BoundedAppRoutingActivityRing(capacity: 2)
        let identifier = UUID()
        var activity = ring.upsert(makeActivity(flowIdentifier: identifier))
        activity.relayState = .completed
        activity.endedAt = Date(timeIntervalSince1970: 1_721_200_100)
        activity.uploadBytes = 999_999
        activity.downloadBytes = 888_888

        let completed = ring.upsert(activity)

        #expect(ring.activeCount == 0)
        #expect(ring.historyCount == 1)
        #expect(ring.activity(for: identifier) == completed)
        #expect(completed.relayState == .completed)
        #expect(completed.endedAt == activity.endedAt)
        #expect(completed.uploadBytes == 999_999)
        #expect(completed.downloadBytes == 888_888)
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

    @Test("Clearing history preserves active flows and their future final update")
    func removeHistoryPreservesActiveFlows() {
        let ring = BoundedAppRoutingActivityRing(capacity: 3)
        let activeIdentifier = UUID()
        var active = ring.upsert(makeActivity(flowIdentifier: activeIdentifier))
        let terminal = ring.upsert(makeTerminalActivity())

        ring.removeHistory()

        #expect(ring.count == 1)
        #expect(ring.activeCount == 1)
        #expect(ring.historyCount == 0)
        #expect(ring.activity(for: terminal.flowIdentifier) == nil)
        #expect(ring.activity(for: activeIdentifier) == active)
        #expect(ring.droppedBeforeSequence == terminal.sequence)

        active.relayState = .failed
        active.relayError = "relay stopped"
        active.endedAt = Date(timeIntervalSince1970: 1_721_200_200)
        let failed = ring.upsert(active)
        #expect(ring.activity(for: activeIdentifier) == failed)
        #expect(ring.activeCount == 0)
        #expect(ring.historyCount == 1)
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

    @Test("Concurrent active updates and terminal churn preserve every live flow")
    func concurrentActiveAndHistoryChurn() {
        let ring = BoundedAppRoutingActivityRing(capacity: 64)
        let activeIdentifiers = (0..<16).map { _ in UUID() }
        let terminalIdentifiers = (0..<1_000).map { _ in UUID() }
        activeIdentifiers.forEach { ring.upsert(makeActivity(flowIdentifier: $0)) }

        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            if index.isMultiple(of: 2) {
                var update = makeActivity(
                    flowIdentifier: activeIdentifiers[(index / 2) % activeIdentifiers.count]
                )
                update.relayState = .relaying
                update.uploadBytes = UInt64(index)
                ring.upsert(update)
            } else {
                ring.upsert(makeTerminalActivity(
                    flowIdentifier: terminalIdentifiers[index / 2]
                ))
            }
        }

        let batch = ring.batch(limit: 64)
        #expect(ring.latestSequence == 2_016)
        #expect(ring.activeCount == activeIdentifiers.count)
        #expect(ring.historyCount == 48)
        #expect(ring.count == ring.capacity)
        #expect(activeIdentifiers.allSatisfy { ring.activity(for: $0) != nil })
        #expect(batch.activities.map(\.sequence) == batch.activities.map(\.sequence).sorted())
        #expect(Set(batch.activities.map(\.flowIdentifier)).count == batch.activities.count)
    }

    @Test("Report limiter coalesces bursts and flushes the latest trailing counters")
    func reportLimiterThrottlesAndFlushes() {
        var limiter = AppRoutingRelayReportLimiter(
            minimumIntervalNanoseconds: 250,
            byteThreshold: 1_000
        )

        #expect(limiter.decision(
            for: .ready,
            uploadBytes: 0,
            downloadBytes: 0,
            nowNanoseconds: 0
        ) == .emit)
        #expect(limiter.decision(
            for: .relaying,
            uploadBytes: 100,
            downloadBytes: 50,
            nowNanoseconds: 10
        ) == .emit)
        #expect(limiter.decision(
            for: .relaying,
            uploadBytes: 200,
            downloadBytes: 100,
            nowNanoseconds: 60
        ) == .schedule(afterNanoseconds: 200))
        #expect(limiter.decision(
            for: .relaying,
            uploadBytes: 300,
            downloadBytes: 200,
            nowNanoseconds: 100
        ) == .suppress)
        let earlyFlush = limiter.shouldEmitScheduledReport(
            uploadBytes: 300,
            downloadBytes: 200,
            nowNanoseconds: 259
        )
        #expect(!earlyFlush)
        let dueFlush = limiter.shouldEmitScheduledReport(
            uploadBytes: 300,
            downloadBytes: 200,
            nowNanoseconds: 260
        )
        #expect(dueFlush)
    }

    @Test("Byte threshold bypasses time throttle and terminal states are immediate")
    func reportLimiterByteThresholdAndFinalState() {
        var limiter = AppRoutingRelayReportLimiter(
            minimumIntervalNanoseconds: 1_000,
            byteThreshold: 500
        )
        #expect(limiter.decision(
            for: .relaying,
            uploadBytes: 10,
            downloadBytes: 10,
            nowNanoseconds: 0
        ) == .emit)
        #expect(limiter.decision(
            for: .relaying,
            uploadBytes: 410,
            downloadBytes: 110,
            nowNanoseconds: 10
        ) == .emit)
        #expect(limiter.decision(
            for: .relaying,
            uploadBytes: 420,
            downloadBytes: 120,
            nowNanoseconds: 20
        ) == .schedule(afterNanoseconds: 990))

        #expect(limiter.decision(
            for: .failed,
            uploadBytes: 777,
            downloadBytes: 888,
            nowNanoseconds: 21
        ) == .emit)
        let staleFlush = limiter.shouldEmitScheduledReport(
            uploadBytes: 777,
            downloadBytes: 888,
            nowNanoseconds: 2_000
        )
        #expect(!staleFlush)
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

    private func makeTerminalActivity(
        flowIdentifier: UUID = UUID()
    ) -> AppRoutingActivity {
        var activity = makeActivity(flowIdentifier: flowIdentifier)
        activity.relayState = .completed
        activity.endedAt = Date(timeIntervalSince1970: 1_721_200_100)
        return activity
    }
}
