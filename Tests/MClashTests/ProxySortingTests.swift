import Testing
@testable import MClashApp

@Suite("Proxy node sorting")
struct ProxySortingTests {
    @Test("Profile, latency, and name modes are total and deterministic")
    func sortsWithStableTieBreakers() throws {
        let collection = try makeProxyCollection([
            ProxyTestSpec(
                name: "Group",
                type: "Selector",
                all: ["Zulu", "alpha", "Béta"],
                now: "Zulu"
            ),
            ProxyTestSpec(name: "Zulu", type: "Trojan"),
            ProxyTestSpec(name: "alpha", type: "Shadowsocks"),
            ProxyTestSpec(name: "Béta", type: "WireGuard"),
        ])
        let topology = ProxyTopologyBuilder().build(collection: collection)
        let sorter = ProxyNodeSorter()
        let input = ["Béta", "alpha", "Zulu"]

        #expect(
            sorter.sortedNodeNames(input, in: "Group", topology: topology, delays: [:], mode: .profile)
                == ["Zulu", "alpha", "Béta"]
        )
        #expect(
            sorter.sortedNodeNames(
                input,
                in: "Group",
                topology: topology,
                delays: ["Zulu": 50, "alpha": 50, "Béta": 0],
                mode: .latency
            ) == ["Zulu", "alpha", "Béta"]
        )
        #expect(
            sorter.sortedNodeNames(input, in: "Group", topology: topology, delays: [:], mode: .name)
                == ["alpha", "Béta", "Zulu"]
        )
    }

    @Test("Duplicate inputs retain a final stable source-position tie breaker")
    func duplicateNamesRemainStable() throws {
        let collection = try makeProxyCollection([
            ProxyTestSpec(name: "Node", type: "Direct"),
        ])
        let topology = ProxyTopologyBuilder().build(collection: collection)

        let result = ProxyNodeSorter().sortedNodeNames(
            ["Node", "Node"],
            in: nil,
            topology: topology,
            delays: ["Node": 10],
            mode: .latency
        )

        #expect(result == ["Node", "Node"])
    }
}
