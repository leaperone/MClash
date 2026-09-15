import Foundation
import MClashAutomationProtocol
import Testing
@testable import MClashApp

@Suite("Xray configuration")
struct XrayConfigurationTests {
    let uuid = "00000000-0000-0000-0000-000000000001"

    @Test("Imported nested WebSocket options retain path, Host, SNI and ALPN")
    func importedWebSocket() throws {
        let yaml = """
        proxies:
          - name: WebSocket
            type: vless
            server: proxy.example
            port: 443
            uuid: \(uuid)
            tls: true
            servername: tls.example
            alpn: [http/1.1]
            ws-opts:
              path: /proxy
              headers:
                Host: cdn.example
            network: ws
        """
        let report = NodeOnlyImporter().importNodes(sourceID: SourceID(), yaml: Data(yaml.utf8))
        let node = try #require(report.nodes.first)
        let outbound = try #require(XrayNodeRenderer.render(node, tag: "node").objectValue)
        let settings = try #require(outbound["settings"]?.objectValue)
        let stream = try #require(outbound["streamSettings"]?.objectValue)
        #expect(settings["streamSettings"] == nil)
        #expect(stream["network"]?.stringValue == "ws")
        #expect(stream["wsSettings"]?.objectValue?["path"]?.stringValue == "/proxy")
        #expect(stream["wsSettings"]?.objectValue?["host"]?.stringValue == "cdn.example")
        #expect(stream["tlsSettings"]?.objectValue?["serverName"]?.stringValue == "tls.example")
        #expect(stream["tlsSettings"]?.objectValue?["alpn"]?.arrayValue == [.string("http/1.1")])
        #expect(stream["tlsSettings"]?.objectValue?["allowInsecure"]?.boolValue == false)
    }

    @Test("Hysteria2 uses its exact endpoint and stream schema")
    func hysteria() throws {
        let node = try Node(displayName: "HY", protocol: .hysteria2, host: "hy.example", port: 8443,
                            parameters: ["password": "test-auth", "sni": "hy-tls.example"])
        let outbound = try #require(XrayNodeRenderer.render(node, tag: "hy").objectValue)
        let settings = try #require(outbound["settings"]?.objectValue)
        let stream = try #require(outbound["streamSettings"]?.objectValue)
        #expect(outbound["protocol"]?.stringValue == "hysteria")
        #expect(settings["version"]?.intValue == 2)
        #expect(settings["address"]?.stringValue == "hy.example")
        #expect(settings["servers"] == nil)
        #expect(stream["hysteriaSettings"]?.objectValue?["version"]?.intValue == 2)
        #expect(stream["hysteriaSettings"]?.objectValue?["auth"]?.stringValue == "test-auth")
        #expect(stream["tlsSettings"]?.objectValue?["serverName"]?.stringValue == "hy-tls.example")
    }

    @Test("Reality preserves numeric-looking short IDs and Vision flow")
    func reality() throws {
        let key = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let node = try Node(displayName: "Reality", protocol: .vless, host: "proxy.example", port: 443,
            parameters: ["uuid": uuid, "flow": "xtls-rprx-vision", "servername": "tls.example",
                         "reality-opts": "{\"public-key\":\"\(key)\",\"short-id\":\"0020\"}"])
        let outbound = try #require(XrayNodeRenderer.render(node, tag: "reality").objectValue)
        let stream = try #require(outbound["streamSettings"]?.objectValue)
        #expect(stream["security"]?.stringValue == "reality")
        #expect(stream["realitySettings"]?.objectValue?["shortId"]?.stringValue == "0020")
        #expect(stream["realitySettings"]?.objectValue?["publicKey"]?.stringValue == key)
        #expect(outbound["settings"]?.objectValue?["vnext"]?.arrayValue?.first?.objectValue?["users"]?.arrayValue?.first?.objectValue?["flow"]?.stringValue == "xtls-rprx-vision")
    }

    @Test("Missing credentials and unsupported plugins fail without disclosing values")
    func invalidNodes() throws {
        let missing = try Node(displayName: "Trojan", protocol: .trojan, host: "proxy.example", port: 443)
        #expect(throws: XrayNodeRenderError.missingField("password")) { try XrayNodeRenderer.render(missing, tag: "node") }
        let plugin = try Node(displayName: "SS", protocol: .shadowsocks, host: "proxy.example", port: 443,
            parameters: ["cipher": "aes-128-gcm", "password": "credential-must-not-appear", "plugin": "unknown"])
        do {
            _ = try XrayNodeRenderer.render(plugin, tag: "node")
            Issue.record("Unsupported plugin was accepted")
        } catch {
            #expect(!error.localizedDescription.contains("credential-must-not-appear"))
            #expect(error as? XrayNodeRenderError == .unsupportedOption("plugin"))
        }
    }

    @Test("Exact, suffix and wildcard rules retain distinct matching semantics")
    func domainRules() throws {
        var document = fixture()
        let rules = [RoutingMatcher.domainExact("example.com"), .domainSuffix("example.net"), .domainWildcard("*.example.org")]
            .enumerated().map { RoutingRule(priority: $0.offset, matchers: [$0.element], action: .direct) }
        document.rules = rules
        document.workspaces[0].ruleIDs = rules.map(\.id)
        let plan = try compile(document)
        let rendered = try #require(plan.configuration["routing"]?.objectValue?["rules"]?.arrayValue).filter { $0.objectValue?["domain"] != nil }
        #expect(rendered[0].objectValue?["domain"]?.arrayValue == [.string("full:example.com")])
        #expect(rendered[1].objectValue?["domain"]?.arrayValue == [.string("domain:example.net")])
        #expect(rendered[2].objectValue?["domain"]?.arrayValue == [.string("regexp:^.*\\.example\\.org$")])
    }

