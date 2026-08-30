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

    @Test func validatorRejectsMultipleEnabledListenersOfOneType() throws {
        let dns = DNSPolicy(name: "DNS")
        let first = Entrance(kind: .http, enabled: true, port: 7890)
        let second = Entrance(kind: .http, enabled: true, port: 7892)
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
        #expect(diagnostics.contains { $0.code == "duplicate_entrance_kind" })
    }

    @Test func modelsRoundTripCodable() throws {
        let dns = DNSPolicy(name: "System")
        let workspace = Workspace(name: "Daily", dnsPolicyID: dns.id)
        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        #expect(decoded == workspace)
    }
}
