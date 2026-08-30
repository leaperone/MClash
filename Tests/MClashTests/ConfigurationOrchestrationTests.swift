import Foundation
import Testing
@testable import MClashApp

struct ConfigurationOrchestrationTests {
    @MainActor
    @Test func sourceRefreshKeepsPriorNodesWhenParsingDegradesOrReadFails() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "MClashSourceRefresh-(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ProfileDirectoryLayout(rootDirectory: root)
        try layout.createDirectories()
        let profileStore = try ProfileStore(layout: layout)
        let validYAML = """
        proxies:
          - name: Stable US
            type: vless
            server: us.example.com
            port: 443
            uuid: rotating-secret
        """
        let profile = try await profileStore.createLocalProfile(
            name: "Refresh fixture",
            yaml: Data(validYAML.utf8)
        )
        let defaultsName = "MClash.ConfigurationOrchestration.(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(false, forKey: AppModel.autoConnectOnLaunchKey)
        defaults.set(false, forKey: AppModel.connectionDesiredOnLaunchKey)
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = makeTestAppModel(
            profileDirectoryLayout: layout,
            profileStoreOverride: profileStore,
            preferenceDefaults: defaults
        )

        await model.synchronizeConfigurationSources()
        let sourceID = SourceID(rawValue: profile.id.rawValue)
        let firstNode = try #require(model.configurationDocument.nodes.first)
        #expect(firstNode.sourceLinks.contains(sourceID))
        #expect(firstNode.health.availability == .available)

