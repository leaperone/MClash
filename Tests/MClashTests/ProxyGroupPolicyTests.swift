import Foundation
import Testing
@testable import MClashApp

@Suite("MClash group policy")
struct ProxyGroupPolicyTests {
    let now = Date(timeIntervalSince1970: 10_000)

    @Test("Empty node scope includes the catalog and named nested selection survives")
    func nestedSelection() throws {
        let first = try node("first", port: 1001)
        let second = try node("second", port: 1002)
        let child = ProxyGroup(name: "Region", members: [.node(second.id)])
        let parent = ProxyGroup(name: "Default", members: [.node(first.id), .group(child.id)])
        let workspace = Workspace(name: "Work", proxyGroupIDs: [parent.id, child.id], dnsPolicyID: DNSPolicyID())
        let document = ConfigurationDocument(nodes: [first, second], proxyGroups: [parent, child])
        let result = ProxyGroupPolicy.resolve(document: document, workspace: workspace,
            persistedOverrides: [parent.id: .group(child.id)], now: now)
        #expect(result[parent.id]?.destination == .node(second.id))
        #expect(result[parent.id]?.selectedMember == .group(child.id))
        #expect(document.proxyGroups.first?.members == [.node(first.id), .group(child.id)])
    }

    @Test("Fallback requires repeated failures and preserves candidate order")
    func fallback() throws {
        let first = try node("first", port: 1001)
        let second = try node("second", port: 1002)
        let group = ProxyGroup(name: "Failover", type: .fallback, members: [.node(first.id), .node(second.id)])
        let document = ConfigurationDocument(nodes: [first, second], proxyGroups: [group])
        let failed = probe(first, secondsAgo: 0, outcome: .failed(stage: "timeout"))
        let single = ProxyGroupPolicy.resolve(document: document, probes: [failed], now: now)
        #expect(single[group.id]?.destination == .node(first.id))
        let repeated = ProxyGroupPolicy.resolve(document: document,
            probes: [failed, probe(first, secondsAgo: 10, outcome: .failed(stage: "timeout"))], now: now)
        #expect(repeated[group.id]?.destination == .node(second.id))
        #expect(repeated[group.id]?.orderedCandidates == [first.id, second.id])
    }

    @Test("All failed candidates reject instead of treating timeouts as fast nodes")
    func allFailed() throws {
        let first = try node("first", port: 1001)
        let second = try node("second", port: 1002)
        for type in [ProxyGroupType.fallback, .urlTest] {
            let group = ProxyGroup(name: "Automatic", type: type, members: [.node(first.id), .node(second.id)])
            let document = ConfigurationDocument(nodes: [first, second], proxyGroups: [group])
            let probes = [first, second].flatMap { n in
                [probe(n, secondsAgo: 0, outcome: .failed(stage: "timeout")),
                 probe(n, secondsAgo: 10, outcome: .failed(stage: "timeout"))]
            }
            #expect(ProxyGroupPolicy.resolve(document: document, probes: probes, now: now)[group.id]?.destination == .reject)
        }
    }

    @Test("Fallback waits for two successful recovery probes before returning to priority one")
    func recovery() throws {
        let first = try node("first", port: 1001)
        let second = try node("second", port: 1002)
        let group = ProxyGroup(name: "Failover", type: .fallback, members: [.node(first.id), .node(second.id)])
        let document = ConfigurationDocument(nodes: [first, second], proxyGroups: [group])
        let previous = [group.id: GroupSelectionState(member: .node(second.id), selectedAt: now.addingTimeInterval(-60))]
        var probes = [probe(first, secondsAgo: 0, outcome: .available(latencyMilliseconds: 100))]
        #expect(ProxyGroupPolicy.resolve(document: document, probes: probes, previousSelections: previous, now: now)[group.id]?.destination == .node(second.id))
        probes.append(probe(first, secondsAgo: 10, outcome: .available(latencyMilliseconds: 110)))
        #expect(ProxyGroupPolicy.resolve(document: document, probes: probes, previousSelections: previous, now: now)[group.id]?.destination == .node(first.id))
    }

    @Test("URL-test cooldown and hysteresis prevent flapping")
    func urlTest() throws {
        let old = try node("old", port: 1001)
        let fast = try node("fast", port: 1002)
        let group = ProxyGroup(name: "Latency", type: .urlTest, members: [.node(old.id), .node(fast.id)])
        let document = ConfigurationDocument(nodes: [old, fast], proxyGroups: [group])
        let probes = [probe(old, secondsAgo: 0, outcome: .available(latencyMilliseconds: 180)),
                      probe(fast, secondsAgo: 0, outcome: .available(latencyMilliseconds: 90))]
        let recent = [group.id: GroupSelectionState(member: .node(old.id), selectedAt: now.addingTimeInterval(-5))]
        let cooled = [group.id: GroupSelectionState(member: .node(old.id), selectedAt: now.addingTimeInterval(-60))]
        #expect(ProxyGroupPolicy.resolve(document: document, probes: probes, previousSelections: recent, now: now)[group.id]?.destination == .node(old.id))
        #expect(ProxyGroupPolicy.resolve(document: document, probes: probes, previousSelections: cooled, now: now)[group.id]?.destination == .node(fast.id))
        let close = [probe(old, secondsAgo: 0, outcome: .available(latencyMilliseconds: 100)), probes[1]]
        #expect(ProxyGroupPolicy.resolve(document: document, probes: close, previousSelections: cooled, now: now)[group.id]?.destination == .node(old.id))
    }

