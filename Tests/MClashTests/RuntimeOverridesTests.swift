import Foundation
import Testing
@testable import MClashApp

@Suite("Runtime Overrides")
struct RuntimeOverridesTests {
    @Test("Only HTTP, SOCKS5, and Mixed count as explicit local proxy listeners")
    func detectsExplicitLocalProxyListenerOverrides() {
        #expect(!RuntimePortOverrides().hasExplicitLocalProxyListener)
        #expect(!RuntimePortOverrides(redirPort: 7_892, tproxyPort: 7_893).hasExplicitLocalProxyListener)
        #expect(RuntimePortOverrides(port: 0).hasExplicitLocalProxyListener)
        #expect(RuntimePortOverrides(socksPort: 7_891).hasExplicitLocalProxyListener)
        #expect(RuntimePortOverrides(mixedPort: 7_890).hasExplicitLocalProxyListener)
    }

    @Test("Store persists a versioned private document and reloads it")
    func storePersistsPrivateVersionedDocument() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let overrides = RuntimeOverrides(
            ports: RuntimePortOverrides(port: 7_890, mixedPort: 7_893),
            allowLAN: true,
            bindAddress: "127.0.0.1",
            ipv6: false,
            sniffing: true,
            tcpConcurrent: true,
            findProcessMode: "strict",
            interfaceName: "en0",
            logLevel: "warning",
            dns: RuntimeDNSOverrides(
                enable: true,
                enhancedMode: .fakeIP,
                nameserver: ["https://1.1.1.1/dns-query"],
                respectRules: true
            ),
            prependRules: ["DOMAIN-SUFFIX,internal.example,DIRECT"],
            appendRules: ["MATCH,REJECT"]
        )

        try await fixture.store.save(overrides)
        #expect(try await fixture.store.load() == overrides)

