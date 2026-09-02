import Foundation
import Testing
@testable import MClashApp

struct ConfigurationSplitPathsTests {
    @Test("Browser path pins an HTTP listener to a source-scoped group")
    func browserPathCreatesSourceGroupAndListener() throws {
        var document = ConfigurationDocument.mclashDefault()
        let source = Source(kind: .subscription, displayName: "Smart Proxy")
        document.sources = [source]
        document.nodes = [
            try Node(
                displayName: "US 01",
                protocol: .vless,
                host: "us.example.com",
                port: 443,
                sourceLinks: [source.id]
            )
        ]

        let applied = try ConfigurationSplitPaths.applyBrowserPath(
            to: document,
            sourceID: source.id,
            kind: .http,
            port: 7890,
            enabled: true
        )
        let path = ConfigurationSplitPaths.browserPath(from: applied)
        let group = try #require(applied.proxyGroups.first { group in
            group.memberSelectors.contains { $0.include == [.source(source.id)] }
        })
        let yaml = String(
            decoding: try ConfigurationCompiler().compile(document: applied).yaml,
            as: UTF8.self
        )

        #expect(path.enabled)
        #expect(path.kind == .http)
        #expect(path.port == 7890)
        #expect(path.sourceID == source.id)
        #expect(path.address == "127.0.0.1:7890")
        #expect(applied.currentWorkspace?.proxyGroupIDs.contains(group.id) == true)
        #expect(yaml.contains("port: 7890"))
        #expect(yaml.contains("proxy: \"Browser · Smart Proxy\""))

        let again = try ConfigurationSplitPaths.applyBrowserPath(
            to: applied,
            sourceID: source.id,
            kind: .http,
            port: 7890,
            enabled: true
        )
        #expect(again.proxyGroups.filter { $0.id == group.id }.count == 1)
    }

    @Test("App path captures listed apps into a different source group")
    func appPathCreatesManagedApplicationRules() throws {
        var document = ConfigurationDocument.mclashDefault()
        let browserSource = Source(kind: .subscription, displayName: "Smart Proxy")
        let appSource = Source(kind: .subscription, displayName: "API line")
        document.sources = [browserSource, appSource]
        document.nodes = [
            try Node(
                displayName: "Browser node",
                protocol: .vless,
                host: "browser.example.com",
                port: 443,
                sourceLinks: [browserSource.id]
            ),
            try Node(
                displayName: "Agent node",
                protocol: .vless,
                host: "agent.example.com",
                port: 443,
                sourceLinks: [appSource.id]
            )
        ]

        document = try ConfigurationSplitPaths.applyBrowserPath(
            to: document,
            sourceID: browserSource.id,
            kind: .socks5,
            port: 1080,
            enabled: true
        )
        document = try ConfigurationSplitPaths.applyAppPath(
            to: document,
            sourceID: appSource.id,
            applicationPatterns: ["com.todesktop.230313mzl4w4u92", "com.anthropic.claude"],
            enabled: true
        )

        let path = ConfigurationSplitPaths.appPath(from: document)
        let compiled = try ConfigurationCompiler().compile(document: document)
        let yaml = String(decoding: compiled.yaml, as: UTF8.self)

        #expect(path.enabled)
        #expect(path.sourceID == appSource.id)
        #expect(path.applicationPatterns.contains("com.todesktop.230313mzl4w4u92"))
        #expect(compiled.captureEnabled)
        #expect(compiled.captureRules.contains { rule in
            rule.action == .mihomo(.group("Apps · API line"))
        })
        #expect(yaml.contains("listen: \"127.0.0.1\""))
        #expect(yaml.contains("port: 1080"))
        #expect(yaml.contains("proxy: \"Browser · Smart Proxy\""))
        #expect(yaml.contains("MATCH,DIRECT") || yaml.contains("MATCH,\"DIRECT\""))
        #expect(!yaml.contains("MATCH,Apps · API line"))
        #expect(!yaml.contains("MATCH,\"Apps · API line\""))
        #expect(
            document.entrances.first { $0.kind == .appRouting }?.defaultAction == .direct
        )

        document = try ConfigurationSplitPaths.applyAppPath(
            to: document,
            sourceID: appSource.id,
            applicationPatterns: ["com.todesktop.230313mzl4w4u92"],
            enabled: true
        )
        #expect(ConfigurationSplitPaths.appPath(from: document).applicationPatterns == [
            "com.todesktop.230313mzl4w4u92"
        ])
    }

    @Test("Browser bundle identifiers are recognized so the UI can warn")
    func browserBundleHints() {
        #expect(ConfigurationSplitPaths.isBrowserApplication("com.google.chrome"))
        #expect(ConfigurationSplitPaths.isBrowserApplication("com.apple.Safari"))
        #expect(!ConfigurationSplitPaths.isBrowserApplication("com.todesktop.230313mzl4w4u92"))
    }

    @Test("Disabling the browser path does not snap onto a sibling SOCKS listener")
    func browserPathStaysOnFirstListenerWhenDisabled() throws {
        var document = ConfigurationDocument.mclashDefault()
        let source = Source(kind: .subscription, displayName: "Smart Proxy")
        document.sources = [source]
        document.nodes = [
            try Node(
                displayName: "US 01",
                protocol: .vless,
                host: "us.example.com",
                port: 443,
                sourceLinks: [source.id]
            )
        ]

        document = try ConfigurationSplitPaths.applyBrowserPath(
            to: document,
            sourceID: source.id,
            kind: .http,
            port: 7890,
            enabled: true
        )
        document = try ConfigurationSplitPaths.applyBrowserPath(
            to: document,
            sourceID: source.id,
            kind: .http,
            port: 7890,
            enabled: false
        )
        let path = ConfigurationSplitPaths.browserPath(from: document)
        let yaml = String(
            decoding: try ConfigurationCompiler().compile(document: document).yaml,
            as: UTF8.self
        )

        #expect(!path.enabled)
        #expect(path.kind == .http)
        #expect(path.port == 7890)
        #expect(path.sourceID == source.id)
        #expect(document.entrances.contains { $0.kind == .socks5 && $0.port == 7891 && $0.enabled })
        #expect(!yaml.contains("port: 7890"))
        #expect(yaml.contains("port: 7891"))
    }

    @Test("Clearing the browser source unbinds the listener default action")
    func browserPathClearsSource() throws {
        var document = ConfigurationDocument.mclashDefault()
        let source = Source(kind: .subscription, displayName: "Smart Proxy")
        document.sources = [source]
        document.nodes = [
            try Node(
                displayName: "US 01",
                protocol: .vless,
                host: "us.example.com",
                port: 443,
                sourceLinks: [source.id]
            )
        ]
        document = try ConfigurationSplitPaths.applyBrowserPath(
            to: document,
            sourceID: source.id,
            kind: .http,
            port: 7890,
            enabled: true
        )
        document = try ConfigurationSplitPaths.applyBrowserPath(
            to: document,
            sourceID: nil,
            kind: .http,
            port: 7890,
            enabled: true
        )
        let path = ConfigurationSplitPaths.browserPath(from: document)
        #expect(path.sourceID == nil)
        #expect(document.entrances.first { $0.kind == .http }?.defaultAction == .direct)
    }

    @Test("An app source remains selected even before any app is listed")
    func appPathRemembersSourceWithoutRules() throws {
        var document = ConfigurationDocument.mclashDefault()
        let appSource = Source(kind: .subscription, displayName: "API line")
        document.sources = [appSource]
        document.nodes = [
            try Node(
                displayName: "Agent node",
                protocol: .vless,
                host: "agent.example.com",
                port: 443,
                sourceLinks: [appSource.id]
            )
        ]

        document = try ConfigurationSplitPaths.applyAppPath(
            to: document,
            sourceID: appSource.id,
            applicationPatterns: [],
            enabled: true
        )
        let path = ConfigurationSplitPaths.appPath(from: document)
        let yaml = String(
            decoding: try ConfigurationCompiler().compile(document: document).yaml,
            as: UTF8.self
        )

        #expect(path.enabled)
        #expect(path.sourceID == appSource.id)
        #expect(path.applicationPatterns.isEmpty)
        #expect(yaml.contains("MATCH,DIRECT") || yaml.contains("MATCH,\"DIRECT\""))
    }

    @Test("Invalid browser ports are rejected")
    func invalidPort() {
        let document = ConfigurationDocument.mclashDefault()
        #expect(throws: ConfigurationSplitPaths.Error.invalidPort) {
            try ConfigurationSplitPaths.applyBrowserPath(
                to: document,
                sourceID: nil,
                kind: .http,
                port: 0,
                enabled: true
            )
        }
    }
}
