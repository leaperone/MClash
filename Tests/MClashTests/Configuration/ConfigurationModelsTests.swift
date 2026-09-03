import Foundation
import Testing
@testable import MClashApp

struct ConfigurationModelsTests {
    @Test func nodeFingerprintIsStableAcrossPresentationChanges() throws {
        let a = try Node(displayName: "Tokyo", protocol: .vless, host: "EXAMPLE.com.", port: 443, parameters: ["uuid": "abc", "tls": "true"])
        let b = try Node(displayName: "Renamed", protocol: .vless, host: "example.com", port: 443, parameters: ["tls": "true", "uuid": "abc"])
        #expect(a.fingerprint == b.fingerprint)
        #expect(a.host == "example.com")
    }

    @Test func nodeIdentitySurvivesCredentialRotation() throws {
        let old = try Node(displayName: "US 01", protocol: .vless, host: "us.example.com", port: 443, parameters: ["uuid": "old", "password": "old-secret", "tls": "true", "sni": "cdn.example.com"])
        let refreshed = try Node(displayName: "United States", protocol: .vless, host: "us.example.com", port: 443, parameters: ["uuid": "new", "password": "new-secret", "tls": "true", "sni": "cdn.example.com"])
        #expect(NodeIdentity(node: old) == NodeIdentity(node: refreshed))
        #expect(NodeID.stable(for: old.fingerprint) == NodeID.stable(for: refreshed.fingerprint))
    }

