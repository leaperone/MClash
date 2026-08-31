import Foundation

// ConfigurationStore carries this lifecycle-only journal field; the smoke
// does not exercise activation, so keep the standalone source set small.
struct NetworkCapturePreferences: Codable, Equatable, Sendable {}

@main
struct ConfigurationCompilerMihomoSmoke {
    static func main() throws {
        guard let corePath = ProcessInfo.processInfo.environment["MCLASH_TEST_CORE"] else {
            throw SmokeFailure.corePathMissing
        }

        let source = Source(kind: .subscription, displayName: "Smoke subscription")
        let reality = try Node(
            displayName: "US Reality",
            protocol: .vless,
            host: "us.example.com",
            port: 443,
            parameters: [
                "uuid": "00000000-0000-4000-8000-000000000001",
                "tls": "true",
                "servername": "cdn.example.com",
                "reality-opts": #"{"public-key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","short-id":"01234567"}"#,
                "network": "tcp",
            ],
            sourceLinks: [source.id]
        )
        let webSocket = try Node(
            displayName: "US WebSocket https://status.example.com",
            protocol: .vless,
            host: "ws.example.com",
            port: 443,
            parameters: [
                "uuid": "00000000-0000-4000-8000-000000000002",
                "tls": "true",
                "servername": "cdn.example.com",
                "network": "ws",
                "ws-opts": #"{"path":"/smoke","headers":{"Host":"cdn.example.com"}}"#,
            ],
            sourceLinks: [source.id]
        )
        let fallback = try Node(
            displayName: "JP Backup",
            protocol: .shadowsocks,
            host: "jp.example.com",
            port: 8388,
            parameters: ["cipher": "aes-128-gcm", "password": "smoke-password"],
            sourceLinks: [source.id]
        )
        let group = ProxyGroup(
            name: "Smoke Select",
            type: .select,
            members: [.node(fallback.id)],
            memberSelectors: [NodeSelector(name: "US", include: [.hostContains("us")])]
        )
        let dns = DNSPolicy(
            name: "Smoke DNS",
            mode: .fakeIP,
            nameservers: ["223.5.5.5", "1.1.1.1"],
            fallbackNameservers: ["8.8.8.8"],
            proxyServer: "https://1.1.1.1/dns-query",
            rules: ["+.example.com"],
            takeoverEnabled: true
        )
        let http = Entrance(kind: .http, enabled: true, port: 18_080, defaultAction: .proxyGroup(group.id))
        let socks = Entrance(kind: .socks5, enabled: true, port: 18_081, defaultAction: .proxyGroup(group.id))
        let appRouting = Entrance(kind: .appRouting, enabled: true, defaultAction: .proxyGroup(group.id))
        let domainRule = RoutingRule(
            priority: 10,
            matchers: [
                .domainWildcard("*.example.com"),
                .ipCIDR("192.0.2.0/24"),
                .portRange(443...8443),
                .transport("tcp"),
            ],
            action: .proxyGroup(group.id)
        )
        let appRule = RoutingRule(
            priority: 20,
            matchers: [.application("com.example.Smoke")],
            action: .direct
        )
        let workspace = Workspace(
            name: "Smoke workspace",
            proxyGroupIDs: [group.id],
            ruleIDs: [domainRule.id, appRule.id],
            dnsPolicyID: dns.id,
            entranceIDs: [http.id, socks.id, appRouting.id]
        )
        let document = ConfigurationDocument(
            sources: [source],
            nodes: [reality, webSocket, fallback],
            proxyGroups: [group],
            rules: [domainRule, appRule],
            dnsPolicies: [dns],
            entrances: [http, socks, appRouting],
            workspaces: [workspace],
            currentWorkspaceID: workspace.id
        )

        let compiled = try ConfigurationCompiler().compile(document: document)
        let yaml = String(decoding: compiled.yaml, as: UTF8.self)
        for required in [
            "port: 18080", "socks-port: 18081", "reality-opts",
            "ws-opts", "DOMAIN-WILDCARD,*.example.com", "AND,((DOMAIN-WILDCARD",
            "IP-CIDR,192.0.2.0/24", "nameserver-policy", "MATCH,Smoke Select",
        ] where !yaml.contains(required) {
            throw SmokeFailure.missingOutput(required)
        }
        guard !yaml.contains("\\/") else {
            throw SmokeFailure.invalidYAMLSlashEscape
        }
        guard compiled.captureEnabled, compiled.networkExtensionRules.count == 1 else {
            throw SmokeFailure.appRoutingNotBridged
        }

        let root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-compiler-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("config.yaml")
        try compiled.yaml.write(to: configURL, options: .atomic)

        let process = Process()
        process.executableURL = URL(filePath: corePath)
        process.arguments = ["-t", "-d", root.path, "-f", configURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw SmokeFailure.coreRejected(result + "\n--- compiled YAML ---\n" + yaml)
        }
        print("Configuration compiler Mihomo smoke passed: \(compiled.yaml.count) bytes")
    }
}

private enum SmokeFailure: Error, CustomStringConvertible {
    case corePathMissing
    case missingOutput(String)
    case appRoutingNotBridged
    case invalidYAMLSlashEscape
    case coreRejected(String)

    var description: String {
        switch self {
        case .corePathMissing: return "MCLASH_TEST_CORE is required"
        case let .missingOutput(value): return "compiled YAML is missing \(value)"
        case .appRoutingNotBridged: return "App Routing was not bridged to capture rules"
        case .invalidYAMLSlashEscape: return "compiled YAML contains an invalid \\/ escape"
        case let .coreRejected(output): return "mihomo rejected compiled YAML:\n\(output)"
        }
    }
}
