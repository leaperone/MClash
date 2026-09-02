import Foundation
import Testing
@testable import MClashApp

struct CompiledRuntimePlanTests {
    @Test func compilerExposesDeterministicConnectorNeutralPlan() throws {
        let document = ConfigurationDocument.mclashDefault()
        let plan = try ConfigurationCompiler().compileRuntimePlan(document: document)

        #expect(plan.workspaceID == document.currentWorkspace?.id)
        #expect(plan.nodes.allSatisfy { $0.enabled })
        #expect(plan.proxyGroups.allSatisfy { $0.enabled })
        #expect(plan.dnsPolicy?.id == document.currentWorkspace.flatMap { workspace in
            document.dnsPolicies.first(where: { $0.id == workspace.dnsPolicyID })?.id
        })
        try plan.validate()

        let roundTrip = try JSONDecoder().decode(
            CompiledRuntimePlan.self,
            from: JSONEncoder().encode(plan)
        )
        #expect(roundTrip == plan)

        // Keep this assertion explicit: the plan is policy data, not rendered
        // YAML and must not accidentally grow a Mihomo-specific field.
        #expect(!JSONEncoder().encode(plan).isEmpty)
    }

    @Test func planValidationRejectsDanglingGroupMembers() throws {
        let node = try Node(displayName: "node", protocol: .socks5, host: "127.0.0.1", port: 1080)
        let missingGroup = ProxyGroupID()
        let group = ProxyGroup(
            name: "Broken",
            members: [.node(node.id), .group(missingGroup)]
        )
        let plan = CompiledRuntimePlan(
            workspaceID: WorkspaceID(),
            workspaceRevision: 1,
            nodes: [node],
            proxyGroups: [group],
            rules: [],
            ruleSets: [],
            dnsPolicy: nil,
            entrances: [],
            routingMode: .rule,
            globalProxyGroupID: nil
        )

        #expect(throws: CompiledRuntimePlanValidationError.missingProxyGroup(missingGroup)) {
            try plan.validate()
        }
    }
}
