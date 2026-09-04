import Foundation
import MClashNetworkShared
import Testing
@testable import MClashApp

struct NativeRuleEngineProjectionTests {
    @Test("native GEO capability gate rejects GEO rules without a ready provider")
    func nativeGeoCapabilityGate() throws {
        let plan = plan(
            groups: [],
            rules: [RoutingRule(priority: 1, matchers: [.geoSite("gfw")], action: .direct)]
        )
        #expect(throws: NativeGeoCapabilityError.providerNotReady(.unavailable)) {
            try NativeGeoCapabilityGate.validate(plan: plan, providerStatus: nil, enforce: true)
        }
        try NativeGeoCapabilityGate.validate(
            plan: plan,
            providerStatus: .ready(revision: "fixture"),
            enforce: true
        )
        try NativeGeoCapabilityGate.validate(plan: plan, providerStatus: nil, enforce: false)
    }

    @Test("v2fly GeoIP protobuf fixture matches country CIDR")
    func geoIPProtobufFixture() throws {
        let cidr = Data([0x0a, 0x04, 192, 0, 2, 0, 0x10, 0x08])
        let entry = Data([0x0a, 0x02]) + Data("CN".utf8) + Data([0x12, UInt8(cidr.count)]) + cidr
        let database = try NativeGeoIPDatabaseProvider(data: Data([0x0a, UInt8(entry.count)]) + entry)
        let context = FlowContext(source: FlowSource(processIdentifier: 1, auditToken: Data(), userID: 501), destination: try FlowDestination(ipAddress: IPAddress("192.0.2.42"), port: 443), transportProtocol: .tcp)
        #expect(database.matches(kind: .ip, value: "cn", context: context))
        #expect(!database.matches(kind: .site, value: "cn", context: context))
    }

    @Test("bundled v2fly GeoIP data parses when an integration fixture is supplied")
    func bundledGeoIPData() throws {
        guard let path = ProcessInfo.processInfo.environment["MCLASH_GEOIP_DAT_PATH"] else {
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let database = try NativeGeoIPDatabaseProvider(data: data)
        let context = FlowContext(
            source: FlowSource(processIdentifier: 1, auditToken: Data(), userID: 501),
            destination: try FlowDestination(
                ipAddress: IPAddress("223.5.5.5"),
                port: 53
            ),
            transportProtocol: .udp
        )
        #expect(database.status != .unavailable)
        #expect(database.entryCount > 0)
        #expect(database.matches(kind: .ip, value: "CN", context: context))
    }

    @Test("native rule-set support distinguishes inline data from external providers")
    func ruleSetSupportGate() {
        #expect(NativeRuleSetSupport.assess(RuleSet(name: "inline", rules: ["DOMAIN,example.com"])) == .inline)
        #expect(NativeRuleSetSupport.assess(RuleSet(name: "remote", sourceURL: URL(string: "https://rules.example/set"))) == .externalRequiresLoader)
        #expect(NativeRuleSetSupport.assess(RuleSet(name: "file", format: .text, path: "/tmp/rules.txt")) == .localText)
    }

    @Test("native text rule-set loader strips comments and blank lines")
    func loadsClassicalTextRuleSet() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mclash-rules-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("# header\nexample.com\n||example.org^ # note\n203.0.113.0/24\n\n".utf8).write(to: url)
        let set = RuleSet(name: "local", format: .text, path: url.path)
        #expect(try NativeRuleSetFileLoader.load(set) == [
            "DOMAIN-SUFFIX,example.com",
            "DOMAIN-SUFFIX,example.org",
            "IP-CIDR,203.0.113.0/24"
        ])
        #expect(throws: NativeRuleSetFileLoader.Error.unsupportedSource) {
            try NativeRuleSetFileLoader.load(RuleSet(name: "yaml", format: .yaml, path: url.path))
        }
    }

    @Test("native text refresher accepts HTTPS only and atomically caches content")
    func textRefresherHTTPSGate() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("mclash-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let httpSet = RuleSet(name: "http", sourceURL: URL(string: "http://rules.example/set"), format: .text)
        let refresher = NativeTextRuleSetRefresher(cacheDirectory: cache)
        await #expect(throws: NativeRuleSetFileLoader.Error.unsupportedSource) {
            try await refresher.refresh(httpSet)
        }
    }

    @Test("native projection evaluates a local text rule set")
    func evaluatesLocalTextRuleSet() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mclash-native-rules-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("||blocked.example^\n".utf8).write(to: url)
        let group = ProxyGroup(name: "Proxy")
        let ruleSet = RuleSet(
            name: "local-gfw",
            defaultAction: .proxyGroup(group.id),
            format: .text,
            path: url.path
        )
        let runtime = plan(groups: [group], ruleSets: [ruleSet])
        let decision = NativeRuleEngineProjection(plan: runtime)
            .evaluate(try context("www.blocked.example"))
        #expect(decision.action == .outbound(group.id))
        #expect(decision.matchedRuleSetID == ruleSet.id)
    }

    @Test("native projection honors direct and reject actions")
    func directAndReject() throws {
        let group = ProxyGroup(name: "Proxy")
        let direct = RoutingRule(priority: 10, matchers: [.domainExact("local.example")], action: .direct)
        let reject = RoutingRule(priority: 20, matchers: [.domainSuffix("blocked.example")], action: .reject)
        let projection = NativeRuleEngineProjection(plan: plan(groups: [group], rules: [direct, reject]))

        #expect(projection.evaluate(try context("local.example")).action == .direct)
        #expect(projection.evaluate(try context("www.blocked.example")).action == .reject)
        #expect(projection.evaluate(try context("other.example")).action == .direct)
    }

    @Test("native projection maps global mode to the configured outbound group")
    func globalMode() throws {
        let group = ProxyGroup(name: "Global")
        let runtime = plan(groups: [group], routingMode: .global, globalGroup: group.id)
        let decision = NativeRuleEngineProjection(plan: runtime).evaluate(try context("example.com"))
        #expect(decision.action == .outbound(group.id))
    }

    @Test("native projection fails safe to Direct when Global exit is absent")
    func globalModeWithoutExitIsDirect() throws {
        let runtime = plan(groups: [], routingMode: .global, globalGroup: ProxyGroupID())
        #expect(NativeRuleEngineProjection(plan: runtime)
            .evaluate(try context("example.com")).action == .direct)
    }

    @Test("native projection uses Direct for explicit Direct mode and rule miss")
    func directModeAndRuleMissAreDirect() throws {
        let directRuntime = plan(groups: [], routingMode: .direct)
        #expect(NativeRuleEngineProjection(plan: directRuntime)
            .evaluate(try context("example.com")).action == .direct)
        let ruleRuntime = plan(
            groups: [ProxyGroup(name: "Proxy")],
            rules: [RoutingRule(priority: 10, matchers: [.domainExact("only.example")], action: .reject)]
        )
        #expect(NativeRuleEngineProjection(plan: ruleRuntime)
            .evaluate(try context("other.example")).action == .direct)
    }

    @Test("native projection resolves GEO and nested rule-set references")
    func geoAndRuleSetReference() throws {
        let group = ProxyGroup(name: "Proxy")
        let nested = RuleSet(name: "gfw", rules: ["GEOSITE,gfw"])
        let wrapper = RuleSet(name: "wrapper", rules: ["RULE-SET,gfw"], defaultAction: .proxyGroup(group.id))
        let runtime = plan(groups: [group], ruleSets: [wrapper, nested])
        let projection = NativeRuleEngineProjection(
            plan: runtime,
            geoMatcher: { kind, value, context in
                kind == .site && value == "gfw" && context.destination.hostname == "blocked.example"
            }
        )
        let decision = projection.evaluate(try context("blocked.example"))
        #expect(decision.action == .outbound(group.id))
        #expect(decision.matchedRuleSetID == wrapper.id)
    }

    @Test("native rule sets preserve explicit GEO targets and no-resolve parameters")
    func ruleSetExplicitTargets() throws {
        let proxy = ProxyGroup(name: "Proxy")
        let geo = RuleSet(
            name: "domestic",
            rules: [
                "GEOSITE,cn,DIRECT",
                "GEOIP,CN,Proxy,no-resolve"
            ],
            defaultAction: .proxyGroup(proxy.id)
        )
        let runtime = plan(groups: [proxy], ruleSets: [geo])
        let expectedIP = try IPAddress("203.0.113.8")
        let matcher: NativeGeoMatcher = { kind, value, context in
            (kind == .site && value == "cn" && context.destination.hostname == "cn.example")
                || (kind == .ip && value == "CN" && context.destination.ipAddress == expectedIP)
        }
        let projection = NativeRuleEngineProjection(plan: runtime, geoMatcher: matcher)
        #expect(projection.evaluate(try context("cn.example")).action == .direct)
        let ipContext = FlowContext(
            source: FlowSource(processIdentifier: 1, auditToken: Data(), userID: 501),
            destination: try FlowDestination(ipAddress: IPAddress("203.0.113.8"), port: 443),
            transportProtocol: .tcp
        )
        #expect(projection.evaluate(ipContext).action == .outbound(proxy.id))
    }

    private func plan(
        groups: [ProxyGroup],
        rules: [RoutingRule] = [],
        ruleSets: [RuleSet] = [],
        routingMode: ConfigurationRoutingMode = .rule,
        globalGroup: ProxyGroupID? = nil
    ) -> CompiledRuntimePlan {
        CompiledRuntimePlan(
            workspaceID: WorkspaceID.stable(for: "native-projection-tests"),
            workspaceRevision: 1,
            nodes: [],
            proxyGroups: groups,
            rules: rules,
            ruleSets: ruleSets,
            dnsPolicy: nil,
            entrances: [],
            routingMode: routingMode,
            globalProxyGroupID: globalGroup
        )
    }

    private func context(_ hostname: String) throws -> FlowContext {
        FlowContext(
            source: FlowSource(processIdentifier: 1, auditToken: Data(), userID: 501),
            destination: try FlowDestination(hostname: hostname, port: 443),
            transportProtocol: .tcp
        )
    }
}
