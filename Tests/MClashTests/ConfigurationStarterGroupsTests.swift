import Foundation
import Testing
@testable import MClashApp

struct ConfigurationStarterGroupsTests {
    @Test("Starter groups include arbitrary sources and follow later node additions")
    func includesCurrentAndFutureNodes() throws {
        var document = ConfigurationDocument.mclashDefault()
        document.rules = []
        document.workspaces[0].ruleIDs = []
        let first = try Node(displayName: "Sydney", protocol: .http, host: "first.example", port: 443)
        document.nodes = [first]
        var result = try ConfigurationStarterGroups.apply(to: document)
        let second = try Node(displayName: "Other source", protocol: .http, host: "second.example", port: 443)
        result.document.nodes.append(second)
        let workspace = try #require(result.document.currentWorkspace)
        let plan = try XrayConfigurationCompiler.compile(document: result.document, workspaceID: workspace.id,
                                                        inbounds: [], apiSocketPath: "/tmp/starter-test.sock")
        for type in [ProxyGroupType.select, .urlTest, .fallback] {
            let id = ConfigurationStarterGroups.groupID(type, workspaceID: workspace.id)
            let group = try #require(plan.groups.first { $0.id == id })
            #expect(Set(group.members) == [.node(first.id), .node(second.id)])
        }
        #expect(result.createdGroupCount == 3)
        #expect(ConfigurationStarterGroups.isInstalled(in: result.document))
    }

    @Test("Installation preserves custom groups, rules, entrances and current routing targets")
    func preservesExistingChoices() throws {
        var document = ConfigurationDocument.mclashDefault()
        let node = try Node(displayName: "Node", protocol: .http, host: "example.test", port: 443)
        document.nodes = [node]
        let custom = ProxyGroup(name: AppLocalization.string("Select"), members: [.node(node.id)])
        document.proxyGroups.append(custom)
        document.workspaces[0].proxyGroupIDs.append(custom.id)
        document.workspaces[0].globalProxyGroupID = custom.id
        let rule = RoutingRule(priority: 0, matchers: [.domainSuffix("example.test")], action: .proxyGroup(custom.id))
        document.rules.append(rule)
        document.workspaces[0].ruleIDs.append(rule.id)
        document.entrances[0].defaultAction = .proxyGroup(custom.id)

        let result = try ConfigurationStarterGroups.apply(to: document)

        #expect(result.document.rules == document.rules)
        #expect(result.document.entrances == document.entrances)
        #expect(result.document.currentWorkspace?.globalProxyGroupID == custom.id)
        #expect(result.document.proxyGroups.first { $0.id == custom.id } == custom)
        #expect(Set(result.document.proxyGroups.map(\.name)).count == result.document.proxyGroups.count)
        #expect(result.redirectedRuleCount == 0)
    }

    @Test("Reinstalling a starter setup preserves user edits and does not change the document")
    func repeatedInstallPreservesEdits() throws {
        var document = try ConfigurationStarterGroups.apply(to: .mclashDefault()).document
        let workspace = try #require(document.currentWorkspace)
        let id = ConfigurationStarterGroups.groupID(.urlTest, workspaceID: workspace.id)
        let index = try #require(document.proxyGroups.firstIndex { $0.id == id })
        document.proxyGroups[index].name = "My automatic group"
        document.proxyGroups[index].enabled = false

        let result = try ConfigurationStarterGroups.apply(to: document)

        #expect(result.document == document)
        #expect(result.createdGroupCount == 0)
    }
}
