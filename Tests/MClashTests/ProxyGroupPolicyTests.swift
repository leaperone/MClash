import XCTest
@testable import MClashApp

final class ProxyGroupPolicyTests: XCTestCase {
    func testSelectUsesStableOrderAndRejectsWhenAllFreshProbesFail() throws {
        let first = try node("first", port: 1001)
        let second = try node("second", port: 1002)
        let group = ProxyGroup(name: "Auto", type: .select, members: [.node(first.id), .node(second.id)])
        let now = Date(timeIntervalSince1970: 10_000)
        let probes = [first, second].map {
            GroupProbeResult(nodeID: $0.id, connectionFingerprint: $0.connectionFingerprint, checkedAt: now, outcome: .failed(stage: "timeout"))
        }
        let document = ConfigurationDocument(nodes: [first, second], proxyGroups: [group])
        let result = ProxyGroupPolicy.resolve(document: document, probes: probes, now: now)
        XCTAssertEqual(result[group.id]?.orderedCandidates, [first.id, second.id])
        XCTAssertEqual(result[group.id]?.destination, .reject)
    }

    func testManualOverrideWinsAndStaleFingerprintIsIgnored() throws {
        let first = try node("first", port: 1001)
        let second = try node("second", port: 1002)
        let group = ProxyGroup(name: "Manual", members: [.node(first.id), .node(second.id)])
        let now = Date(timeIntervalSince1970: 10_000)
        let stale = GroupProbeResult(nodeID: second.id, connectionFingerprint: "old", checkedAt: now, outcome: .available(latencyMilliseconds: 1))
        let document = ConfigurationDocument(nodes: [first, second], proxyGroups: [group])
        let result = ProxyGroupPolicy.resolve(document: document, persistedOverrides: [group.id: second.id], probes: [stale], now: now)
        XCTAssertEqual(result[group.id]?.destination, .node(second.id))
        XCTAssertEqual(result[group.id]?.reason, "manual_override")
    }

    func testURLTestCooldownKeepsPreviousMemberWithinTolerance() throws {
        let old = try node("old", port: 1001)
        let fast = try node("fast", port: 1002)
        let group = ProxyGroup(name: "Latency", type: .urlTest, members: [.node(old.id), .node(fast.id)])
        let selectedAt = Date(timeIntervalSince1970: 10_000)
        let now = selectedAt.addingTimeInterval(5)
        let probes = [
            GroupProbeResult(nodeID: old.id, connectionFingerprint: old.connectionFingerprint, checkedAt: now, outcome: .available(latencyMilliseconds: 100)),
            GroupProbeResult(nodeID: fast.id, connectionFingerprint: fast.connectionFingerprint, checkedAt: now, outcome: .available(latencyMilliseconds: 90))
        ]
        let document = ConfigurationDocument(nodes: [old, fast], proxyGroups: [group])
        let result = ProxyGroupPolicy.resolve(document: document, probes: probes, previousSelections: [group.id: GroupSelectionState(member: old.id, selectedAt: selectedAt)], now: now)
        XCTAssertEqual(result[group.id]?.selectedMember, old.id)
        XCTAssertEqual(result[group.id]?.reason, "cooldown")
    }

    func testUnsupportedTypesAreExplicitAndCyclesFailClosed() throws {
        let node = try node("node", port: 1001)
        let relay = ProxyGroup(name: "Relay", type: .relay, members: [.node(node.id)])
        let aID = ProxyGroupID()
        let bID = ProxyGroupID()
        let a = ProxyGroup(id: aID, name: "A", members: [.group(bID)])
        let b = ProxyGroup(id: bID, name: "B", members: [.group(aID)])
        let document = ConfigurationDocument(nodes: [node], proxyGroups: [relay, a, b])
        let result = ProxyGroupPolicy.resolve(document: document)
        XCTAssertEqual(result[relay.id]?.destination, .unsupported("relay"))
        XCTAssertEqual(result[aID]?.destination, .reject)
        XCTAssertEqual(result[bID]?.destination, .unsupported("cycle"))
    }

    private func node(_ name: String, port: Int) throws -> Node {
        try Node(displayName: name, protocol: .vmess, host: "example.com", port: port)
    }
}
