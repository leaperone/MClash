import Foundation
import MClashNetworkShared
@testable import MClashApp
import Testing

@Suite("Network Extension Mihomo listener")
struct NetworkExtensionMihomoListenerTests {
    @Test("Dedicated SOCKS5 listeners are loopback-only, dual-stack, and UDP capable")
    func emitsPrivateDualStackListeners() throws {
        let profile = Data(
            """
            # user profile remains the source of truth
            mixed-port: 7890
            proxies:
              - name: keep-me
                type: direct
            rules:
              - MATCH,DIRECT
            """.utf8
        )
        let configuration = try NetworkExtensionMihomoListenerConfiguration(port: 17_891)

        let result = try RuntimeConfigurationComposer().applying(
            .empty,
            to: profile,
            networkExtensionListener: configuration
        )
        let yaml = try #require(String(data: result, encoding: .utf8))

        #expect(yaml.contains("# user profile remains the source of truth"))
        #expect(yaml.contains("proxies:\n  - name: keep-me\n    type: direct"))
        #expect(yaml.contains("rules:\n  - MATCH,DIRECT"))
        #expect(yaml.contains("name: \"mclash-network-extension-socks-ipv4\""))
        #expect(yaml.contains("name: \"mclash-network-extension-socks-ipv6\""))
        #expect(yaml.contains("listen: \"127.0.0.1\""))
        #expect(yaml.contains("listen: \"::1\""))
        #expect(yaml.components(separatedBy: "port: 17891").count == 3)
        #expect(yaml.components(separatedBy: "udp: true").count == 3)
        #expect(yaml.components(separatedBy: "users: []").count == 3)
        #expect(!yaml.contains("listen: \"0.0.0.0\""))
        #expect(!yaml.contains("listen: \"::\""))
        #expect(configuration.ipv4Endpoint.host == "127.0.0.1")
        #expect(configuration.ipv6Endpoint.host == "::1")
        #expect(configuration.ipv4Endpoint.port == 17_891)
    }

