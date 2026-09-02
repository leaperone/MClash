import Foundation
import Testing
@testable import MClashApp

struct ConfigurationRoutingModeTests {
    @Test("Workspace routing mode defaults to rule for legacy manifests")
    func legacyWorkspaceDecodesWithRuleMode() throws {
        let original = Workspace(name: "Legacy", dnsPolicyID: DNSPolicyID())
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "routingMode")
        object.removeValue(forKey: "globalProxyGroupID")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let workspace = try JSONDecoder().decode(Workspace.self, from: legacyData)
        #expect(workspace.routingMode == .rule)
        #expect(workspace.globalProxyGroupID == nil)
    }

    @Test("Global mode emits Mihomo GLOBAL policy group")
    func globalModeCompiles() throws {
        var document = ConfigurationDocument.mclashDefault()
        let group = try #require(document.proxyGroups.first)
        document.workspaces[0].routingMode = .global
        document.workspaces[0].globalProxyGroupID = group.id
        let yaml = String(decoding: try ConfigurationCompiler().compile(document: document).yaml, as: UTF8.self)
        #expect(yaml.contains("mode: global"))
        #expect(yaml.contains("name: \"GLOBAL\""))
        #expect(yaml.contains("proxies: [\"MClash Select\"]"))
    }

    @Test("Direct mode compiles without a synthetic GLOBAL group")
    func directModeCompiles() throws {
        var document = ConfigurationDocument.mclashDefault()
        document.workspaces[0].routingMode = .direct
        let yaml = String(decoding: try ConfigurationCompiler().compile(document: document).yaml, as: UTF8.self)
        #expect(yaml.contains("mode: direct"))
        #expect(!yaml.contains("name: \"GLOBAL\""))
        #expect(yaml.contains("proxy: \"DIRECT\""))
    }

    @Test("Global and direct modes override saved entrance defaults")
    func modesOverrideEntranceTargets() throws {
        var document = ConfigurationDocument.mclashDefault()
        let group = try #require(document.proxyGroups.first)
        document.entrances[0].defaultAction = .direct
        document.entrances[1].defaultAction = .proxyGroup(group.id)

        document.workspaces[0].routingMode = .global
        document.workspaces[0].globalProxyGroupID = group.id
        let global = String(
            decoding: try ConfigurationCompiler().compile(document: document).yaml,
            as: UTF8.self
        )
        #expect(global.components(separatedBy: "proxy: \"GLOBAL\"").count == 3)
        #expect(!global.contains("proxy: \"DIRECT\""))

        document.workspaces[0].routingMode = .direct
        let direct = String(
            decoding: try ConfigurationCompiler().compile(document: document).yaml,
            as: UTF8.self
        )
        #expect(direct.components(separatedBy: "proxy: \"DIRECT\"").count == 3)
        #expect(!direct.contains("proxy: \"GLOBAL\""))
    }
}

extension ConfigurationRoutingModeTests {
    @Test("Native inbound mode omits Mihomo-owned listeners")
    func nativeInboundCompilerOmitsListeners() throws {
        var document = ConfigurationDocument.mclashDefault()
        document.entrances[0].enabled = true
        let yaml = String(
            decoding: try ConfigurationCompiler(emitsMihomoListeners: false)
                .compile(document: document).yaml,
            as: UTF8.self
        )
        #expect(!yaml.contains("listeners:"))
        #expect(yaml.contains("proxies:"))
    }
}
