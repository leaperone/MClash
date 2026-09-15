import Foundation
import MClashAutomationProtocol
import Testing
@testable import MClashApp

@Suite("Xray live control", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MCLASH_XRAY_BINARY"] != nil))
struct XrayControlSessionTests {
    @Test("Routing and listener changes retain the core process and roll back failed writes")
    func transactions() async throws {
        let root = URL(fileURLWithPath: "/tmp/mct-" + UUID().uuidString.prefix(12))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = Process()
        origin.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let originPort = try LocalPortProbe().availableTCPPort()
        origin.arguments = ["-c", "import http.server; http.server.HTTPServer(('127.0.0.1', \(originPort)), http.server.SimpleHTTPRequestHandler).serve_forever()"]
        origin.currentDirectoryURL = root
        origin.standardOutput = FileHandle.nullDevice
        origin.standardError = FileHandle.nullDevice
        try Data("control-payload".utf8).write(to: root.appending(path: "payload"))
        try origin.run()
        defer { if origin.isRunning { origin.terminate(); origin.waitUntilExit() } }
        let commands = CoreSupervisor()
        let target = "http://127.0.0.1:\(originPort)/payload"
        var originReady = false
        for _ in 0..<50 {
            if (try? await commands.runCommand(executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
                arguments: ["-fsS", "--noproxy", "*", "--max-time", "1", target], directory: root)) == Data("control-payload".utf8) {
                originReady = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(originReady)
        let direct = ProxyGroup(name: "Direct exit", type: .direct)
        let reject = ProxyGroup(name: "Reject exit", type: .reject)
        let selector = ProxyGroup(name: "Choice", members: [.group(direct.id), .group(reject.id)])
        let dns = DNSPolicy(name: "System")
        let workspace = Workspace(name: "Fixture", proxyGroupIDs: [direct.id, reject.id, selector.id], dnsPolicyID: dns.id)
        let document = ConfigurationDocument(proxyGroups: [direct, reject, selector], dnsPolicies: [dns],
            workspaces: [workspace], currentWorkspaceID: workspace.id)
        let input = XrayInbound(tag: "public", kind: .socks, port: try LocalPortProbe().availableTCPPort(), target: .group(selector.id))
        let socket = root.appending(path: "api.sock").path
        func compile(_ document: ConfigurationDocument, _ inputs: [XrayInbound]) throws -> XrayRuntimePlan {
            try XrayConfigurationCompiler.compile(document: document, workspaceID: workspace.id, inbounds: inputs,
                apiSocketPath: socket, logDirectory: root.path)
        }
        let initial = try compile(document, [input])
        let configDirectory = root.appending(path: "configuration")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: false)
        let config = configDirectory.appending(path: "config.json")
        try initial.encoded().write(to: config)
        let binary = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MCLASH_XRAY_BINARY"]))
        let control = try XrayControlSession(plan: initial, document: document, binary: binary, apiSocketPath: socket,
            directory: root, commands: commands, configurationURL: config)
        let launch = CoreLaunchConfiguration(binaryURL: binary, homeDirectory: root, configURL: config,
            controllerPort: 0, secret: "", backend: .xray(apiSocketPath: socket, version: "fixture"))
        func request(_ entrance: XrayInbound) async throws -> Data {
            var arguments = ["-fsS", "--max-time", "3", "--noproxy", "", "--socks5-hostname", "127.0.0.1:\(entrance.port)"]
            if let authentication = entrance.authentication { arguments += ["--proxy-user", authentication.username + ":" + authentication.password] }
            return try await commands.runCommand(executableURL: URL(fileURLWithPath: "/usr/bin/curl"), arguments: arguments + [target], directory: root)
        }
        func servingPID() async throws -> Data {
            try await commands.runCommand(executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"),
                arguments: ["-nP", "-t", "-iTCP:\(input.port)", "-sTCP:LISTEN"], directory: root)
        }
        do {
            try await commands.start(launch)
            try await control.prepare()
            #expect(try await request(input) == Data("control-payload".utf8))
            let originalPID = try await servingPID()
            let capture = XrayInbound(tag: "capture", kind: .socks, port: try LocalPortProbe().availableTCPPort(),
                target: .direct, authentication: .init(username: "fixture", password: "fixture-secret"))
            let expanded = try compile(document, [input, capture])
            try await control.reconfigure(plan: expanded, document: document, capturedRuleIDs: [])
            #expect(try await request(capture) == Data("control-payload".utf8))
            #expect(try await servingPID() == originalPID)
            try await control.reconfigure(plan: initial, document: document, capturedRuleIDs: [])
            await #expect(throws: (any Error).self) { try await request(capture) }
            #expect(try await request(input) == Data("control-payload".utf8))
            var invalidConfig = expanded.configuration
            invalidConfig["inbounds"] = .array([.object(["protocol": .string("nonexistent")])])
            let invalid = XrayRuntimePlan(workspace: expanded.workspace, nodes: expanded.nodes, groups: expanded.groups,
                inbounds: expanded.inbounds, nodeTags: expanded.nodeTags, groupTags: expanded.groupTags,
                unavailableNodes: expanded.unavailableNodes, diagnostics: expanded.diagnostics, configuration: invalidConfig)
            await #expect(throws: (any Error).self) {
                try await control.reconfigure(plan: invalid, document: document, capturedRuleIDs: [])
            }
            #expect(try await request(input) == Data("control-payload".utf8))
            let oldResolutions = await control.groupResolutions()
            let oldState = try Data(contentsOf: root.appending(path: "group-state.json"))
            let oldConfig = try Data(contentsOf: config)
            var replacement = document
            replacement.proxyGroups[2].members = [.group(reject.id), .group(direct.id)]
            let candidate = try compile(replacement, [input, capture])
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: configDirectory.path)
            do {
                try await control.reconfigure(plan: candidate, document: replacement, capturedRuleIDs: [])
                Issue.record("Reconfigure accepted a read-only configuration directory")
            } catch {
                #expect(!(error is XrayControlError), "The write should fail, and rollback should succeed")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDirectory.path)
            #expect(await control.groupResolutions() == oldResolutions)
            #expect(try Data(contentsOf: root.appending(path: "group-state.json")) == oldState)
            #expect(try Data(contentsOf: config) == oldConfig)
            #expect(try await request(input) == Data("control-payload".utf8))
            await #expect(throws: (any Error).self) { try await request(capture) }
            #expect(try await servingPID() == originalPID)
            #expect(await commands.stop())
        } catch {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDirectory.path)
            _ = await commands.stop()
            throw error
        }
    }
}