    @Test("GLOBAL and policy-group actions receive distinct forced-route listeners")
    func emitsRouteSpecificListeners() throws {
        let configuration = try NetworkExtensionMihomoListenerConfiguration(
            port: 17_881,
            routePorts: [
                .global: 17_882,
                .group("Auto Select"): 17_883,
            ]
        )

        let result = try RuntimeConfigurationComposer().applying(
            .empty,
            to: Data("rules: []\n".utf8),
            networkExtensionListener: configuration
        )
        let yaml = try #require(String(data: result, encoding: .utf8))

        #expect(yaml.components(separatedBy: "type: socks").count == 7)
        #expect(yaml.components(separatedBy: "port: 17881").count == 3)
        #expect(yaml.components(separatedBy: "port: 17882").count == 3)
        #expect(yaml.components(separatedBy: "port: 17883").count == 3)
        #expect(yaml.components(separatedBy: "proxy: \"GLOBAL\"").count == 3)
        #expect(yaml.components(separatedBy: "proxy: \"Auto Select\"").count == 3)

        let catalog = try MihomoRouteProxyCatalog.decode(
            configuration.encodedRouteProxyCatalog()
        )
        #expect(catalog.map(\.route) == [
            .profileRules,
            .global,
            .group("Auto Select"),
        ])
        #expect(configuration.endpoint(for: .global)?.port == 17_882)
        #expect(configuration.endpoint(for: .group("Auto Select"))?.port == 17_883)
    }

    @Test("An auxiliary profile emits only its exact private routes")
    func emitsAuxiliaryProfileListeners() throws {
        let profileID = RoutingProfileID(
            try #require(UUID(
                uuidString: "0ae18464-82a2-4a9b-a402-ddb8d39e280b"
            ))
        )
        let route = MihomoRoute.profile(profileID, target: .rules)
        let configuration = try NetworkExtensionMihomoListenerConfiguration(
            port: 17_884,
            routePorts: [route: 17_884],
            includesLegacyProfileRules: false
        )

        let result = try RuntimeConfigurationComposer().applying(
            .empty,
            to: Data("rules: []\n".utf8),
            networkExtensionListener: configuration
        )
        let yaml = try #require(String(data: result, encoding: .utf8))

        #expect(configuration.routeListeners.map(\.route) == [route])
        #expect(yaml.components(separatedBy: "type: socks").count == 3)
        #expect(!yaml.contains(NetworkExtensionMihomoListenerConfiguration.ipv4ListenerName))
        #expect(!yaml.contains("proxy:"))
    }

    @Test("Runtime configuration publishes a combined exact-profile catalog")
    func publishesCombinedProfileCatalog() throws {
        let profileID = RoutingProfileID(
            try #require(UUID(
                uuidString: "d111ee2e-da45-41fa-bb7b-c399e66defc2"
            ))
        )
        let route = MihomoRoute.profile(profileID, target: .global)
        let primary = try NetworkExtensionMihomoListenerConfiguration(port: 17_885)
        let auxiliary = try NetworkExtensionMihomoListenerConfiguration(
            port: 17_886,
            routePorts: [route: 17_886],
            includesLegacyProfileRules: false
        )
        let endpoints = try primary.routeProxyEndpoints()
            + auxiliary.routeProxyEndpoints()

        let runtime = try NetworkExtensionRuntimeConfiguration(
            preferences: .defaults(),
            mihomoListener: primary,
            routeProxyEndpoints: endpoints
        )
        let encoded = try #require(runtime.encodedMihomoRouteProxyCatalog)
        let catalog = try MihomoRouteProxyCatalog.decode(encoded)

        #expect(catalog.map(\.route) == [.profileRules, route])
        #expect(catalog.map(\.port) == [17_885, 17_886])
    }

    @Test("Internal listener composes with scalar, DNS, and rule overrides")
    func coexistsWithRuntimeOverrides() throws {
        let profile = Data(
            """
            mixed-port: 7890
            dns: {enable: false}
            rules: ["MATCH,DIRECT"]
            """.utf8
        )
        let overrides = RuntimeOverrides(
            ports: RuntimePortOverrides(mixedPort: 9_090),
            tcpConcurrent: true,
            dns: RuntimeDNSOverrides(enable: true, nameserver: ["1.1.1.1"]),
            prependRules: ["DOMAIN,example.com,DIRECT"]
        )

        let result = try RuntimeConfigurationComposer().applying(
            overrides,
            to: profile,
            networkExtensionListener: try .init(port: 17_892)
        )
        let yaml = try #require(String(data: result, encoding: .utf8))

        #expect(yaml.contains("mixed-port: 9090\n"))
        #expect(yaml.contains("tcp-concurrent: true\n"))
        #expect(yaml.contains("dns:\n  enable: true\n"))
        #expect(yaml.contains("rules: [\"DOMAIN,example.com,DIRECT\", \"MATCH,DIRECT\"]"))
        #expect(yaml.contains("mclash-network-extension-socks-ipv4"))
        #expect(yaml.contains("mclash-network-extension-socks-ipv6"))
    }

    @Test("Optional authentication is scoped to both generated listeners and safely quoted")
    func emitsOptionalAuthentication() throws {
        let authentication = try NetworkExtensionMihomoAuthentication(
            username: "extension:user",
            password: "secret # with \"quotes\" and 雪"
        )
        let configuration = try NetworkExtensionMihomoListenerConfiguration(
            port: 17_893,
            authentication: authentication
        )

        let result = try RuntimeConfigurationComposer().applying(
            .empty,
            to: Data("rules: []\n".utf8),
            networkExtensionListener: configuration
        )
        let yaml = try #require(String(data: result, encoding: .utf8))

        #expect(yaml.components(separatedBy: "username: \"extension:user\"").count == 3)
        #expect(
            yaml.components(
                separatedBy: "password: \"secret # with \\\"quotes\\\" and 雪\""
            ).count == 3
        )
        #expect(!yaml.contains("users: []"))
        #expect(try JSONEncoder().encode(RuntimeOverrides.empty).range(of: Data("secret".utf8)) == nil)
    }

    @Test(
        "Generated listeners append without rewriting existing block listener forms",
        arguments: [
            "listeners:\n  - name: user-http\n    type: http\n    port: 8080\nrules: []\n",
            "listeners:\n- name: user-http\n  type: http\n  port: 8080\nrules: []\n",
        ]
    )
    func appendsToBlockListeners(source: String) throws {
        let result = try RuntimeConfigurationComposer().applying(
            .empty,
            to: Data(source.utf8),
            networkExtensionListener: try .init(port: 17_894)
        )
        let yaml = try #require(String(data: result, encoding: .utf8))

        #expect(yaml.contains("name: user-http"))
        #expect(yaml.contains("type: http"))
        #expect(yaml.contains("port: 8080"))
        #expect(yaml.contains("mclash-network-extension-socks-ipv4"))
        #expect(yaml.contains("mclash-network-extension-socks-ipv6"))
        #expect(yaml.range(of: "name: user-http")!.lowerBound < yaml.range(of: "mclash-network-extension")!.lowerBound)
    }

    @Test("Generated listeners append to an inline listeners sequence")
    func appendsToFlowListeners() throws {
        let source = Data(
            "listeners: [{name: user-http, type: http, port: 8080}]\nrules: []\n".utf8
        )
        let result = try RuntimeConfigurationComposer().applying(
            .empty,
            to: source,
            networkExtensionListener: try .init(port: 17_895)
        )
        let yaml = try #require(String(data: result, encoding: .utf8))

        #expect(yaml.contains("{name: user-http, type: http, port: 8080}"))
        #expect(yaml.contains("\"name\": \"mclash-network-extension-socks-ipv4\""))
        #expect(yaml.contains("\"name\": \"mclash-network-extension-socks-ipv6\""))
        #expect(yaml.contains("\"listen\": \"127.0.0.1\""))
        #expect(yaml.contains("\"listen\": \"::1\""))
        #expect(yaml.contains("\"udp\": true"))
    }

    @Test("No internal listener and empty overrides preserve arbitrary profile bytes exactly")
    func nilListenerIsExactNoOp() throws {
        let profile = Data([0xff, 0x00, 0x01])
        let result = try RuntimeConfigurationComposer().applying(
            .empty,
            to: profile,
            networkExtensionListener: nil
        )
        #expect(result == profile)
    }

    @Test("Managed-session sanitizer removes profile-owned inbound surfaces")
    func sanitizesManagedSessionListenerSurfaces() throws {
        let source = Data(
            """
            mixed-port: 7890
            tun:
              enable: true
              stack: system
            listeners:
              - name: public-http
                type: http
                port: 8080
            tunnels:
              - tcp,0.0.0.0:8081,example.com:443,DIRECT
            ss-config: ss://2022-blake3-aes-256-gcm:secret@:8082
            vmess-config: vmess://1:00000000-0000-0000-0000-000000000000@:8083
            tuic-server:
              enable: true
              listen: 0.0.0.0:8084
            external-controller: 0.0.0.0:9090
            external-controller-tls: 0.0.0.0:9443
            external-controller-unix: /tmp/profile-owned.sock
            external-controller-pipe: profile-owned-pipe
            rules:
              - MATCH,DIRECT
            """.utf8
        )
        let composer = RuntimeConfigurationComposer()
        let sanitized = try composer.sanitizingForManagedSession(source)
        let result = try composer.applying(
            RuntimeOverrides(
                ports: RuntimePortOverrides(
                    port: 0,
                    socksPort: 0,
                    redirPort: 0,
                    tproxyPort: 0,
                    mixedPort: 18_080
                ),
                allowLAN: false,
                bindAddress: "127.0.0.1",
                dns: RuntimeDNSOverrides(enable: false)
            ),
            to: sanitized,
            networkExtensionListener: try .init(port: 18_081)
        )
        let yaml = try #require(String(data: result, encoding: .utf8))

        #expect(!yaml.contains("public-http"))
        #expect(!yaml.contains("tunnels:"))
        #expect(!yaml.contains("ss-config:"))
        #expect(!yaml.contains("vmess-config:"))
        #expect(!yaml.contains("tuic-server:"))
        #expect(!yaml.contains("external-controller:"))
        #expect(!yaml.contains("external-controller-tls:"))
        #expect(!yaml.contains("external-controller-unix:"))
        #expect(!yaml.contains("external-controller-pipe:"))
        #expect(!yaml.contains("profile-owned"))
        #expect(!yaml.contains("stack: system"))
        #expect(!yaml.contains("enable: true"))
        #expect(yaml.contains("rules:\n  - MATCH,DIRECT"))
        #expect(yaml.contains("mixed-port: 18080"))
        #expect(yaml.contains("redir-port: 0"))
        #expect(yaml.contains("tproxy-port: 0"))
        #expect(yaml.contains("allow-lan: false"))
        #expect(yaml.contains("bind-address: \"127.0.0.1\""))
        #expect(yaml.contains("mclash-network-extension-socks-ipv4"))
        #expect(yaml.contains("mclash-network-extension-socks-ipv6"))
    }

    @Test("Managed-session sanitizer fails closed on root merges")
    func managedSessionSanitizerRejectsRootMerge() {
        let source = Data(
            """
            defaults: &defaults
              listeners:
                - name: hidden
                  type: mixed
                  port: 62030
            <<: *defaults
            rules: []
            """.utf8
        )

        #expect(
            throws: RuntimeConfigurationComposerError
                .unsupportedBoundListenerSyntax("root mapping")
        ) {
            try RuntimeConfigurationComposer()
                .sanitizingForManagedSession(source)
        }
    }

    @Test("Port and RFC 1929 credential byte limits are enforced")
    func validatesConfiguration() throws {
        #expect(throws: NetworkExtensionMihomoListenerValidationError.invalidPort(0)) {
            try NetworkExtensionMihomoListenerConfiguration(port: 0)
        }
        #expect(throws: NetworkExtensionMihomoListenerValidationError.invalidPort(65_536)) {
            try NetworkExtensionMihomoListenerConfiguration(port: 65_536)
        }
        #expect(throws: NetworkExtensionMihomoListenerValidationError.duplicatePort(17_899)) {
            try NetworkExtensionMihomoListenerConfiguration(
                port: 17_899,
                routePorts: [.global: 17_899]
            )
        }
        #expect(
            throws: NetworkExtensionMihomoListenerValidationError.invalidCredentialLength(
                field: .username,
                utf8ByteCount: 0
            )
        ) {
            try NetworkExtensionMihomoAuthentication(username: "", password: "secret")
        }
        #expect(
            throws: NetworkExtensionMihomoListenerValidationError.invalidCredentialLength(
                field: .password,
                utf8ByteCount: 256
            )
        ) {
            try NetworkExtensionMihomoAuthentication(
                username: "extension",
                password: String(repeating: "x", count: 256)
            )
        }
        #expect(
            throws: NetworkExtensionMihomoListenerValidationError.invalidCredentialCharacters(
                field: .password
            )
        ) {
            try NetworkExtensionMihomoAuthentication(username: "extension", password: "bad\nsecret")
        }
    }

    @Test("Ambiguous or colliding profile listeners fail closed instead of corrupting YAML")
    func rejectsUnsafeListenerSources() throws {
        let composer = RuntimeConfigurationComposer()
        let configuration = try NetworkExtensionMihomoListenerConfiguration(port: 17_896)

        #expect(throws: RuntimeConfigurationComposerError.multipleListenersSectionsUnsupported) {
            try composer.applying(
                .empty,
                to: Data("listeners: []\nlisteners: []\n".utf8),
                networkExtensionListener: configuration
            )
        }
        #expect(throws: RuntimeConfigurationComposerError.listenersSectionMustBeSequence) {
            try composer.applying(
                .empty,
                to: Data("listeners: {name: invalid-map}\n".utf8),
                networkExtensionListener: configuration
            )
        }
        #expect(
            throws: RuntimeConfigurationComposerError.reservedListenerNameConflict(
                NetworkExtensionMihomoListenerConfiguration.ipv4ListenerName
            )
        ) {
            try composer.applying(
                .empty,
                to: Data(
                    "listeners:\n  - name: mclash-network-extension-socks-ipv4\n".utf8
                ),
                networkExtensionListener: configuration
            )
        }
    }

    @Test("Coordinator validates and stages the exact internal listener overlay")
    func coordinatorComposesInternalListenerWithoutMutatingProfile() async throws {
        let fixture = try ListenerFixture()
        defer { fixture.remove() }
        let profileStore = try ProfileStore(layout: fixture.profileLayout)
        let source = Data(
            """
            mixed-port: 7890
            redir-port: 7891
            dns:
              enable: true
              listen: 127.0.0.1:1053
            tun:
              enable: true
            listeners:
              - name: profile-owned
                type: mixed
                port: 62031
            tunnels:
              - tcp,127.0.0.1:62032,example.com:443,DIRECT
            external-controller: 127.0.0.1:62033
            rules: []
            """.utf8
        )
        let profile = try await profileStore.createLocalProfile(name: "Original", yaml: source)
        let validator = ListenerRecordingValidator()
        let coordinator = RuntimeOverrideActivationCoordinator(overrideStore: fixture.overrideStore)
        let configuration = try NetworkExtensionMihomoListenerConfiguration(port: 17_897)

        let activation = try await coordinator.activateProfile(
            profile.id,
            networkExtensionListener: configuration,
            in: profileStore,
            validator: validator
        )

        #expect(activation.profileID == profile.id)
        #expect(try await profileStore.configurationData(for: profile.id) == source)
        let runtime = try Data(contentsOf: fixture.profileLayout.runtimeConfigurationURL)
        #expect(await validator.validatedData == [runtime])
        let yaml = try #require(String(data: runtime, encoding: .utf8))
        #expect(yaml.contains("listen: \"127.0.0.1\""))
        #expect(yaml.contains("listen: \"::1\""))
        #expect(yaml.components(separatedBy: "udp: true").count == 3)
        #expect(yaml.contains("redir-port: 7891"))
        #expect(yaml.contains("listen: 127.0.0.1:1053"))
        #expect(!yaml.contains("profile-owned"))
        #expect(!yaml.contains("tunnels:"))
        #expect(!yaml.contains("external-controller:"))
        #expect(!yaml.contains("enable: true\nlisteners:"))
    }
}

private struct ListenerFixture {
    let root: URL
    let profileLayout: ProfileDirectoryLayout
    let overrideStore: RuntimeOverrideStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NetworkExtensionMihomoListenerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        profileLayout = ProfileDirectoryLayout(rootDirectory: root.appendingPathComponent("MClash"))
        try profileLayout.createDirectories()
        overrideStore = try RuntimeOverrideStore(profileLayout: profileLayout)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ListenerRecordingValidator: ProfileValidating {
    private(set) var validatedData: [Data] = []

    func validate(configurationAt url: URL) throws {
        validatedData.append(try Data(contentsOf: url))
    }
}