        let data = try Data(contentsOf: fixture.storageLayout.overridesURL)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == RuntimeOverrideStore.currentSchemaVersion)
        #expect(object["overrides"] != nil)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.storageLayout.overridesURL.path
        )
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test("Missing storage and schema zero documents migrate to current values")
    func legacyDocumentsAreCompatible() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(try await fixture.store.load() == .empty)

        let legacy = Data(
            """
            {
              "ports": { "socksPort": 7891 },
              "allowLAN": true,
              "logLevel": "debug"
            }
            """.utf8
        )
        try legacy.write(to: fixture.storageLayout.overridesURL)

        let loaded = try await fixture.store.load()
        #expect(loaded.ports.socksPort == 7_891)
        #expect(loaded.allowLAN == true)
        #expect(loaded.logLevel == "debug")
        #expect(loaded.prependRules == nil)
        #expect(loaded.appendRules == nil)
    }

    @Test("A wrapped schema zero document is also accepted")
    func wrappedLegacyDocumentIsCompatible() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let legacy = Data(
            """
            {
              "overrides": {
                "ports": { "redirPort": 7892 },
                "ipv6": true
              }
            }
            """.utf8
        )
        try legacy.write(to: fixture.storageLayout.overridesURL)

        let loaded = try await fixture.store.load()
        #expect(loaded.ports.redirPort == 7_892)
        #expect(loaded.ipv6 == true)
        #expect(loaded.dns == nil)
    }

    @Test("Schema one documents without DNS remain compatible")
    func schemaOneWithoutDNSIsCompatible() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data(
            """
            {
              "schemaVersion": 1,
              "overrides": {
                "ports": { "mixedPort": 7890 },
                "allowLAN": false
              }
            }
            """.utf8
        ).write(to: fixture.storageLayout.overridesURL)

        let loaded = try await fixture.store.load()
        #expect(loaded.ports.mixedPort == 7_890)
        #expect(loaded.allowLAN == false)
        #expect(loaded.dns == nil)
    }

    @Test("Future schema versions are rejected instead of overwritten")
    func futureSchemaIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("{\"schemaVersion\":999,\"overrides\":{}}".utf8)
            .write(to: fixture.storageLayout.overridesURL)

        await #expect(throws: RuntimeOverrideStoreError.unsupportedSchemaVersion(999)) {
            _ = try await fixture.store.load()
        }
    }

    @Test("Composer replaces root scalars and preserves profile-owned sections")
    func composerLayersAllSupportedFields() throws {
        let profile = Data(
            """
            ---
            # subscription comment
            mixed-port: 7890
            allow-lan: false
            bind-address: "*"
            ipv6: true
            sniffing: false
            tcp-concurrent: false
            find-process-mode: off
            interface-name: en1
            log-level: info
            proxies:
              - name: keep-me
                type: direct
            rules:
              - MATCH,DIRECT
            ...
            """.utf8
        )
        let overrides = RuntimeOverrides(
            ports: RuntimePortOverrides(
                port: 7_891,
                socksPort: 7_892,
                redirPort: 0,
                tproxyPort: 0,
                mixedPort: 7_893
            ),
            allowLAN: true,
            bindAddress: "127.0.0.1",
            ipv6: false,
            sniffing: true,
            tcpConcurrent: true,
            findProcessMode: "strict",
            interfaceName: "en0: uplink",
            logLevel: "debug"
        )

        let result = try RuntimeConfigurationComposer().applying(overrides, to: profile)
        let yaml = try #require(String(data: result, encoding: .utf8))

        #expect(yaml.contains("# subscription comment"))
        #expect(yaml.contains("proxies:\n  - name: keep-me"))
        #expect(yaml.contains("rules:\n  - MATCH,DIRECT"))
        #expect(yaml.contains("port: 7891\n"))
        #expect(yaml.contains("socks-port: 7892\n"))
        #expect(yaml.contains("mixed-port: 7893\n"))
        #expect(yaml.contains("allow-lan: true\n"))
        #expect(yaml.contains("bind-address: \"127.0.0.1\"\n"))
        #expect(yaml.contains("interface-name: \"en0: uplink\"\n"))
        #expect(yaml.contains("log-level: \"debug\"\n"))
        #expect(yaml.range(of: "mixed-port:") == yaml.range(of: "mixed-port:", options: .backwards))
        #expect(yaml.range(of: "allow-lan:") == yaml.range(of: "allow-lan:", options: .backwards))
        #expect(yaml.range(of: "...\n")?.lowerBound ?? yaml.endIndex > yaml.range(of: "log-level:")!.lowerBound)
    }

    @Test("Empty overrides preserve profile bytes exactly")
    func emptyOverridesAreNoOp() throws {
        let profile = Data([0xff, 0x00, 0x01])
        let result = try RuntimeConfigurationComposer().applying(.empty, to: profile)
        #expect(result == profile)
    }

    @Test("Profile listener ports are read before overrides")
    func readsProfileListenerPorts() throws {
        let profile = Data(
            """
            port: 7890 # HTTP
            socks-port: "7891"
            mixed-port: 7_892
            redir-port: 7893
            """.utf8
        )

        let ports = try RuntimeConfigurationComposer().listenerPorts(in: profile)
        #expect(ports.port == 7_890)
        #expect(ports.socksPort == 7_891)
        #expect(ports.mixedPort == 7_892)
        #expect(ports.redirPort == nil)
        #expect(ports.tproxyPort == nil)
    }

    @Test("Bound-port scan covers advanced DNS and custom listeners only")
    func scansEveryPrimaryBoundPort() throws {
        let configuration = Data(
            #"""
            port: 0
            socks-port: 0
            mixed-port: 7890
            redir-port: !!int 7891
            tproxy-port: 7892
            "\u0065xternal-controller": "127.0.0.1\u003a9090"
            dns:
              enable: true
              listen: !!str "0.0.0.0:1053"
            listeners:
              - name: custom-http
                type: http
                port: 18080/18082-18083
              - {name: custom-socks, type: socks, port: "18081"}
              - name: tagged-mixed
                type: mixed
                port: !!int 18084
            ss-config: ss://YWVzLTI1Ni1nY206cGFzc3dvcmRAMTI3LjAuMC4xOjYyMDA1
            vmess-config: vmess://1:00000000-0000-0000-0000-000000000000@:12345
            tuic-server:
              enable: true
              listen: 127.0.0.1:10443
            tunnels:
              - tcp/udp,127.0.0.1:6553,8.8.8.8:53,DIRECT
              - network: [tcp, udp]
                address: 127.0.0.1:7777
                target: 8.8.4.4:53
            proxies:
              - name: remote
                type: socks5
                server: example.com
                port: 443
            """#.utf8
        )

        let ports = try RuntimeConfigurationComposer()
            .boundListenerPorts(in: configuration)

        #expect(
            ports == [
                6553, 7777, 7890, 7891, 7892, 9090, 10443, 1053,
                12345, 18080, 18081, 18082, 18083, 18084, 62005,
            ]
        )
        #expect(!ports.contains(443))
        #expect(!ports.contains(53))
    }

    @Test("Bound-port scan handles inline DNS maps")
    func scansInlineDNSListen() throws {
        let configuration = Data(
            "mixed-port: 7890\ndns: {enable: true, listen: '[::1]:5353'}\n".utf8
        )
        #expect(
            try RuntimeConfigurationComposer()
                .boundListenerPorts(in: configuration) == [7890, 5353]
        )
    }

    @Test("Bound-port scan normalizes reverse listener ranges and rejects ephemeral ports")
    func validatesListenerPortSpecifications() throws {
        let reverseRange = Data(
            """
            listeners:
              - name: reverse-range
                type: mixed
                port: 62042-62040
            """.utf8
        )
        #expect(
            try RuntimeConfigurationComposer()
                .boundListenerPorts(in: reverseRange) == [62040, 62041, 62042]
        )

        for invalidSpecification in ["0", "65536", "62040,,62041"] {
            let configuration = Data(
                """
                listeners:
                  - name: invalid
                    type: mixed
                    port: \(invalidSpecification)
                """.utf8
            )
            #expect(
                throws: RuntimeConfigurationComposerError
                    .unsupportedBoundListenerSyntax("listeners.port")
            ) {
                try RuntimeConfigurationComposer()
                    .boundListenerPorts(in: configuration)
            }
        }
    }

    @Test("Bound-port scan fails closed for merged or block-scalar bindings")
    func rejectsUnexpandedBindingSyntax() {
        let composer = RuntimeConfigurationComposer()
        let mergedDNS = Data(
            """
            dns-template: &dns-template
              enable: true
              listen: 127.0.0.1:62015
            dns: {<<: *dns-template}
            """.utf8
        )
        #expect(
            throws: RuntimeConfigurationComposerError
                .unsupportedBoundListenerSyntax("dns.<<")
        ) {
            try composer.boundListenerPorts(in: mergedDNS)
        }

        let blockDNS = Data(
            """
            dns:
              enable: true
              listen: >-
                127.0.0.1:62016
            """.utf8
        )
        #expect(
            throws: RuntimeConfigurationComposerError
                .unsupportedBoundListenerSyntax("dns.listen")
        ) {
            try composer.boundListenerPorts(in: blockDNS)
        }

        let escapedMultilineDNS = Data(
            #"""
            dns:
              enable: true
              listen: "127.0.0.1:620\
                34"
            """#.utf8
        )
        #expect(
            throws: RuntimeConfigurationComposerError
                .unsupportedBoundListenerSyntax("dns.listen")
        ) {
            try composer.boundListenerPorts(in: escapedMultilineDNS)
        }

        let foldedPlainDNS = Data(
            """
            dns:
              enable: true
              listen: 127.0.0.1:620
                35
            """.utf8
        )
        #expect(
            throws: RuntimeConfigurationComposerError
                .unsupportedBoundListenerSyntax("dns.listen")
        ) {
            try composer.boundListenerPorts(in: foldedPlainDNS)
        }

        let outOfRangeDNS = Data(
            """
            dns:
              enable: true
              listen: 127.0.0.1:99999
            """.utf8
        )
        #expect(
            throws: RuntimeConfigurationComposerError
                .unsupportedBoundListenerSyntax("dns.listen")
        ) {
            try composer.boundListenerPorts(in: outOfRangeDNS)
        }

        let aliasedListener = Data(
            """
            listener-template: &listener-template
              name: aliased
              type: mixed
              port: 62017
            listeners:
              - *listener-template
            """.utf8
        )
        #expect(
            throws: RuntimeConfigurationComposerError
                .unsupportedBoundListenerSyntax("listeners alias")
        ) {
            try composer.boundListenerPorts(in: aliasedListener)
        }

        let rootMerge = Data(
            """
            defaults: &defaults
              mixed-port: 62018
            <<: *defaults
            """.utf8
        )
        #expect(
            throws: RuntimeConfigurationComposerError
                .unsupportedBoundListenerSyntax("root mapping")
        ) {
            try composer.boundListenerPorts(in: rootMerge)
        }

        let scalarAlias = Data(
            """
            shared-port: &shared-port 62019
            redir-port: *shared-port
            """.utf8
        )
        #expect(
            throws: RuntimeConfigurationComposerError
                .unsupportedBoundListenerSyntax("redir-port")
        ) {
            try composer.boundListenerPorts(in: scalarAlias)
        }

        let escapedBindingKey = Data(
            #"""
            listeners:
              - name: escaped-key
                type: mixed
                "po\u0072t": 62020
            """#.utf8
        )
        #expect(
            throws: RuntimeConfigurationComposerError
                .unsupportedBoundListenerSyntax("listeners mapping key")
        ) {
            try composer.boundListenerPorts(in: escapedBindingKey)
        }

        let nonDecimalPort = Data(
            """
            listeners:
              - name: non-decimal
                type: mixed
                port: 0xF245
            """.utf8
        )
        #expect(
            throws: RuntimeConfigurationComposerError
                .unsupportedBoundListenerSyntax("listeners.port")
        ) {
            try composer.boundListenerPorts(in: nonDecimalPort)
        }

        let blockTunnel = Data(
            """
            tunnels:
              - >-
                tcp,127.0.0.1:62021,example.com:443,DIRECT
            """.utf8
        )
        #expect(
            throws: RuntimeConfigurationComposerError
                .unsupportedBoundListenerSyntax("tunnels compact scalar")
        ) {
            try composer.boundListenerPorts(in: blockTunnel)
        }

        let keyProperty = Data(
            """
            listeners:
              - name: key-property
                type: mixed
                &binding-key port: 62022
            """.utf8
        )
        #expect(
            throws: RuntimeConfigurationComposerError
                .unsupportedBoundListenerSyntax("listeners mapping key")
        ) {
            try composer.boundListenerPorts(in: keyProperty)
        }

        let leadingZeroInteger = Data(
            """
            mixed-port: 0777
            """.utf8
        )
        #expect(
            throws: RuntimeConfigurationComposerError
                .unsupportedBoundListenerSyntax("mixed-port")
        ) {
            try composer.boundListenerPorts(in: leadingZeroInteger)
        }

        let listenerLeadingZeroInteger = Data(
            """
            listeners:
              - name: octal
                type: mixed
                port: !!int "0_777"
            """.utf8
        )
        #expect(
            throws: RuntimeConfigurationComposerError
                .unsupportedBoundListenerSyntax(
                    "listeners.port leading-zero integer"
                )
        ) {
            try composer.boundListenerPorts(in: listenerLeadingZeroInteger)
        }
    }

    @Test("Nil and empty rule layers have explicit no-op persistence semantics")
    func emptyRuleLayersAreNoOpButRemainPersisted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let overrides = RuntimeOverrides(prependRules: [], appendRules: [])
        let profile = Data([0xff, 0x00, 0x01])

        #expect(overrides.isEmpty)
        #expect(try RuntimeConfigurationComposer().applying(overrides, to: profile) == profile)
        try await fixture.store.save(overrides)
        let loaded = try await fixture.store.load()
        #expect(loaded.prependRules == [])
        #expect(loaded.appendRules == [])
        #expect(RuntimeOverrides().prependRules == nil)
        #expect(RuntimeOverrides().appendRules == nil)
    }

    @Test("Rule composer handles indented, indentless, and inline sequences")
    func composerLayersRuleSourceForms() throws {
        let prepend = "DOMAIN-SUFFIX,internal.example,DIRECT"
        let append = "DOMAIN-KEYWORD,release#candidate:1,REJECT"
        let cases: [(source: String, expected: String)] = [
            (
                "rules:\n  - MATCH,DIRECT\nproxies: []\n",
                "rules:\n  - \"DOMAIN-SUFFIX,internal.example,DIRECT\"\n"
                    + "  - MATCH,DIRECT\n"
                    + "  - \"DOMAIN-KEYWORD,release#candidate:1,REJECT\"\n"
                    + "proxies: []\n"
            ),
            (
                "rules:\n- MATCH,DIRECT\nproxies: []\n",
                "rules:\n- \"DOMAIN-SUFFIX,internal.example,DIRECT\"\n"
                    + "- MATCH,DIRECT\n"
                    + "- \"DOMAIN-KEYWORD,release#candidate:1,REJECT\"\n"
                    + "proxies: []\n"
            ),
            (
                "rules: [\"MATCH,DIRECT\"]\nproxies: []\n",
                "rules: [\"DOMAIN-SUFFIX,internal.example,DIRECT\", \"MATCH,DIRECT\", "
                    + "\"DOMAIN-KEYWORD,release#candidate:1,REJECT\"]\nproxies: []\n"
            ),
        ]
        let overrides = RuntimeOverrides(prependRules: [prepend], appendRules: [append])

        for item in cases {
            let result = try RuntimeConfigurationComposer().applying(
                overrides,
                to: Data(item.source.utf8)
            )
            #expect(String(data: result, encoding: .utf8) == item.expected)
        }
    }

    @Test("Rule composer creates a top-level sequence when the profile has none")
    func composerCreatesMissingRulesSectionBeforeDocumentEnd() throws {
        let profile = Data("---\nmixed-port: 7890\n...\n".utf8)
        let overrides = RuntimeOverrides(
            prependRules: ["DOMAIN,example.com,DIRECT"],
            appendRules: ["MATCH,REJECT"]
        )

        let result = try RuntimeConfigurationComposer().applying(overrides, to: profile)
        let yaml = try #require(String(data: result, encoding: .utf8))
        #expect(
            yaml == "---\nmixed-port: 7890\nrules:\n"
                + "  - \"DOMAIN,example.com,DIRECT\"\n"
                + "  - \"MATCH,REJECT\"\n...\n"
        )
    }

    @Test("Rule composer coexists with scalar and DNS replacements")
    func composerLayersRulesWithOtherOverrides() throws {
        let profile = Data(
            "mixed-port: 7890\ndns: {enable: false}\nrules: [\"MATCH,DIRECT\"]\n".utf8
        )
        let overrides = RuntimeOverrides(
            ports: RuntimePortOverrides(mixedPort: 9_090),
            dns: RuntimeDNSOverrides(enable: true, nameserver: ["1.1.1.1"]),
            prependRules: ["DOMAIN,example.com,DIRECT"],
            appendRules: ["MATCH,REJECT"]
        )

        let result = try RuntimeConfigurationComposer().applying(overrides, to: profile)
        let yaml = try #require(String(data: result, encoding: .utf8))
        #expect(
            yaml.contains(
                "rules: [\"DOMAIN,example.com,DIRECT\", \"MATCH,DIRECT\", \"MATCH,REJECT\"]\n"
            )
        )
        #expect(yaml.contains("mixed-port: 9090\n"))
        #expect(yaml.contains("dns:\n  enable: true\n  nameserver:\n    - \"1.1.1.1\"\n"))
    }

    @Test("DNS composer emits every supported field")
    func composerEmitsSupportedDNSFields() throws {
        let profile = Data("mixed-port: 7890\nrules:\n  - MATCH,DIRECT\n".utf8)
        let overrides = RuntimeOverrides(
            dns: RuntimeDNSOverrides(
                enable: true,
                listen: "0.0.0.0:1053",
                ipv6: false,
                enhancedMode: .fakeIP,
                fakeIPRange: "198.18.0.1/16",
                fakeIPFilter: ["*.lan", "+.local"],
                defaultNameserver: ["223.5.5.5"],
                nameserver: ["https://1.1.1.1/dns-query"],
                fallback: [],
                proxyServerNameserver: ["tls://8.8.8.8"],
                directNameserver: ["system"],
                respectRules: true,
                useHosts: false,
                useSystemHosts: true,
                preferH3: true
            )
        )

        let result = try RuntimeConfigurationComposer().applying(overrides, to: profile)
        let yaml = try #require(String(data: result, encoding: .utf8))
        #expect(yaml.contains("dns:\n  enable: true\n"))
        #expect(yaml.contains("  listen: \"0.0.0.0:1053\"\n"))
        #expect(yaml.contains("  enhanced-mode: \"fake-ip\"\n"))
        #expect(yaml.contains("  fake-ip-range: \"198.18.0.1/16\"\n"))
        #expect(yaml.contains("  fake-ip-filter:\n    - \"*.lan\"\n    - \"+.local\"\n"))
        #expect(yaml.contains("  default-nameserver:\n    - \"223.5.5.5\"\n"))
        #expect(yaml.contains("  nameserver:\n    - \"https://1.1.1.1/dns-query\"\n"))
        #expect(yaml.contains("  fallback: []\n"))
        #expect(yaml.contains("  proxy-server-nameserver:\n    - \"tls://8.8.8.8\"\n"))
        #expect(yaml.contains("  direct-nameserver:\n    - \"system\"\n"))
        #expect(yaml.contains("  respect-rules: true\n"))
        #expect(yaml.contains("  use-hosts: false\n"))
        #expect(yaml.contains("  use-system-hosts: true\n"))
        #expect(yaml.contains("  prefer-h3: true\n"))
        #expect(yaml.contains("rules:\n  - MATCH,DIRECT\n"))
    }

    @Test(
        "DNS replacement handles block, indentless sequence, and inline map source forms",
        arguments: [
            "dns:\n  enable: false\n  nameserver:\n    - 8.8.8.8\n",
            "dns:\n  nameserver:\n  - 8.8.8.8\n  - 1.1.1.1\n",
            "dns: {enable: false, nameserver: [8.8.8.8, 1.1.1.1]}\n",
            "dns: {\n  enable: false,\n  nameserver: [8.8.8.8]\n}\n",
        ]
    )
    func dnsSourceFormsAreReplaced(sourceDNS: String) throws {
        let profile = Data(
            ("mixed-port: 7890\n" + sourceDNS + "proxies:\n  - name: keep-me\n").utf8
        )
        let overrides = RuntimeOverrides(
            dns: RuntimeDNSOverrides(enable: true, nameserver: ["https://dns.example/dns-query"])
        )

        let result = try RuntimeConfigurationComposer().applying(overrides, to: profile)
        let yaml = try #require(String(data: result, encoding: .utf8))
        #expect(yaml.contains("mixed-port: 7890\n"))
        #expect(yaml.contains("proxies:\n  - name: keep-me\n"))
        #expect(yaml.contains("dns:\n  enable: true\n"))
        #expect(yaml.contains("https://dns.example/dns-query"))
        #expect(!yaml.contains("8.8.8.8"))
        #expect(!yaml.contains("1.1.1.1"))
        #expect(yaml.range(of: "dns:") == yaml.range(of: "dns:", options: .backwards))
    }

    @Test("A present empty DNS override intentionally clears the profile section")
    func emptyDNSSectionIsAuthoritative() throws {
        let profile = Data("dns: {enable: true}\nrules:\n  - MATCH,DIRECT\n".utf8)
        let result = try RuntimeConfigurationComposer().applying(
            RuntimeOverrides(dns: RuntimeDNSOverrides()),
            to: profile
        )
        let yaml = try #require(String(data: result, encoding: .utf8))
        #expect(yaml.contains("dns: {}\n"))
        #expect(!yaml.contains("enable: true"))
        #expect(yaml.contains("rules:\n  - MATCH,DIRECT\n"))
    }

    @Test("Invalid ports and unsafe scalar lines are rejected before saving")
    func invalidValuesAreRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        await #expect(
            throws: RuntimeOverrideValidationError.invalidPort(field: "mixed-port", value: 70_000)
        ) {
            try await fixture.store.save(
                RuntimeOverrides(ports: RuntimePortOverrides(mixedPort: 70_000))
            )
        }
        await #expect(
            throws: RuntimeOverrideValidationError.invalidScalar(field: "interface-name")
        ) {
            try await fixture.store.save(RuntimeOverrides(interfaceName: "en0\ninjected"))
        }
        await #expect(
            throws: RuntimeOverrideValidationError.invalidScalar(field: "dns.nameserver")
        ) {
            try await fixture.store.save(
                RuntimeOverrides(dns: RuntimeDNSOverrides(nameserver: ["1.1.1.1\nmalicious"]))
            )
        }
        await #expect(
            throws: RuntimeOverrideValidationError.invalidScalar(field: "rules.prepend")
        ) {
            try await fixture.store.save(
                RuntimeOverrides(prependRules: ["MATCH,DIRECT\ninjected: true"])
            )
        }
    }

    @Test("Coordinator validates and activates composed YAML without changing the profile")
    func coordinatorActivatesComposedRuntime() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let profileStore = try ProfileStore(layout: fixture.profileLayout)
        let source = Data("mixed-port: 7890\nrules:\n  - MATCH,DIRECT\n".utf8)
        let profile = try await profileStore.createLocalProfile(name: "Original", yaml: source)
        try await fixture.store.save(
            RuntimeOverrides(
                ports: RuntimePortOverrides(mixedPort: 9_090),
                tcpConcurrent: true,
                dns: RuntimeDNSOverrides(
                    enable: true,
                    nameserver: ["https://dns.example/dns-query"]
                ),
                prependRules: ["DOMAIN,example.com,DIRECT"],
                appendRules: ["MATCH,REJECT"]
            )
        )
        let validator = RuntimeRecordingValidator()
        let coordinator = RuntimeOverrideActivationCoordinator(overrideStore: fixture.store)

        let activation = try await coordinator.activateProfile(
            profile.id,
            in: profileStore,
            validator: validator
        )

        #expect(activation.profileID == profile.id)
        #expect(try await profileStore.configurationData(for: profile.id) == source)
        #expect(try await profileStore.activeProfileID() == profile.id)
        let runtime = try Data(contentsOf: fixture.profileLayout.runtimeConfigurationURL)
        let validated = await validator.validatedData
        #expect(validated == [runtime])
        let yaml = try #require(String(data: runtime, encoding: .utf8))
        #expect(yaml.contains("mixed-port: 9090\n"))
        #expect(yaml.contains("tcp-concurrent: true\n"))
        #expect(yaml.contains("dns:\n  enable: true\n"))
        #expect(yaml.contains("    - \"https://dns.example/dns-query\"\n"))
        #expect(yaml.contains("rules:\n  - \"DOMAIN,example.com,DIRECT\"\n"))
        #expect(yaml.contains("  - MATCH,DIRECT\n  - \"MATCH,REJECT\"\n"))
    }

    @Test("Candidate validation does not change the durable overrides or active runtime")
    func coordinatorPreflightsExplicitCandidateWithoutMutation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let profileStore = try ProfileStore(layout: fixture.profileLayout)
        let profile = try await profileStore.createLocalProfile(
            name: "Original",
            yaml: Data("mixed-port: 7890\n".utf8)
        )
        _ = try await profileStore.activateProfile(
            profile.id,
            validator: RuntimeRecordingValidator()
        )
        let previousRuntime = try Data(contentsOf: fixture.profileLayout.runtimeConfigurationURL)
        let stored = RuntimeOverrides(ports: RuntimePortOverrides(mixedPort: 9_090))
        try await fixture.store.save(stored)
        let validator = RuntimeRecordingValidator()
        let coordinator = RuntimeOverrideActivationCoordinator(overrideStore: fixture.store)

        try await coordinator.validateProfile(
            profile.id,
            overrides: RuntimeOverrides(ports: RuntimePortOverrides(mixedPort: 9_191)),
            in: profileStore,
            validator: validator
        )

        #expect(try await fixture.store.load() == stored)
        #expect(try Data(contentsOf: fixture.profileLayout.runtimeConfigurationURL) == previousRuntime)
        let validations = await validator.validatedData
        let validated = try #require(validations.first)
        #expect(String(decoding: validated, as: UTF8.self).contains("mixed-port: 9191\n"))
    }

    @Test("Explicit activation uses the candidate instead of the stored override")
    func coordinatorActivatesExplicitCandidate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let profileStore = try ProfileStore(layout: fixture.profileLayout)
        let profile = try await profileStore.createLocalProfile(
            name: "Original",
            yaml: Data("mixed-port: 7890\n".utf8)
        )
        let stored = RuntimeOverrides(ports: RuntimePortOverrides(mixedPort: 9_090))
        try await fixture.store.save(stored)
        let coordinator = RuntimeOverrideActivationCoordinator(overrideStore: fixture.store)

        _ = try await coordinator.activateProfile(
            profile.id,
            overrides: RuntimeOverrides(ports: RuntimePortOverrides(mixedPort: 9_191)),
            in: profileStore,
            validator: RuntimeRecordingValidator()
        )

        #expect(try await fixture.store.load() == stored)
        let runtime = try Data(contentsOf: fixture.profileLayout.runtimeConfigurationURL)
        #expect(String(decoding: runtime, as: UTF8.self).contains("mixed-port: 9191\n"))
    }

    @Test("Rejected composed YAML leaves the previous runtime and active profile intact")
    func coordinatorRollsBackRejectedRuntime() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let profileStore = try ProfileStore(layout: fixture.profileLayout)
        let first = try await profileStore.createLocalProfile(
            name: "First",
            yaml: Data("mixed-port: 7890\n".utf8)
        )
        let second = try await profileStore.createLocalProfile(
            name: "Second",
            yaml: Data("mixed-port: 7891\n".utf8)
        )
        _ = try await profileStore.activateProfile(first.id, validator: RuntimeRecordingValidator())
        let previousRuntime = try Data(contentsOf: fixture.profileLayout.runtimeConfigurationURL)
        try await fixture.store.save(
            RuntimeOverrides(ports: RuntimePortOverrides(mixedPort: 9_090))
        )
        let coordinator = RuntimeOverrideActivationCoordinator(overrideStore: fixture.store)

        await #expect(throws: RuntimeRejectedConfiguration.self) {
            _ = try await coordinator.activateProfile(
                second.id,
                in: profileStore,
                validator: RuntimeRejectingValidator()
            )
        }

        #expect(try await profileStore.activeProfileID() == first.id)
        #expect(try Data(contentsOf: fixture.profileLayout.runtimeConfigurationURL) == previousRuntime)
    }
}

private struct Fixture {
    let root: URL
    let profileLayout: ProfileDirectoryLayout
    let storageLayout: RuntimeOverrideStorageLayout
    let store: RuntimeOverrideStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RuntimeOverridesTests-\(UUID().uuidString)",
            isDirectory: true
        )
        profileLayout = ProfileDirectoryLayout(rootDirectory: root.appendingPathComponent("MClash"))
        try profileLayout.createDirectories()
        storageLayout = RuntimeOverrideStorageLayout(applicationRoot: profileLayout.rootDirectory)
        store = try RuntimeOverrideStore(profileLayout: profileLayout)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor RuntimeRecordingValidator: ProfileValidating {
    private(set) var validatedData: [Data] = []

    func validate(configurationAt url: URL) throws {
        validatedData.append(try Data(contentsOf: url))
    }
}

private struct RuntimeRejectingValidator: ProfileValidating {
    func validate(configurationAt url: URL) throws {
        throw RuntimeRejectedConfiguration()
    }
}

private struct RuntimeRejectedConfiguration: Error {}
