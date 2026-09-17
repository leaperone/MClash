import Foundation
import Testing
@testable import MClashApp

struct ConfigurationRuntimeStateTests {
    @Test("Source refresh timestamps and measured latency do not require application")
    func observationMetadataDoesNotChangeRuntime() throws {
        var document = try fixture()
        let workspace = try #require(document.currentWorkspace)
        let original = ConfigurationRuntimeState(document: document, workspaceID: workspace.id)
        document.nodes[0].lastSeenAt = Date()
        document.nodes[0].health.checkedAt = Date()
        document.nodes[0].health.latencyMilliseconds = 25
        document.workspaces[0].revision += 1
        #expect(ConfigurationRuntimeState(document: document, workspaceID: workspace.id) == original)
    }

    @Test("Node credentials, health policies and application rules need application")
    func detectsMClashOwnedPolicies() throws {
        let document = try fixture()
        let workspace = try #require(document.currentWorkspace)
        let original = ConfigurationRuntimeState(document: document, workspaceID: workspace.id)
        var credentials = document
        credentials.nodes[0].parameters["password"] = "rotated"
        #expect(ConfigurationRuntimeState(document: credentials, workspaceID: workspace.id) != original)
        var health = document
        var policy = ProxyGroupPolicySettings()
        policy.probeInterval = 60
        health.proxyGroups[0].healthCheck = policy
        #expect(ConfigurationRuntimeState(document: health, workspaceID: workspace.id) != original)
        var rules = document
        let appRule = RoutingRule(priority: 1, matchers: [.application("example.App")], action: .reject)
        rules.rules.append(appRule)
        rules.workspaces[0].ruleIDs.append(appRule.id)
        #expect(ConfigurationRuntimeState(document: rules, workspaceID: workspace.id) != original)
    }

    @Test("Changes to a separate workspace do not mark the current workspace pending")
    func excludesOtherWorkspace() throws {
        var document = try fixture()
        let workspace = try #require(document.currentWorkspace)
        let original = ConfigurationRuntimeState(document: document, workspaceID: workspace.id)
        let unused = ProxyGroup(name: "Separate", type: .direct)
        document.proxyGroups.append(unused)
        document.workspaces.append(Workspace(name: "Separate", proxyGroupIDs: [unused.id], dnsPolicyID: workspace.dnsPolicyID))
        #expect(ConfigurationRuntimeState(document: document, workspaceID: workspace.id) == original)
    }

    private func fixture() throws -> ConfigurationDocument {
        var document = ConfigurationDocument.mclashDefault()
        document.nodes = [try Node(displayName: "Example", protocol: .http, host: "proxy.example", port: 443)]
        return document
    }
}
