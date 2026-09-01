import Foundation
import Testing
@testable import MClashApp

struct ConfigurationProxyGroupPresetTests {
    @Test("Common strategy preset creates a stable nested group hierarchy")
    func createsNestedHierarchyAndRedirectsProxyRules() throws {
        var document = ConfigurationDocument.mclashDefault()
        let cunoe = Source(kind: .subscription, displayName: "CUNOE-Proxy")
        let other = Source(kind: .subscription, displayName: "Other subscription")
        document.sources = [cunoe, other]
        document.nodes = [
            try Node(
                displayName: "🇺🇸 US primary",
                protocol: .vless,
                host: "us.example.com",
                port: 443,
                sourceLinks: [cunoe.id]
            ),
            try Node(
                displayName: "🇯🇵 日本 backup",
                protocol: .vless,
                host: "jp.example.com",
                port: 443,
                sourceLinks: [cunoe.id]
            ),
            try Node(
                displayName: "🇭🇰 香港 backup",
                protocol: .vless,
                host: "hk.example.com",
                port: 443,
                sourceLinks: [cunoe.id]
            ),
            try Node(
                displayName: "🇺🇸 US from another source",
                protocol: .vless,
                host: "other.example.com",
                port: 443,
                sourceLinks: [other.id]
            ),
        ]
        let originalGroup = try #require(document.proxyGroups.first)
        let proxyRule = RoutingRule(
            priority: 10,
            matchers: [.domainSuffix("example.com")],
            action: .proxyGroup(originalGroup.id)
        )
        let directRule = RoutingRule(
            priority: 20,
            matchers: [.domainSuffix("internal.example")],
            action: .direct
        )
        document.rules = [proxyRule, directRule]
        document.workspaces[0].ruleIDs = [proxyRule.id, directRule.id]

        let first = try ConfigurationProxyGroupPreset.apply(to: document)
        let second = try ConfigurationProxyGroupPreset.apply(to: first.document)
        let main = try #require(first.document.proxyGroups.first(where: {
            $0.id == first.mainGroupID
        }))

        #expect(main.name == ConfigurationProxyGroupPreset.mainGroupName)
        #expect(main.type == .select)
        #expect(main.members.count == 8)
        #expect(first.createdGroupCount == 8)
        #expect(first.redirectedRuleCount == 0)
        #expect(second.createdGroupCount == 0)
        #expect(second.redirectedRuleCount == 0)
        #expect(second.document.proxyGroups.count == first.document.proxyGroups.count)
        #expect(second.document.currentWorkspace?.proxyGroupIDs.first == first.mainGroupID)
        #expect(second.document.rules.first(where: { $0.id == directRule.id })?.action == .direct)

        let compiled = try ConfigurationCompiler().compile(document: second.document)
        let yaml = String(decoding: compiled.yaml, as: UTF8.self)
        #expect(yaml.contains("name: \"🚀 节点选择\""))
        #expect(yaml.contains("\"🇺🇸 美国优先\""))
        #expect(yaml.contains("DOMAIN-SUFFIX,example.com,🚀 节点选择"))
        #expect(!yaml.contains("MClash Select"))

        let regionalGroups = [
            ConfigurationProxyGroupPreset.hongKongGroupName,
            ConfigurationProxyGroupPreset.unitedStatesGroupName,
            ConfigurationProxyGroupPreset.japanGroupName,
        ]
        for name in regionalGroups {
            let group = try #require(second.document.proxyGroups.first(where: { $0.name == name }))
            let resolved = NodeSelectorResolver.resolve(selectors: group.memberSelectors, nodes: second.document.nodes)
            #expect(resolved.nodeIDs.count == Set(resolved.nodeIDs).count)
            #expect(!resolved.nodeIDs.contains(where: { $0 == second.document.nodes[3].id }))
        }
        let us = try #require(second.document.proxyGroups.first(where: {
            $0.name == ConfigurationProxyGroupPreset.unitedStatesGroupName
        }))
        let usNodes = NodeSelectorResolver.resolve(selectors: us.memberSelectors, nodes: second.document.nodes).nodeIDs
        #expect(usNodes == [second.document.nodes[0].id])
    }

    @Test("Regional selectors are source-scoped and remain empty without CUNOE")
    func regionalSelectorsDoNotImportOtherSources() throws {
        var document = ConfigurationDocument.mclashDefault()
        let source = Source(kind: .subscription, displayName: "Other")
        document.sources = [source]
        document.nodes = [try Node(
            displayName: "🇺🇸 US",
            protocol: .vless,
            host: "us.example.com",
            port: 443,
            sourceLinks: [source.id]
        )]
        let result = try ConfigurationProxyGroupPreset.apply(to: document)
        let groups = result.document.proxyGroups.filter {
            [ConfigurationProxyGroupPreset.hongKongGroupName,
             ConfigurationProxyGroupPreset.unitedStatesGroupName,
             ConfigurationProxyGroupPreset.japanGroupName].contains($0.name)
        }
        #expect(groups.allSatisfy {
            NodeSelectorResolver.resolve(selectors: $0.memberSelectors, nodes: result.document.nodes).nodeIDs.isEmpty
        })
    }

    @Test("A shared proxy rule is cloned before redirecting one configuration")
    func sharedRulesAreNotRewrittenForOtherWorkspaces() throws {
        var document = ConfigurationDocument.mclashDefault()
        document.nodes = [
            try Node(
                displayName: "US",
                protocol: .vless,
                host: "us.example.com",
                port: 443
            ),
        ]
        let originalGroup = try #require(document.proxyGroups.first)
        let sourceGroup = ProxyGroup(
            name: "Source-specific group",
            type: .select,
            memberSelectors: [NodeSelector(name: "All source nodes")]
        )
        document.proxyGroups.append(sourceGroup)
        let sharedRule = RoutingRule(
            priority: 10,
            action: .proxyGroup(sourceGroup.id)
        )
        document.rules = [sharedRule]
        document.workspaces[0].proxyGroupIDs.append(sourceGroup.id)
        document.workspaces[0].ruleIDs = [sharedRule.id]
        let secondWorkspace = Workspace(
            name: "Second",
            proxyGroupIDs: [originalGroup.id, sourceGroup.id],
            ruleIDs: [sharedRule.id],
            dnsPolicyID: document.workspaces[0].dnsPolicyID,
            entranceIDs: document.workspaces[0].entranceIDs
        )
        document.workspaces.append(secondWorkspace)

        let result = try ConfigurationProxyGroupPreset.apply(
            to: document,
            workspaceID: document.workspaces[0].id
        )
        let firstWorkspaceRuleID = try #require(result.document.workspaces.first?.ruleIDs.first)
        let presetIDs = Set(result.document.proxyGroups.filter {
            ConfigurationProxyGroupPreset.groupNames.contains($0.name)
        }.map(\.id))

        #expect(firstWorkspaceRuleID != sharedRule.id)
        #expect(result.redirectedRuleCount == 1)
        #expect(result.document.workspaces[1].ruleIDs == [sharedRule.id])
        #expect(Set(result.document.workspaces[1].proxyGroupIDs).isSuperset(of: presetIDs))
        #expect(
            result.document.rules.first(where: { $0.id == sharedRule.id })?.action
                == .proxyGroup(sourceGroup.id)
        )
        #expect(
            result.document.rules.first(where: { $0.id == firstWorkspaceRuleID })?.action
                == .proxyGroup(result.mainGroupID)
        )
        _ = try ConfigurationCompiler().compile(
            document: result.document,
            workspaceID: secondWorkspace.id
        )
    }
}
