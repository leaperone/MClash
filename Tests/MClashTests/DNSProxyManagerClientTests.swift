import Foundation
import MClashNetworkShared
import Testing
@testable import MClashApp

@Suite("DNS proxy manager preferences")
struct DNSProxyManagerClientTests {
    @Test("Enable prepares IPC, persists the bootstrap, and verifies operational status")
    func enablePersistsAndReadsBackActivation() async throws {
        let channel = StubDNSRuntimeChannel()
        let preferences = StubDNSProxyPreferences(runtimeChannel: channel)
        let configuration = try Self.configuration(revision: 41)
        let manager = AppleDNSProxyManager(
            preferences: preferences,
            runtimeChannel: channel,
            operationalStatusTimeout: .milliseconds(100),
            operationalStatusPollInterval: .milliseconds(1)
        )

        try await manager.configureAndEnable(configuration)

        let persisted = try #require(await preferences.persistedSnapshot())
        #expect(persisted.isEnabled)
        #expect(persisted.localizedDescription == "MClash DNS Proxy")
        #expect(
            persisted.providerBundleIdentifier
                == MClashNetworkExtensionIdentifiers.systemExtension
        )
        let savedBootstrapData = try #require(
            persisted.providerConfiguration?["dnsProxyBootstrap"] as? Data
        )
        let savedBootstrap = try DNSProxyBootstrapConfiguration.decode(savedBootstrapData)
        #expect(savedBootstrap.revision == 41)
        #expect(savedBootstrap.activationIdentifier == configuration.activationIdentifier)
        #expect(savedBootstrap.profileRulesProxy.route == .profileRules)
        #expect(await preferences.preparedBeforeFirstEnableSave())
        #expect(await preferences.loadCount() == 2)
        #expect(await preferences.saveCount() == 1)
    }

    @Test("An already-enabled owned manager is verified off before a fresh start")
    func enableForcesOwnedOffOnRestart() async throws {
        let channel = StubDNSRuntimeChannel()
        let previous = try Self.configuration(revision: 40)
        let desired = try Self.configuration(revision: 41)
        let preferences = StubDNSProxyPreferences(
            initial: Self.preferenceSnapshot(previous, enabled: true),
            runtimeChannel: channel
        )
        let manager = AppleDNSProxyManager(
            preferences: preferences,
            runtimeChannel: channel,
            operationalStatusTimeout: .milliseconds(100),
            operationalStatusPollInterval: .milliseconds(1)
        )

        try await manager.configureAndEnable(desired)

        #expect(await preferences.savedEnabledStates() == [false, true])
        #expect(await preferences.loadCount() == 3)
        #expect(await preferences.saveCount() == 2)
        #expect(await preferences.preparedBeforeFirstEnableSave())
        #expect((await preferences.persistedSnapshot())?.isEnabled == true)
    }

    @Test("Enable rejects a system readback with a changed bootstrap")
    func enableRejectsMismatchedReadback() async throws {
        let channel = StubDNSRuntimeChannel()
        let preferences = StubDNSProxyPreferences(
            runtimeChannel: channel,
            readbackMutation: .replaceBootstrap
        )
        let configuration = try Self.configuration(revision: 42)
        let manager = AppleDNSProxyManager(
            preferences: preferences,
            runtimeChannel: channel,
            operationalStatusTimeout: .milliseconds(100),
            operationalStatusPollInterval: .milliseconds(1)
        )

        do {
            try await manager.configureAndEnable(configuration)
            Issue.record("Expected mismatched readback to fail")
        } catch let failure as NetworkExtensionControlFailure {
            #expect(failure.operation == .configureDNSProxy)
            #expect(failure.message.contains("bootstrap"))
        }
    }

    @Test("Runtime status cannot mask a disabled persisted DNS proxy")
    func runtimeStatusRequiresEnabledPreferences() async throws {
        let configuration = try Self.configuration(revision: 43)
        let channel = StubDNSRuntimeChannel()
        await channel.prepareAndPublishOperational(configuration)
        let preferences = StubDNSProxyPreferences(
            initial: Self.preferenceSnapshot(configuration, enabled: false),
            runtimeChannel: channel
        )
        let manager = AppleDNSProxyManager(
            preferences: preferences,
            runtimeChannel: channel
        )

        do {
            _ = try await manager.runtimeStatus(for: configuration)
            Issue.record("Expected disabled persisted preferences to fail")
        } catch let failure as NetworkExtensionControlFailure {
            #expect(failure.operation == .inspectDNSProxy)
            #expect(failure.message.contains("disabled"))
        }
    }

    @Test("A provider bootstrap rejection is returned without waiting for timeout")
    func bootstrapFailureIsImmediate() async throws {
        let channel = StubDNSRuntimeChannel()
        let preferences = StubDNSProxyPreferences(
            runtimeChannel: channel,
            publication: .startupFailure(.invalidBootstrapPayload)
        )
        let configuration = try Self.configuration(revision: 45)
        let manager = AppleDNSProxyManager(
            preferences: preferences,
            runtimeChannel: channel,
            operationalStatusTimeout: .seconds(2),
            operationalStatusPollInterval: .milliseconds(1)
        )

        let clock = ContinuousClock()
        let started = clock.now
        do {
            try await manager.configureAndEnable(configuration)
            Issue.record("Expected provider bootstrap rejection")
        } catch let failure as NetworkExtensionControlFailure {
            #expect(failure.operation == .configureDNSProxy)
            #expect(failure.message.contains("bootstrap payload was invalid"))
        }
        #expect(started.duration(to: clock.now) < .seconds(1))
    }

    @Test("Disable preserves another application's DNS proxy preferences")
    func disableDoesNotTouchForeignPreferences() async throws {
        let channel = StubDNSRuntimeChannel()
        let preferences = StubDNSProxyPreferences(
            initial: DNSProxyPreferenceSnapshot(
                providerBundleIdentifier: "example.foreign.dns-proxy",
                providerConfiguration: nil,
                localizedDescription: "Foreign DNS",
                isEnabled: true
            ),
            runtimeChannel: channel
        )
        let manager = AppleDNSProxyManager(
            preferences: preferences,
            runtimeChannel: channel
        )

        try await manager.disable()

        #expect(await preferences.saveCount() == 0)
        #expect((await preferences.persistedSnapshot())?.isEnabled == true)
    }

    @Test("Disable is verified against a freshly loaded system-owned copy")
    func disablePersistsAndVerifies() async throws {
        let configuration = try Self.configuration(revision: 44)
        let channel = StubDNSRuntimeChannel()
        let preferences = StubDNSProxyPreferences(
            initial: Self.preferenceSnapshot(configuration, enabled: true),
            runtimeChannel: channel
        )
        let manager = AppleDNSProxyManager(
            preferences: preferences,
            runtimeChannel: channel
        )

        try await manager.disable()

        #expect(await preferences.loadCount() == 2)
        #expect(await preferences.saveCount() == 1)
        #expect((await preferences.persistedSnapshot())?.isEnabled == false)
    }

    @Test("Preference failures retain the NetworkExtension error domain and stage")
    func preferenceFailureRetainsEvidence() async throws {
        let underlying = NSError(
            domain: "NEConfigurationErrorDomain",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "permission denied"]
        )
        let channel = StubDNSRuntimeChannel()
        let preferences = StubDNSProxyPreferences(
            runtimeChannel: channel,
            loadError: underlying
        )
        let manager = AppleDNSProxyManager(
            preferences: preferences,
            runtimeChannel: channel
        )

        do {
            try await manager.reload()
            Issue.record("Expected preference load to fail")
        } catch let failure as NetworkExtensionControlFailure {
            #expect(failure.operation == .inspectDNSProxy)
            #expect(failure.message.contains("load NEDNSProxyManager preferences"))
            #expect(failure.message.contains("NEConfigurationErrorDomain 10"))
        }
    }
}

