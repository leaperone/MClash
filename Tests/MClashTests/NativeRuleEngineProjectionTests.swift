import Foundation
import MClashNetworkShared
import Testing
@testable import MClashApp

struct NativeRuleEngineProjectionTests {
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
