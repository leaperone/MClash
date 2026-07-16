import Testing
@testable import MClashApp

@Suite("Proxy topology builder")
struct ProxyTopologyBuilderTests {
    @Test("Profile order, dependencies, roots, parents, and unresolved references are deterministic")
    func buildsStableTopology() throws {
        let specs = topologySpecs
        let profile = ProfileStructure(
            groupOrder: ["Root", "Nested"],
            membersByGroup: ["Root": ["Nested", "Leaf"]]
        )
        let forward = ProxyTopologyBuilder().build(
            collection: try makeProxyCollection(specs),
            profileStructure: profile
        )
        let reversed = ProxyTopologyBuilder().build(
            collection: try makeProxyCollection(specs.reversed()),
            profileStructure: profile
        )

        #expect(forward == reversed)
        #expect(forward.groupOrder == ["Root", "Nested", "Dialer", "Zulu"])
        #expect(forward.visibleGroupOrder == ["Root", "Nested", "Dialer", "Zulu"])
        #expect(forward.childrenByGroup["Root"] == ["Leaf", "Nested", "Missing"])
        #expect(forward.parentsByChild["Nested"] == ["Root"])
        #expect(forward.parentsByChild["Dialer"] == ["Leaf"])
        #expect(forward.roots == ["Root", "Zulu"])
        #expect(forward.unresolved == ["Missing"])
        #expect(
            forward.edges.contains(
                ProxyTopologyEdge(source: "Root", target: "Nested", kind: .member)
            )
        )
        #expect(
            forward.edges.contains(
                ProxyTopologyEdge(source: "Leaf", target: "Dialer", kind: .dialer)
            )
        )
    }

    @Test("Member and dialer edges participate in one cycle detector")
    func detectsCombinedCycles() throws {
        let collection = try makeProxyCollection([
            ProxyTestSpec(name: "Root", type: "Selector", all: ["Leaf"], now: "Leaf"),
            ProxyTestSpec(name: "Leaf", type: "Shadowsocks", dialerProxy: "Root"),
        ])

        let topology = ProxyTopologyBuilder().build(collection: collection)

        #expect(topology.cycles == [ProxyTopologyCycle(nodes: ["Leaf", "Root", "Leaf"])])
        #expect(topology.roots.isEmpty)
    }

    @Test("Hidden groups remain in topology but are omitted from visible order")
    func preservesHiddenDependencies() throws {
        let collection = try makeProxyCollection([
            ProxyTestSpec(name: "Visible", type: "Selector", all: ["Hidden"], now: "Hidden"),
            ProxyTestSpec(name: "Hidden", type: "Fallback", all: ["Leaf"], now: "Leaf", hidden: true),
            ProxyTestSpec(name: "Leaf", type: "Direct"),
        ])

        let topology = ProxyTopologyBuilder().build(collection: collection)

        #expect(topology.groupOrder == ["Hidden", "Visible"])
        #expect(topology.visibleGroupOrder == ["Visible"])
        #expect(topology.vertices["Hidden"]?.isGroup == true)
        #expect(topology.parentsByChild["Hidden"] == ["Visible"])
    }

    private var topologySpecs: [ProxyTestSpec] {
        [
            ProxyTestSpec(
                name: "Root",
                type: "Selector",
                all: ["Leaf", "Nested", "Missing"],
                now: "Nested"
            ),
            ProxyTestSpec(name: "Nested", type: "URLTest", all: ["Nested Leaf"], now: "Nested Leaf"),
            ProxyTestSpec(name: "Zulu", type: "LoadBalance", all: ["Leaf"]),
            ProxyTestSpec(name: "Dialer", type: "Fallback", all: ["Dialer Leaf"], now: "Dialer Leaf"),
            ProxyTestSpec(name: "Leaf", type: "Shadowsocks", dialerProxy: "Dialer"),
            ProxyTestSpec(name: "Nested Leaf", type: "Trojan"),
            ProxyTestSpec(name: "Dialer Leaf", type: "Direct"),
        ]
    }
}