    @Test func nodeSourceRevisionIsPersistedAndLegacyManifestsDecode() throws {
        let source = SourceID()
        let node = try Node(
            displayName: "US 01",
            protocol: .vless,
            host: "us.example.com",
            port: 443,
            sourceLinks: [source],
            sourceRevisionByID: [source: 7]
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let roundTrip = try decoder.decode(Node.self, from: encoder.encode(node))
        #expect(roundTrip.sourceLinks == [source])
        #expect(roundTrip.sourceRevisionByID == [source: 7])

        var legacy = try #require(JSONSerialization.jsonObject(with: encoder.encode(node)) as? [String: Any])
        legacy.removeValue(forKey: "sourceRevisionByID")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let decodedLegacy = try decoder.decode(Node.self, from: legacyData)
        #expect(decodedLegacy.sourceLinks == [source])
        #expect(decodedLegacy.sourceRevisionByID.isEmpty)
    }

    @Test func nodeProjectsToConnectorNeutralOutboundTarget() throws {
        let node = try Node(
            displayName: "SOCKS node",
            protocol: .socks5,
            host: "proxy.example.com",
            port: 1080,
            parameters: ["username": "user", "password": "secret"]
        )
        #expect(node.outboundTarget?.protocolName == "socks5")
        #expect(node.outboundTarget?.host == "proxy.example.com")
        #expect(node.outboundTarget?.port == 1080)
    }

    @Test func selectorCombinesPinsAndDynamicIncludeExcludeDeterministically() throws {
        let source = SourceID()
        let us = try Node(displayName: "US 02", protocol: .vless, host: "us-2.example.com", port: 443, sourceLinks: [source])
        let excluded = try Node(displayName: "US backup", protocol: .vless, host: "us-backup.example.com", port: 443, sourceLinks: [source])
        let japan = try Node(displayName: "Japan", protocol: .vless, host: "jp.example.com", port: 443, sourceLinks: [source])
        let selector = NodeSelector(name: "US", include: [.hostContains("us")], exclude: [.nameContains("backup")], fixedNodeIDs: [japan.id])
        let result = NodeSelectorResolver.resolve(selectors: [selector], nodes: [japan, excluded, us])
        #expect(result.nodeIDs == [japan.id, us.id])
        #expect(result.diagnostics.isEmpty)
    }

    @Test func selectorReportsMissingPinsAndStableIdentityCollisions() throws {
        let missing = NodeID()
        let a = try Node(displayName: "A", protocol: .vless, host: "same.example.com", port: 443, parameters: ["uuid": "one"])
        let b = try Node(displayName: "B", protocol: .vless, host: "same.example.com", port: 443, parameters: ["uuid": "two"])
        let selector = NodeSelector(name: "Pinned", fixedNodeIDs: [missing])
        let result = NodeSelectorResolver.resolve(selectors: [selector], nodes: [b, a])
        #expect(result.diagnostics.contains { $0.code == "selector_missing_fixed_node" })
        #expect(result.diagnostics.contains { $0.code == "node_identity_conflict" })
    }

    @Test func fixedPinsSurviveAnExcludeCondition() throws {
        let pinned = try Node(displayName: "US pinned", protocol: .vless, host: "us.example.com", port: 443)
        let selector = NodeSelector(
            name: "US",
            include: [.hostContains("us")],
            exclude: [.nameContains("us")],
            fixedNodeIDs: [pinned.id]
        )
        let result = NodeSelectorResolver.resolve(selectors: [selector], nodes: [pinned])
        #expect(result.nodeIDs == [pinned.id])
    }

    @Test func selectorResolverReportsDuplicateNodeIDsWithoutTrapping() throws {
        let stableID = NodeID()
        let first = try Node(id: stableID, displayName: "First", protocol: .vless, host: "one.example.com", port: 443)
        let second = try Node(id: stableID, displayName: "Second", protocol: .vless, host: "two.example.com", port: 443)
        let result = NodeSelectorResolver.resolve(selectors: [NodeSelector(name: "All")], nodes: [first, second])
        #expect(result.diagnostics.contains { $0.code == "duplicate_node_id" })
        #expect(result.nodeIDs.count == 1)
    }

    @Test func identityNormalizesParameterKeyPresentation() throws {
        let upper = try Node(displayName: "A", protocol: .vless, host: "example.com", port: 443, parameters: ["SNI": "cdn.example.com", "ws_opts": "true"])
        let lower = try Node(displayName: "B", protocol: .vless, host: "example.com", port: 443, parameters: ["sni": "cdn.example.com", "ws-opts": "true"])
        #expect(upper.fingerprint == lower.fingerprint)
    }

    @Test func selectorContainsFieldsAcceptWildcardPatterns() throws {
        let us = try Node(displayName: "US Premium", protocol: .vless, host: "us-01.example.com", port: 443)
        let jp = try Node(displayName: "Japan", protocol: .vless, host: "jp.example.com", port: 443)
        let selector = NodeSelector(name: "US", include: [.nameContains("US*"), .hostContains("us-*")])
        let resolution = NodeSelectorResolver.resolve(selectors: [selector], nodes: [us, jp])
        #expect(resolution.nodeIDs == [us.id])
    }

    @Test func defaultConfigurationUsesAWholeCatalogSelector() {
        let document = ConfigurationDocument.mclashDefault()
        #expect(document.currentWorkspace?.nodeIDs.isEmpty == true)
        #expect(document.proxyGroups.first?.memberSelectors.count == 1)
        #expect(document.proxyGroups.first?.members.isEmpty == true)
    }

    @Test func mihomoRuleAcceptsLargeDomainMatcherListWithinExpansionBudget() throws {
        var document = ConfigurationDocument.mclashDefault()
        let group = try #require(document.proxyGroups.first)
        let domains = (0..<2_882).map {
            RoutingMatcher.domainSuffix("service-\($0).example.com")
        }
        let rule = RoutingRule(
            priority: 10,
            matchers: domains + [.transport("tcp")],
            action: .proxyGroup(group.id)
        )
        document.rules = [rule]
        document.workspaces[0].ruleIDs = [rule.id]

        let diagnostics = ConfigurationValidator.automationPlanDiagnostics(document: document)
        #expect(!diagnostics.contains { $0.severity == .error })

        let compiled = try ConfigurationCompiler().compile(document: document)
        #expect(compiled.yaml.count < ConfigurationAutomationLimits.compiledYAMLBytes)
        let yaml = String(decoding: compiled.yaml, as: UTF8.self)
        #expect(yaml.contains("DOMAIN-SUFFIX,service-2881.example.com"))
        #expect(yaml.contains("AND,((DOMAIN-SUFFIX"))
    }

    @Test func mihomoRuleRejectsOnlyGenuinelyExcessiveMatcherList() throws {
        var document = ConfigurationDocument.mclashDefault()
        let group = try #require(document.proxyGroups.first)
        let domains = (0...ConfigurationAutomationLimits.ruleMatchers).map {
            RoutingMatcher.domainSuffix("service-\($0).example.com")
        }
        let rule = RoutingRule(
            priority: 10,
            matchers: domains,
            action: .proxyGroup(group.id)
        )
        document.rules = [rule]
        document.workspaces[0].ruleIDs = [rule.id]

        let diagnostics = ConfigurationValidator.automationPlanDiagnostics(document: document)
        #expect(diagnostics.contains {
            $0.severity == .error && $0.code == "configuration_resource_limit"
        })
    }

    @Test func proxyGroupWithoutNewSelectorFieldRemainsCodableCompatible() throws {
        let group = ProxyGroup(name: "US", members: [])
        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(ProxyGroup.self, from: data)
        #expect(decoded.memberSelectors.isEmpty)
    }

    @Test func validatorProducesDeterministicDependencyDiagnostics() throws {
        let dnsID = DNSPolicyID(); let missing = NodeID()
        let workspace = Workspace(name: "Test", nodeIDs: [missing], dnsPolicyID: dnsID)
        let diagnostics = ConfigurationValidator.validate(workspace: workspace, nodes: [], groups: [], rules: [], dnsPolicies: [], entrances: [])
        #expect(diagnostics.map(\.code) == ["missing_dns_policy", "missing_node"])
    }

    @Test func validatorAndCompilerKeepMultipleEnabledHTTPEntrances() throws {
        let dns = DNSPolicy(name: "DNS")
        let first = Entrance(name: "HTTP Browser", kind: .http, enabled: true, port: 7890)
        let second = Entrance(name: "HTTP Tools", kind: .http, enabled: true, port: 7892)
        let workspace = Workspace(
            name: "Everyday",
            dnsPolicyID: dns.id,
            entranceIDs: [first.id, second.id]
        )
        let diagnostics = ConfigurationValidator.validate(
            workspace: workspace,
            nodes: [],
            groups: [],
            rules: [],
            dnsPolicies: [dns],
            entrances: [first, second]
        )
        #expect(!diagnostics.contains { $0.code == "duplicate_entrance_kind" })
        let document = ConfigurationDocument(
            proxyGroups: [],
            dnsPolicies: [dns],
            entrances: [first, second],
            workspaces: [workspace],
            currentWorkspaceID: workspace.id
        )
        let yaml = String(
            decoding: try ConfigurationCompiler().compile(document: document).yaml,
            as: UTF8.self
        )
        #expect(yaml.contains("name: \"HTTP Browser\""))
        #expect(yaml.contains("name: \"HTTP Tools\""))
        #expect(yaml.contains("port: 7890"))
        #expect(yaml.contains("port: 7892"))
    }

    @Test func modelsRoundTripCodable() throws {
        let dns = DNSPolicy(name: "System")
        let workspace = Workspace(name: "Daily", dnsPolicyID: dns.id)
        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(decoded == workspace)
    }
}