private actor StubDNSRuntimeChannel: DNSProxyRuntimeChannel {
    private var report: DNSProxyRuntimeReport?

    func prepareDNSActivation(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) {
        report = DNSProxyRuntimeReport(
            expectedRevision: configuration.revision,
            expectedActivationIdentifier: configuration.activationIdentifier
        )
    }

    func dnsRuntimeReport(
        for configuration: NetworkExtensionRuntimeConfiguration
    ) throws -> DNSProxyRuntimeReport {
        guard let report else {
            throw TransparentProxyProviderMessageError.missingDNSRuntimeReport
        }
        return report
    }

    func isPrepared(for configuration: NetworkExtensionRuntimeConfiguration) -> Bool {
        report?.expectedRevision == configuration.revision
            && report?.expectedActivationIdentifier == configuration.activationIdentifier
    }

    func publishOperational(_ configuration: NetworkExtensionRuntimeConfiguration) {
        let now = Date()
        report = DNSProxyRuntimeReport(
            expectedRevision: configuration.revision,
            expectedActivationIdentifier: configuration.activationIdentifier,
            status: DNSProxyRuntimeStatus(
                revision: configuration.revision,
                activationIdentifier: configuration.activationIdentifier,
                phase: .running,
                backendReady: true,
                startedAt: now,
                updatedAt: now,
                lastBackendAssociationAt: now
            )
        )
    }

    func publishStartupFailure(
        _ reason: DNSProxyStartupFailureReason,
        configuration: NetworkExtensionRuntimeConfiguration
    ) {
        report = DNSProxyRuntimeReport(
            expectedRevision: configuration.revision,
            expectedActivationIdentifier: configuration.activationIdentifier,
            startupFailure: DNSProxyStartupFailure(reason: reason)
        )
    }

    func prepareAndPublishOperational(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) {
        prepareDNSActivation(configuration)
        publishOperational(configuration)
    }
}

