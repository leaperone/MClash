import Foundation
import MClashNetworkShared
import Testing
@testable import MClashApp

@Suite("Native app-owned real endpoint interoperability")
struct NativeAppRealEndpointInteropTests {
    @Test("NativeRuntimeEngine carries HTTPS through its own HTTP entrance")
    func nativeRuntimeEngineCarriesHTTPS() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifestPath = environment["MCLASH_REAL_PROFILE_MANIFEST"] else {
            return
        }
        let nodeHint = environment["MCLASH_REAL_NODE_NAME_CONTAINS"]
            ?? "🇺🇸 美国|us|9929|ws|private"
        let document = try Self.loadDocument(
            URL(fileURLWithPath: manifestPath)
        )
        let node = try #require(document.nodes.first {
            $0.displayName.localizedCaseInsensitiveContains(nodeHint)
                && $0.proto == .vless
                && $0.parameters["network"]?.lowercased() == "ws"
        })
        let group = ProxyGroup(
            name: "Real CUNOE probe",
            type: .select,
            members: [.node(node.id)]
        )
        let dns = DNSPolicy(
            name: "Native endpoint DNS",
            mode: .redirHost,
            nameservers: [environment["MCLASH_REAL_DNS_SERVER"] ?? "119.29.29.29"],
            takeoverEnabled: true
        )
        let base = try ConfigurationCompiler().compileRuntimePlan(
            document: .mclashDefault()
        )
        let plan = CompiledRuntimePlan(
            workspaceID: base.workspaceID,
            workspaceRevision: 1,
            nodes: [node],
            proxyGroups: [group],
            rules: [],
            ruleSets: [],
            dnsPolicy: dns,
            entrances: [],
            routingMode: .global,
            globalProxyGroupID: group.id
        )
        let port = try LocalPortProbe().availableTCPPort()
        let listener = try MClashListenerSpec(
            name: "Real HTTP probe",
            kind: .http,
            enabled: true,
            port: port,
            route: .outbound(.group(group.name))
        )
        let engine = NativeRuntimeEngine()
        try await engine.configure(
            plan: plan,
            listeners: MClashListenerRegistry(listeners: [listener])
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-native-real-\(UUID().uuidString)")
        try await engine.start(CoreLaunchConfiguration(
            binaryURL: root.appending(path: "must-not-launch"),
            homeDirectory: root.appending(path: "home"),
            configURL: root.appending(path: "native-plan.json"),
            controllerPort: 19_104,
            secret: "native-real-endpoint-secret"
        ))
        do {
            var ready = false
            for _ in 0..<1_000 {
                let handles = await engine.nativeListenerHandles()
                if handles.first?.socketBound == true {
                    ready = true
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard ready else { throw NativeAppRealEndpointError.listenerDidNotStart }
            let responseCode = try Self.curl(proxyPort: port)
            #expect(responseCode == "204")
            #expect(await engine.diagnostics().unsupportedConnectors.isEmpty)
            #expect(await engine.stop())
            var observation: FlowRelayObservation?
            for _ in 0..<200 {
                observation = await engine.flowObservations.snapshot().last
                if observation?.state == .completed { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(
                observation?.state == .completed,
                "Native observation failed at \(observation?.failureReason ?? "unknown stage")"
            )
            #expect(observation?.route == .relay)
            #expect(observation?.routeChain == [OutboundRoute.group(group.name).stableSortKey])
            #expect((observation?.uploadBytes ?? 0) > 0)
            #expect((observation?.downloadBytes ?? 0) > 0)
        } catch {
            _ = await engine.stop()
            throw error
        }
    }

    private static func loadDocument(_ url: URL) throws -> ConfigurationDocument {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 32 * 1_024 * 1_024 else {
            throw NativeAppRealEndpointError.invalidManifest
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ConfigurationDocument.self, from: data)
    }

    private static func curl(proxyPort: Int) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--silent", "--show-error", "--output", "/dev/null",
            "--write-out", "%{http_code}",
            "--proxy", "http://127.0.0.1:\(proxyPort)",
            "--connect-timeout", "15", "--max-time", "30",
            "https://www.google.com/generate_204"
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
            throw NativeAppRealEndpointError.curlFailed(
                process.terminationStatus,
                String(detail.prefix(512))
            )
        }
        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum NativeAppRealEndpointError: Error {
    case invalidManifest
    case listenerDidNotStart
    case curlFailed(Int32, String)
}
