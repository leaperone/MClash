import Foundation
import Testing
@testable import MClashApp

struct ConfigurationOrchestrationTests {
    @Test func configurationStoreRoundTripsAndQuarantinesMalformedState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MClashConfigurationStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ProfileDirectoryLayout(rootDirectory: root)
        let store = try ConfigurationStore(layout: layout)
        let document = ConfigurationDocument.mclashDefault()
        try await store.save(document)
        #expect(try await store.load() == document)
        try Data("not-json".utf8).write(to: layout.configurationManifestURL, options: [.atomic])
        let recovery = try await store.loadRecoveringInvalidDocument()
        #expect(recovery.document == .empty)
        #expect(recovery.quarantinedURL != nil)
        #expect(recovery.quarantinedURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func nodeOnlyImporterIgnoresSourceStrategySectionsAndDeduplicates() throws {
        let sourceID = SourceID()
        let yaml = """
        proxies:
          - {name: Tokyo, type: vless, server: EXAMPLE.com., port: 443, uuid: abc, tls: true}
          - name: Tokyo renamed
            type: vless
            server: example.com
            port: 443
            uuid: abc
            tls: true
        proxy-groups:
          - name: Provider-owned
            type: select
            proxies: [Tokyo]
        rules:
          - DOMAIN-SUFFIX,example.com,Provider-owned
        dns:
          enable: true
        tun:
          enable: true
        """
        let report = NodeOnlyImporter().importNodes(sourceID: sourceID, yaml: Data(yaml.utf8))
        // The two entries have the same connection identity; only one reaches
        // the authoritative node catalog.
        #expect(report.nodes.count == 1)
        #expect(report.ignoredSections == ["proxy-groups", "rules", "dns", "tun"])
        #expect(report.diagnostics.contains { $0.code == "duplicate_node" })
        #expect(report.diagnostics.contains { $0.code == "strategy_sections_ignored" })
    }

    @Test func compilerStartsFromBlankDocumentAndIncludesOnlyWorkspacePolicy() throws {
        let sourceID = SourceID()
        let node = try Node(
            displayName: "Tokyo",
            protocol: .vless,
            host: "example.com",
            port: 443,
            parameters: ["uuid": "abc", "tls": "true"],
            sourceLinks: [sourceID]
        )
        let group = ProxyGroup(name: "Japan", type: .select, members: [.node(node.id)])
        let dns = DNSPolicy(name: "MClash DNS", mode: .fakeIP, nameservers: ["1.1.1.1"])
        let entrance = Entrance(kind: .socks5, enabled: true, port: 7891, defaultAction: .proxyGroup(group.id))
        let workspace = Workspace(name: "AI", nodeIDs: [node.id], proxyGroupIDs: [group.id], dnsPolicyID: dns.id, entranceIDs: [entrance.id])
        let document = ConfigurationDocument(nodes: [node], proxyGroups: [group], dnsPolicies: [dns], entrances: [entrance], workspaces: [workspace], currentWorkspaceID: workspace.id)
        let compiled = try ConfigurationCompiler().compile(document: document)
        let output = String(decoding: compiled.yaml, as: UTF8.self)
        #expect(output.contains("proxy-groups:"))
        #expect(output.contains("Japan"))
        #expect(output.contains("enhanced-mode: fake-ip"))
        #expect(!output.contains("Provider-owned"))
        #expect(compiled.workspaceID == workspace.id)
    }

    @Test func compilerExpandsSelectorBackedGroupsAgainstAnImplicitCatalogScope() throws {
        let first = try Node(displayName: "US 01", protocol: .vless, host: "us-1.example.com", port: 443)
        let second = try Node(displayName: "US 02", protocol: .vless, host: "us-2.example.com", port: 443)
        let group = ProxyGroup(
            name: "United States",
            type: .select,
            memberSelectors: [NodeSelector(name: "US", include: [.nameContains("US")])]
        )
        let dns = DNSPolicy(name: "MClash DNS")
        let entrance = Entrance(kind: .socks5, enabled: true, port: 7891, defaultAction: .proxyGroup(group.id))
        // Empty nodeIDs deliberately means all enabled catalog nodes.
        let workspace = Workspace(name: "Everyday", proxyGroupIDs: [group.id], dnsPolicyID: dns.id, entranceIDs: [entrance.id])
        let document = ConfigurationDocument(
            nodes: [first, second],
            proxyGroups: [group],
            dnsPolicies: [dns],
            entrances: [entrance],
            workspaces: [workspace],
            currentWorkspaceID: workspace.id
        )
        let output = String(decoding: try ConfigurationCompiler().compile(document: document).yaml, as: UTF8.self)
        #expect(output.contains("us-1.example.com"))
        #expect(output.contains("us-2.example.com"))
    }
}
