import Testing
@testable import MClashApp

@Suite("Proxy topology projection")
struct ProxyTopologyProjectionTests {
    @Test("Dialer groups expand through their selected endpoint")
    func expandsDialerGroupBranch() throws {
        let collection = try makeProxyCollection([
            ProxyTestSpec(
                name: "Root",
                type: "Selector",
                all: ["Leaf", "Unused Leaf"],
                now: "Leaf"
            ),
            ProxyTestSpec(name: "Leaf", type: "Shadowsocks", dialerProxy: "Dialer"),
            ProxyTestSpec(
                name: "Dialer",
                type: "URLTest",
                all: ["Dialer Leaf"],
                now: "Dialer Leaf"
            ),
            ProxyTestSpec(name: "Dialer Leaf", type: "Direct"),
            ProxyTestSpec(
                name: "Unused Leaf",
                type: "Shadowsocks",
                dialerProxy: "Unused Dialer"
            ),
            ProxyTestSpec(name: "Unused Dialer", type: "Direct")
        ])
        let topology = ProxyTopologyBuilder().build(collection: collection)
        let path = ProxySelectionPathResolver().resolve(from: "Root", topology: topology)

        let projection = ProxyTopologyProjection(
            topology: topology,
            rootGroup: "Root",
            selectedPath: path,
            delays: [:]
        )

        #expect(Set(projection.nodes.map(\.sourceName)).isSuperset(of: [
            "Root", "Leaf", "Dialer", "Dialer Leaf"
        ]))
        #expect(projection.edges.contains {
            $0.source == "Leaf"
                && $0.target == "Dialer"
                && $0.kind == .dialer
                && $0.isDialerPath
        })
        #expect(projection.edges.contains {
            $0.source == "Dialer"
                && $0.target == "Dialer Leaf"
                && $0.kind == .member
                && $0.isDialerPath
                && !$0.isSelected
        })
        #expect(projection.edges.contains {
            $0.source == "Unused Leaf"
                && $0.target == "Unused Dialer"
                && $0.kind == .dialer
                && !$0.isDialerPath
        })
    }
}