        let unsupportedYAML = """
        proxies:
          - name: Future protocol
            type: quic
            server: us.example.com
            port: 443
        """
        try Data(unsupportedYAML.utf8).write(
            to: layout.configurationURL(for: profile.id),
            options: .atomic
        )
        await model.synchronizeConfigurationSources()
        let degradedNode = try #require(
            model.configurationDocument.nodes.first(where: { $0.id == firstNode.id })
        )
        #expect(degradedNode.sourceLinks.contains(sourceID))
        #expect(degradedNode.health.availability == .available)
        let degradedSource = try #require(
            model.configurationDocument.sources.first(where: { $0.id == sourceID })
        )
        #expect(degradedSource.parseDiagnostics.filter { $0.code == "source_refresh_degraded" }.count == 1)

        try FileManager.default.removeItem(at: layout.configurationURL(for: profile.id))
        await model.synchronizeConfigurationSources()
        let failedNode = try #require(
            model.configurationDocument.nodes.first(where: { $0.id == firstNode.id })
        )
        #expect(failedNode.sourceLinks.contains(sourceID))
        #expect(failedNode.health.availability == .available)
        let failedSource = try #require(
            model.configurationDocument.sources.first(where: { $0.id == sourceID })
        )
        #expect(failedSource.parseDiagnostics.filter { $0.code == "source_read_failed" }.count == 1)
        #expect(Set(model.configurationDiagnostics.map(\.id)).count == model.configurationDiagnostics.count)
    }

    @MainActor
    @Test func sourcesWithOneEndpointButDifferentCredentialsStayDistinct() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "MClashSourceIdentityConflict-(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ProfileDirectoryLayout(rootDirectory: root)
        try layout.createDirectories()
        let profileStore = try ProfileStore(layout: layout)
        func yaml(_ credential: String) -> Data {
            Data("""
            proxies:
              - name: Shared endpoint
                type: vless
                server: shared.example.com
                port: 443
                uuid: \(credential)
            """.utf8)
        }
        let first = try await profileStore.createLocalProfile(name: "Account A", yaml: yaml("account-a"))
        let second = try await profileStore.createLocalProfile(name: "Account B", yaml: yaml("account-b"))
        let defaultsName = "MClash.ConfigurationIdentity.(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.set(false, forKey: AppModel.autoConnectOnLaunchKey)
        defaults.set(false, forKey: AppModel.connectionDesiredOnLaunchKey)
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = makeTestAppModel(
            profileDirectoryLayout: layout,
            profileStoreOverride: profileStore,
            preferenceDefaults: defaults
        )

        await model.synchronizeConfigurationSources()
        let firstSourceID = SourceID(rawValue: first.id.rawValue)
        let secondSourceID = SourceID(rawValue: second.id.rawValue)
        let initialNodes = model.configurationDocument.nodes.filter {
            $0.sourceLinks.contains(firstSourceID) || $0.sourceLinks.contains(secondSourceID)
        }
        #expect(initialNodes.count == 2)
        #expect(Set(initialNodes.map(\.id)).count == 2)
        #expect(initialNodes.allSatisfy { $0.sourceLinks.count == 1 })

        let secondNodeID = try #require(
            initialNodes.first(where: { $0.sourceLinks.contains(secondSourceID) })?.id
        )
        try yaml("account-b-rotated").write(
            to: layout.configurationURL(for: second.id),
            options: .atomic
        )
        await model.synchronizeConfigurationSources()
        let refreshedSecondNode = try #require(
            model.configurationDocument.nodes.first(where: { $0.sourceLinks.contains(secondSourceID) })
        )
        #expect(refreshedSecondNode.id == secondNodeID)
        let refreshedFirstNode = try #require(
            model.configurationDocument.nodes.first(where: { $0.sourceLinks.contains(firstSourceID) })
        )
        #expect(refreshedFirstNode.parameters["uuid"] == "account-a")
        #expect(model.configurationDocument.nodes.filter {
            $0.sourceLinks.contains(firstSourceID) || $0.sourceLinks.contains(secondSourceID)
        }.count == 2)
    }

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

    @Test func nodeOnlyImporterOnlyTreatsZeroIndentStrategyKeysAsTopLevel() throws {
        let sourceID = SourceID()
        let yaml = """
        proxies:
          - name: Nested fields
            type: vless
            server: example.com
            port: 443
            transport-options:
              dns: preserved-as-a-node-value
              tun: also-not-a-root-section
        """
        let report = NodeOnlyImporter().importNodes(sourceID: sourceID, yaml: Data(yaml.utf8))
        #expect(report.nodes.count == 1)
        #expect(!report.ignoredSections.contains("dns"))
        #expect(!report.ignoredSections.contains("tun"))
    }

    @Test func nodeOnlyImporterKeepsGroupingMetadataOutsideConnectionIdentity() throws {
        let sourceID = SourceID()
        let tagged = """
        proxies:
          - name: US Premium
            type: vless
            server: us.example.com
            port: 443
            uuid: account-a
            tags: [US, premium]
            region: United States
        """
        let renamedMetadata = """
        proxies:
          - name: United States
            type: vless
            server: us.example.com
            port: 443
            uuid: account-a
            tags: [US, backup]
            region: US
        """
        let first = try #require(
            NodeOnlyImporter().importNodes(sourceID: sourceID, yaml: Data(tagged.utf8)).nodes.first
        )
        let second = try #require(
            NodeOnlyImporter().importNodes(sourceID: sourceID, yaml: Data(renamedMetadata.utf8)).nodes.first
        )
        #expect(first.tags == Set(["US", "premium"]))
        #expect(first.region == "United States")
        #expect(first.fingerprint == second.fingerprint)
        #expect(first.id == second.id)
    }

    @Test func nodeOnlyImporterRetainsDistinctCredentialsAtOneEndpoint() throws {
        let sourceID = SourceID()
        let yaml = """
        proxies:
          - name: US account A
            type: vless
            server: us.example.com
            port: 443
            uuid: account-a
            tls: true
          - name: US account B
            type: vless
            server: us.example.com
            port: 443
            uuid: account-b
            tls: true
        """
        let report = NodeOnlyImporter().importNodes(sourceID: sourceID, yaml: Data(yaml.utf8))
        #expect(report.nodes.count == 2)
        #expect(report.nodes[0].fingerprint == report.nodes[1].fingerprint)
        #expect(report.nodes[0].id != report.nodes[1].id)
        #expect(report.diagnostics.contains { $0.code == "node_identity_conflict" })
    }

    @Test func collisionNodeIDsDoNotDependOnProviderEntryOrder() throws {
        let sourceID = SourceID()
        let first = """
        proxies:
          - name: Account A
            type: vless
            server: us.example.com
            port: 443
            uuid: account-a
            tls: true
          - name: Account B
            type: vless
            server: us.example.com
            port: 443
            uuid: account-b
            tls: true
        """
        let second = """
        proxies:
          - name: Account B renamed
            type: vless
            server: us.example.com
            port: 443
            uuid: account-b
            tls: true
          - name: Account A renamed
            type: vless
            server: us.example.com
            port: 443
            uuid: account-a
            tls: true
        """
        let reportA = NodeOnlyImporter().importNodes(sourceID: sourceID, yaml: Data(first.utf8))
        let reportB = NodeOnlyImporter().importNodes(sourceID: sourceID, yaml: Data(second.utf8))
        let identitiesA = Dictionary(uniqueKeysWithValues: reportA.nodes.map {
            ($0.connectionFingerprint, $0.id)
        })
        let identitiesB = Dictionary(uniqueKeysWithValues: reportB.nodes.map {
            ($0.connectionFingerprint, $0.id)
        })
        #expect(identitiesA == identitiesB)
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

    @Test func applicationAndDomainConditionsStayInTheCapturePlan() throws {
        let group = ProxyGroup(name: "AI", type: .select)
        let rule = RoutingRule(
            priority: 10,
            matchers: [
                .application("com.example.*"),
                .application("com.other.app"),
                .domainSuffix("api.example.com"),
                .port(443),
            ],
            action: .proxyGroup(group.id)
        )
        let conversion = ConfigurationCaptureAdapter.convert(
            from: [rule],
            groups: [group]
        )
        #expect(conversion.diagnostics.isEmpty)
        #expect(conversion.rules.count == 1)
        #expect(conversion.rules[0].sources.count == 2)
        #expect(conversion.rules[0].destinations.count == 1)
        #expect(conversion.rules[0].portRanges.count == 1)

        let dns = DNSPolicy(name: "MClash DNS")
        let entrance = Entrance(kind: .socks5, enabled: true, port: 7891)
        let workspace = Workspace(
            name: "Everyday",
            proxyGroupIDs: [group.id],
            ruleIDs: [rule.id],
            dnsPolicyID: dns.id,
            entranceIDs: [entrance.id]
        )
        let document = ConfigurationDocument(
            proxyGroups: [group],
            rules: [rule],
            dnsPolicies: [dns],
            entrances: [entrance],
            workspaces: [workspace],
            currentWorkspaceID: workspace.id
        )
        let yaml = String(decoding: try ConfigurationCompiler().compile(document: document).yaml, as: UTF8.self)
        #expect(!yaml.contains("DOMAIN-SUFFIX,api.example.com"))
    }

    @Test func compilerDisambiguatesDuplicateProviderNamesForMihomoReferences() throws {
        let first = try Node(displayName: "US", protocol: .vless, host: "one.example.com", port: 443)
        let second = try Node(displayName: "US", protocol: .vless, host: "two.example.com", port: 443)
        let group = ProxyGroup(name: "US nodes", type: .select, members: [.node(first.id), .node(second.id)])
        let dns = DNSPolicy(name: "MClash DNS")
        let entrance = Entrance(kind: .socks5, enabled: true, port: 7891)
        let workspace = Workspace(name: "Everyday", proxyGroupIDs: [group.id], dnsPolicyID: dns.id, entranceIDs: [entrance.id])
        let document = ConfigurationDocument(
            nodes: [first, second],
            proxyGroups: [group],
            dnsPolicies: [dns],
            entrances: [entrance],
            workspaces: [workspace],
            currentWorkspaceID: workspace.id
        )
        let yaml = String(decoding: try ConfigurationCompiler().compile(document: document).yaml, as: UTF8.self)
        #expect(yaml.contains("name: \"US\""))
        #expect(yaml.contains("name: \"US (2)\""))
        #expect(yaml.contains("US (2)"))
    }
}