    @Test("Credential rotation, stale probes, and a different probe URL cannot select a node")
    func probeScope() throws {
        let first = try node("first", port: 1001)
        let second = try node("second", port: 1002)
        let group = ProxyGroup(name: "Latency", type: .urlTest, members: [.node(first.id), .node(second.id)])
        let document = ConfigurationDocument(nodes: [first, second], proxyGroups: [group])
        let wrongFingerprint = GroupProbeResult(nodeID: second.id, connectionFingerprint: "old", checkedAt: now, outcome: .available(latencyMilliseconds: 1))
        let wrongURL = GroupProbeResult(nodeID: second.id, connectionFingerprint: second.connectionFingerprint, checkedAt: now,
                                       outcome: .available(latencyMilliseconds: 1), targetURL: URL(string: "https://example.org/test")!)
        let stale = probe(second, secondsAgo: 1000, outcome: .available(latencyMilliseconds: 1))
        #expect(ProxyGroupPolicy.resolve(document: document, probes: [wrongFingerprint, wrongURL, stale], now: now)[group.id]?.destination == .node(first.id))
    }

    @Test("Manual choice wins until cleared and missing pins reject")
    func manualPin() throws {
        let first = try node("first", port: 1001)
        let second = try node("second", port: 1002)
        let group = ProxyGroup(name: "Latency", type: .urlTest, members: [.node(first.id), .node(second.id)])
        let document = ConfigurationDocument(nodes: [first, second], proxyGroups: [group])
        let probes = [probe(first, secondsAgo: 0, outcome: .available(latencyMilliseconds: 1))]
        #expect(ProxyGroupPolicy.resolve(document: document, persistedOverrides: [group.id: .node(second.id)], probes: probes, now: now)[group.id]?.destination == .node(second.id))
        #expect(ProxyGroupPolicy.resolve(document: document, probes: probes, now: now)[group.id]?.destination == .node(first.id))
        #expect(ProxyGroupPolicy.resolve(document: document, persistedOverrides: [group.id: .node(NodeID())], now: now)[group.id]?.destination == .reject)
    }

    @Test("Direct and reject nested members preserve their action")
    func builtinGroups() throws {
        for type in [ProxyGroupType.direct, .reject] {
            let child = ProxyGroup(name: "Builtin", type: type)
            let parent = ProxyGroup(name: "Manual", members: [.group(child.id)])
            let result = ProxyGroupPolicy.resolve(document: ConfigurationDocument(proxyGroups: [parent, child]), now: now)
            #expect(result[parent.id]?.destination == (type == .direct ? .direct : .reject))
            #expect(result[parent.id]?.selectedMember == .group(child.id))
        }
    }

    @Test("Cycles fail closed independently of traversal order")
    func cycles() {
        let aID = ProxyGroupID()
        let bID = ProxyGroupID()
        let a = ProxyGroup(id: aID, name: "A", members: [.group(bID)])
        let b = ProxyGroup(id: bID, name: "B", members: [.group(aID)])
        let result = ProxyGroupPolicy.resolve(document: ConfigurationDocument(proxyGroups: [a, b]), now: now)
        #expect(result[aID]?.destination == .unsupported("cycle"))
        #expect(result[bID]?.destination == .unsupported("cycle"))
    }

    @Test("Load balance and relay preserve pools and ordered chains")
    func aggregateGroups() throws {
        let first = try node("first", port: 1001)
        let second = try node("second", port: 1002)
        let members = [first, second].map { ProxyGroupMember.node($0.id) }
        let balance = ProxyGroup(name: "Spread", type: .loadBalance, members: members)
        let relay = ProxyGroup(name: "Chain", type: .relay, members: members)
        let result = ProxyGroupPolicy.resolve(document: ConfigurationDocument(nodes: [first, second], proxyGroups: [balance, relay]), now: now)
        #expect(result[balance.id]?.destination == .balance([first.id, second.id]))
        #expect(result[relay.id]?.destination == .chain([first.id, second.id]))
    }

    private func node(_ name: String, port: Int) throws -> Node {
        try Node(displayName: name, protocol: .vmess, host: "example.com", port: port)
    }

    private func probe(_ node: Node, secondsAgo: TimeInterval, outcome: GroupProbeResult.Outcome) -> GroupProbeResult {
        GroupProbeResult(nodeID: node.id, connectionFingerprint: node.connectionFingerprint,
                         checkedAt: now.addingTimeInterval(-secondsAgo), outcome: outcome)
    }
}
