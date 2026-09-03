import Foundation
import MClashNetworkShared
import Testing
@testable import MClashApp

struct NativeProxyGroupTargetResolverTests {
    @Test("resolver preserves explicit order and traverses nested groups")
    func explicitAndNestedMembers() throws {
        let first = try node("Pinned", host: "first.example", availability: .available)
        let second = try node("Nested", host: "second.example", availability: .available)
        let nested = ProxyGroup(name: "Nested", members: [.node(second.id)])
        let root = ProxyGroup(name: "Root", members: [.node(first.id), .group(nested.id)])

        let result = NativeProxyGroupTargetResolver.resolve(
            groupID: root.id, groups: [root, nested], nodes: [first, second]
        )
        #expect(result.nodeID == first.id)
        #expect(result.target?.host == "first.example")
    }

    @Test("resolver ignores removed, unavailable and disabled nodes")
    func eligibility() throws {
        let removed = try node("Removed", host: "removed.example", availability: .sourceRemoved)
        let unavailable = try node("Unavailable", host: "unavailable.example", availability: .unavailable)
        let disabled = try node("Disabled", host: "disabled.example", availability: .available, enabled: false)
        let group = ProxyGroup(name: "Root", members: [.node(removed.id), .node(unavailable.id), .node(disabled.id)])

        let result = NativeProxyGroupTargetResolver.resolve(
            groupID: group.id, groups: [group], nodes: [removed, unavailable, disabled]
        )
        #expect(result.nodeID == nil)
        #expect(result.target == nil)
        #expect(result.reason != nil)
    }

    @Test("selector-backed membership follows refresh while fixed pins remain ordered")
    func selectors() throws {
        let pinned = try node("Pinned", host: "pinned.example", availability: .available)
        let refreshed = try node("US refreshed", host: "new.example", availability: .available)
        let selector = NodeSelector(
            name: "US", include: [.nameContains("US")], fixedNodeIDs: [pinned.id]
        )
        let group = ProxyGroup(name: "Root", memberSelectors: [selector])

        let result = NativeProxyGroupTargetResolver.resolve(
            groupID: group.id, groups: [group], nodes: [refreshed, pinned]
        )
        #expect(result.nodeID == pinned.id)
        #expect(result.target?.host == "pinned.example")
    }

    @Test("url-test chooses lowest measured latency and remains deterministic")
    func urlTestHealth() throws {
        let slow = try node("Slow", host: "slow.example", availability: .available, latency: 200)
        let fast = try node("Fast", host: "fast.example", availability: .available, latency: 20)
        let group = ProxyGroup(name: "Auto", type: .urlTest, members: [.node(slow.id), .node(fast.id)])

        let result = NativeProxyGroupTargetResolver.resolve(
            groupID: group.id, groups: [group], nodes: [slow, fast]
        )
        #expect(result.nodeID == fast.id)
    }

    @Test("Regional groups prefer CUNOE while explicit provider groups may opt in")
    func preferredSourcePolicy() throws {
        let cunoe = SourceID()
        let secondary = SourceID()
        let preferred = try node("US preferred", host: "cunoe.example", availability: .available, source: cunoe)
        let other = try node("US other", host: "other.example", availability: .available, source: secondary)
        let regional = ProxyGroup(name: "美国优先", members: [.node(other.id), .node(preferred.id)])
        let provider = ProxyGroup(name: "AI 专用", members: [.node(other.id), .node(preferred.id)])

        let regionalResult = NativeProxyGroupTargetResolver.resolve(
            groupID: regional.id,
            groups: [regional, provider],
            nodes: [other, preferred],
            preferredSourceIDs: [cunoe]
        )
        #expect(regionalResult.nodeID == preferred.id)

        let providerResult = NativeProxyGroupTargetResolver.resolve(
            groupID: provider.id,
            groups: [regional, provider],
            nodes: [other, preferred],
            preferredSourceIDs: [cunoe]
        )
        #expect(providerResult.nodeID == other.id)
    }

    private func node(
        _ name: String,
        host: String,
        availability: NodeAvailability,
        enabled: Bool = true,
        latency: Int? = nil,
        source: SourceID? = nil
    ) throws -> Node {
        try Node(
            displayName: name,
            protocol: .https,
            host: host,
            port: 443,
            sourceLinks: source.map { [$0] } ?? [],
            enabled: enabled,
            health: NodeHealthSnapshot(
                availability: availability,
                latencyMilliseconds: latency
            ),
        )
    }
}