    @Test("Rules stay scoped to the selected workspace and cross-kind predicates remain AND")
    func ruleScope() throws {
        var document = fixture()
        let selected = RoutingRule(priority: 10, matchers: [.domainSuffix("example.org"), .port(443), .transport("tcp")], action: .direct)
        let other = RoutingRule(priority: 0, matchers: [.domainSuffix("private.example")], action: .reject)
        document.rules = [other, selected]
        document.workspaces[0].ruleIDs = [selected.id]
        let rules = try #require(compile(document).configuration["routing"]?.objectValue?["rules"]?.arrayValue)
        #expect(rules.count == 3)
        #expect(rules[1].objectValue?["port"]?.stringValue == "443")
        #expect(rules[1].objectValue?["network"]?.stringValue == "tcp")
        #expect(rules[1].objectValue?["domain"]?.arrayValue == [.string("domain:example.org")])
    }

    @Test("Untranslated application conditions cannot become broad core rules")
    func captureBoundary() throws {
        var document = fixture()
        let rule = RoutingRule(priority: 0, matchers: [.application("example.app"), .domainSuffix("example.org")], action: .direct)
        document.rules = [rule]
        document.workspaces[0].ruleIDs = [rule.id]
        #expect(throws: (any Error).self) { try compile(document) }
        let workspace = document.workspaces[0]
        let plan = try XrayConfigurationCompiler.compile(document: document, workspaceID: workspace.id,
            inbounds: [], apiSocketPath: "/tmp/mcx-test/api.sock", capturedRuleIDs: [rule.id])
        #expect(plan.configuration["routing"]?.objectValue?["rules"]?.arrayValue?.count == 1)
    }

    @Test("Groups start with a reject selection until the controller arms them")
    func defaultSelection() throws {
        var document = fixture()
        let node = try Node(displayName: "VLESS", protocol: .vless, host: "proxy.example", port: 443, parameters: ["uuid": uuid])
        let group = ProxyGroup(name: "Default", members: [.node(node.id)])
        document.nodes = [node]
        document.proxyGroups = [group]
        document.workspaces[0].proxyGroupIDs = [group.id]
        let plan = try compile(document)
        let balancer = try #require(plan.configuration["routing"]?.objectValue?["balancers"]?.arrayValue?.first?.objectValue)
        #expect(balancer["selector"]?.arrayValue == [.string("reject")])
        #expect(plan.nodeTags[node.id] == XrayRuntimePlan.nodeTag(node.id))
        let api = try #require(plan.configuration["api"]?.objectValue)
        #expect(api["listen"]?.stringValue == "/tmp/mcx-test/api.sock")
    }

    @Test("Unsupported catalog entries remain visible and cannot be selected")
    func unsupportedCatalog() throws {
        var document = fixture()
        let node = try Node(displayName: "Unsupported", protocol: .tuic, host: "proxy.example", port: 443)
        document.nodes = [node]
        let plan = try compile(document)
        #expect(plan.unavailableNodes[node.id] != nil)
        #expect(plan.nodeTags[node.id] == nil)
        #expect(throws: (any Error).self) {
            try XrayConfigurationCompiler.compile(document: document, workspaceID: document.workspaces[0].id,
                inbounds: [.init(tag: "input", kind: .socks, port: 19090, target: .node(node.id))], apiSocketPath: "/tmp/mcx-test/api.sock")
        }
    }

    @Test("The pinned Xray executable accepts every claimed node schema",
          .enabled(if: ProcessInfo.processInfo.environment["MCLASH_XRAY_BINARY"] != nil))
    func coreValidation() throws {
        let binary = try #require(ProcessInfo.processInfo.environment["MCLASH_XRAY_BINARY"])
        let nodes: [(NodeProtocol, [String: String])] = [
            (.vless, ["uuid": uuid]), (.vmess, ["uuid": uuid, "cipher": "auto"]),
            (.trojan, ["password": "fixture"]), (.http, [:]), (.https, [:]), (.socks5, [:]),
            (.shadowsocks, ["password": "fixture", "cipher": "aes-128-gcm"]),
            (.hysteria2, ["password": "fixture", "sni": "example.com"]),
        ]
        let directory = FileManager.default.temporaryDirectory.appending(path: "xray-schema-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (proto, parameters) in nodes {
            let node = try Node(displayName: proto.rawValue, protocol: proto, host: "127.0.0.1", port: 19999, parameters: parameters)
            let outbound = try XrayNodeRenderer.render(node, tag: "node")
            let config: [String: AutomationJSONValue] = ["outbounds": .array([outbound])]
            let path = directory.appending(path: "config.json")
            try JSONEncoder().encode(config).write(to: path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["run", "-test", "-config", path.path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            _ = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "Xray rejected the \(proto.rawValue) schema")
        }
    }

    private func fixture() -> ConfigurationDocument {
        let dns = DNSPolicy(name: "System", mode: .system)
        let workspace = Workspace(name: "Test", dnsPolicyID: dns.id)
        return ConfigurationDocument(dnsPolicies: [dns], workspaces: [workspace], currentWorkspaceID: workspace.id)
    }

    private func compile(_ document: ConfigurationDocument) throws -> XrayRuntimePlan {
        try XrayConfigurationCompiler.compile(document: document, workspaceID: document.workspaces[0].id,
            inbounds: [.init(tag: "input", kind: .socks, port: 19090)], apiSocketPath: "/tmp/mcx-test/api.sock")
    }
}