private actor StubDNSProxyPreferences: DNSProxyPreferenceManaging {
    enum ReadbackMutation: Sendable {
        case none
        case replaceBootstrap
    }

    enum Publication: Sendable {
        case operational
        case startupFailure(DNSProxyStartupFailureReason)
    }

    private var persisted: DNSProxyPreferenceSnapshot?
    private var loads = 0
    private var saves = 0
    private var wasPreparedBeforeFirstEnableSave = false
    private var savedEnabledValues: [Bool] = []
    private let runtimeChannel: StubDNSRuntimeChannel
    private let readbackMutation: ReadbackMutation
    private let loadError: NSError?
    private let publication: Publication

    init(
        initial: DNSProxyPreferenceSnapshot? = nil,
        runtimeChannel: StubDNSRuntimeChannel,
        readbackMutation: ReadbackMutation = .none,
        loadError: NSError? = nil,
        publication: Publication = .operational
    ) {
        persisted = initial
        self.runtimeChannel = runtimeChannel
        self.readbackMutation = readbackMutation
        self.loadError = loadError
        self.publication = publication
    }

    func load() throws -> DNSProxyPreferenceSnapshot {
        loads += 1
        if let loadError { throw loadError }
        return persisted ?? DNSProxyPreferenceSnapshot(
            providerBundleIdentifier: nil,
            providerConfiguration: nil,
            localizedDescription: nil,
            isEnabled: false
        )
    }

    func save(_ snapshot: DNSProxyPreferenceSnapshot) async throws {
        saves += 1
        savedEnabledValues.append(snapshot.isEnabled)
        persisted = snapshot

        if snapshot.isEnabled,
           let configuration = try? DNSProxyManagerClientTests.configuration(
               providerConfiguration: snapshot.providerConfiguration
           )
        {
            if !wasPreparedBeforeFirstEnableSave {
                wasPreparedBeforeFirstEnableSave = await runtimeChannel.isPrepared(
                    for: configuration
                )
            }
            switch publication {
            case .operational:
                await runtimeChannel.publishOperational(configuration)
            case let .startupFailure(reason):
                await runtimeChannel.publishStartupFailure(
                    reason,
                    configuration: configuration
                )
            }
        }

        if readbackMutation == .replaceBootstrap {
            persisted?.providerConfiguration?["dnsProxyBootstrap"] = Data("invalid".utf8)
        }
    }

    func persistedSnapshot() -> DNSProxyPreferenceSnapshot? { persisted }
    func loadCount() -> Int { loads }
    func saveCount() -> Int { saves }
    func preparedBeforeFirstEnableSave() -> Bool { wasPreparedBeforeFirstEnableSave }
    func savedEnabledStates() -> [Bool] { savedEnabledValues }
}

private extension DNSProxyManagerClientTests {
    static func configuration(
        revision: UInt64,
        activationIdentifier: UUID = UUID()
    ) throws -> NetworkExtensionRuntimeConfiguration {
        let snapshot = try CaptureConfigurationSnapshot(
            revision: revision,
            rules: [try CaptureRule(
                id: "all",
                priority: 1,
                action: .mihomo(.profileRules)
            )]
        )
        let preferences = try NetworkCapturePreferences(
            enabled: true,
            dnsEnabled: true,
            failOpen: true,
            snapshot: snapshot
        )
        let authentication = try NetworkExtensionMihomoAuthentication(
            username: "dns-provider",
            password: "private-secret"
        )
        return try NetworkExtensionRuntimeConfiguration(
            preferences: preferences,
            mihomoListener: NetworkExtensionMihomoListenerConfiguration(
                port: 17_891,
                authentication: authentication
            ),
            activationIdentifier: activationIdentifier
        )
    }

    static func configuration(
        providerConfiguration: [String: Any]?
    ) throws -> NetworkExtensionRuntimeConfiguration {
        let data = try #require(providerConfiguration?["dnsProxyBootstrap"] as? Data)
        let bootstrap = try DNSProxyBootstrapConfiguration.decode(data)
        return try configuration(
            revision: bootstrap.revision,
            activationIdentifier: bootstrap.activationIdentifier
        )
    }

    static func preferenceSnapshot(
        _ configuration: NetworkExtensionRuntimeConfiguration,
        enabled: Bool
    ) -> DNSProxyPreferenceSnapshot {
        DNSProxyPreferenceSnapshot(
            providerBundleIdentifier: MClashNetworkExtensionIdentifiers.systemExtension,
            providerConfiguration: configuration.providerConfiguration,
            localizedDescription: "MClash DNS Proxy",
            isEnabled: enabled
        )
    }
}
