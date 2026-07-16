import Testing
@testable import MClashApp

@Suite("Proxy selected path resolver")
struct ProxySelectionPathTests {
    @Test("Selector, URLTest, Fallback, and dialer dependencies resolve recursively")
    func resolvesNestedAndDialerPath() throws {
        let collection = try makeProxyCollection([
            ProxyTestSpec(
                name: "Root",
                type: "Selector",
                all: ["Auto", "Stale Preference"],
                now: "Auto",
                fixed: "Stale Preference"
            ),
            ProxyTestSpec(name: "Auto", type: "URLTest", all: ["Fallback"], now: "Fallback"),
            ProxyTestSpec(name: "Fallback", type: "Fallback", all: ["Leaf"], now: "Leaf"),
            ProxyTestSpec(name: "Leaf", type: "Shadowsocks", dialerProxy: "Dialer"),
            ProxyTestSpec(name: "Dialer", type: "URLTest", all: ["Dialer Leaf"], now: "Dialer Leaf"),
            ProxyTestSpec(name: "Dialer Leaf", type: "Direct"),
            ProxyTestSpec(name: "Stale Preference", type: "Direct"),
        ])
        let topology = ProxyTopologyBuilder().build(collection: collection)

        let path = ProxySelectionPathResolver().resolve(from: "Root", topology: topology)

        #expect(path.route == ["Root", "Auto", "Fallback", "Leaf"])
        #expect(path.terminal == "Leaf")
        #expect(path.certainty == .automatic)
        #expect(path.issue == nil)
        #expect(path.hops.first?.target == "Auto")
        #expect(path.hops.first?.kind == .selection(.fixedOverride))
        #expect(path.hops.contains(ProxySelectionHop(source: "Leaf", target: "Dialer", kind: .dialer)))
        #expect(path.dialerHops == [
            ProxySelectionHop(source: "Leaf", target: "Dialer", kind: .dialer),
            ProxySelectionHop(
                source: "Dialer",
                target: "Dialer Leaf",
                kind: .dialerSelection(.urlTest)
            )
        ])
    }

    @Test("A fixed automatic preference remains an automatic route")
    func fixedAutomaticPreferenceIsNotDeterministic() throws {
        let collection = try makeProxyCollection([
            ProxyTestSpec(
                name: "Auto",
                type: "URLTest",
                all: ["Leaf", "Backup"],
                now: "Leaf",
                fixed: "Leaf"
            ),
            ProxyTestSpec(name: "Leaf", type: "Direct"),
            ProxyTestSpec(name: "Backup", type: "Direct"),
        ])

        let path = ProxySelectionPathResolver().resolve(
            from: "Auto",
            topology: ProxyTopologyBuilder().build(collection: collection)
        )

        #expect(path.hops.first?.kind == .selection(.fixedOverride))
        #expect(path.certainty == .automatic)
        #expect(path.terminal == "Leaf")
    }

    @Test("Dialer failures remain visible without replacing the primary outlet")
    func reportsDialerFailures() throws {
        let unresolvedCollection = try makeProxyCollection([
            ProxyTestSpec(
                name: "Root",
                type: "Selector",
                all: ["Leaf"],
                now: "Leaf"
            ),
            ProxyTestSpec(name: "Leaf", type: "Shadowsocks", dialerProxy: "Missing"),
        ])
        let cyclicCollection = try makeProxyCollection([
            ProxyTestSpec(
                name: "Root",
                type: "Selector",
                all: ["Leaf"],
                now: "Leaf"
            ),
            ProxyTestSpec(name: "Leaf", type: "Shadowsocks", dialerProxy: "Dialer Leaf"),
            ProxyTestSpec(
                name: "Dialer Leaf",
                type: "Shadowsocks",
                dialerProxy: "Leaf"
            ),
        ])
        let balancedCollection = try makeProxyCollection([
            ProxyTestSpec(
                name: "Root",
                type: "Selector",
                all: ["Leaf"],
                now: "Leaf"
            ),
            ProxyTestSpec(name: "Leaf", type: "Shadowsocks", dialerProxy: "Dialer"),
            ProxyTestSpec(
                name: "Dialer",
                type: "LoadBalance",
                all: ["A", "B"],
                now: "A"
            ),
            ProxyTestSpec(name: "A", type: "Direct"),
            ProxyTestSpec(name: "B", type: "Direct"),
        ])

        let unresolved = ProxySelectionPathResolver().resolve(
            from: "Root",
            topology: ProxyTopologyBuilder().build(collection: unresolvedCollection)
        )
        let cyclic = ProxySelectionPathResolver().resolve(
            from: "Root",
            topology: ProxyTopologyBuilder().build(collection: cyclicCollection)
        )
        let balanced = ProxySelectionPathResolver().resolve(
            from: "Root",
            topology: ProxyTopologyBuilder().build(collection: balancedCollection)
        )

        #expect(unresolved.terminal == "Leaf")
        #expect(unresolved.issue == .dialerUnresolvedReference("Missing"))
        #expect(cyclic.terminal == "Leaf")
        #expect(cyclic.issue == .dialerCycle(["Leaf", "Dialer Leaf", "Leaf"]))
        #expect(balanced.terminal == "Leaf")
        #expect(balanced.certainty == .perConnection)
        #expect(
            balanced.issue == .dialerLoadBalance(group: "Dialer", candidates: ["A", "B"])
        )
    }

    @Test("LoadBalance without a fixed override is explicitly per-connection")
    func loadBalanceIsUncertain() throws {
        let collection = try makeProxyCollection([
            ProxyTestSpec(name: "Balance", type: "LoadBalance", all: ["A", "B"], now: "A"),
            ProxyTestSpec(name: "A", type: "Direct"),
            ProxyTestSpec(name: "B", type: "Direct"),
        ])
        let topology = ProxyTopologyBuilder().build(collection: collection)

        let path = ProxySelectionPathResolver().resolve(from: "Balance", topology: topology)

        #expect(path.certainty == .perConnection)
        #expect(path.terminal == nil)
        #expect(path.issue == .loadBalance(group: "Balance", candidates: ["A", "B"]))
    }

    @Test("Selection cycles and unresolved references terminate safely")
    func reportsPathFailures() throws {
        let cyclicCollection = try makeProxyCollection([
            ProxyTestSpec(name: "A", type: "Selector", all: ["B"], now: "B"),
            ProxyTestSpec(name: "B", type: "Fallback", all: ["A"], now: "A"),
        ])
        let unresolvedCollection = try makeProxyCollection([
            ProxyTestSpec(name: "Root", type: "Selector", all: ["Missing"], now: "Missing"),
        ])

        let cyclic = ProxySelectionPathResolver().resolve(
            from: "A",
            topology: ProxyTopologyBuilder().build(collection: cyclicCollection)
        )
        let unresolved = ProxySelectionPathResolver().resolve(
            from: "Root",
            topology: ProxyTopologyBuilder().build(collection: unresolvedCollection)
        )

        #expect(cyclic.issue == .cycle(["A", "B", "A"]))
        #expect(unresolved.issue == .unresolvedReference("Missing"))
    }
}
