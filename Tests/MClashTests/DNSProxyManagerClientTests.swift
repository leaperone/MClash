import Foundation
import MClashNetworkShared
import Testing
@testable import MClashApp

@Suite("DNS proxy manager preferences")
struct DNSProxyManagerClientTests {
    @Test("Enable persists and reads back an owned activation before reporting success")
    func enablePersistsAndReadsBackActivation() async throws {
        let fixture = Self.makeStatusFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preferences = StubDNSProxyPreferences(statusFile: fixture.file)
        let configuration = NetworkExtensionRuntimeConfiguration(
            revision: 41,
            dnsEnabled: true,
            activationIdentifier: UUID()
        )
        let manager = AppleDNSProxyManager(
            preferences: preferences,
            statusFile: fixture.file,
            operationalStatusTimeout: .milliseconds(100),
            operationalStatusPollInterval: .milliseconds(1)
        )

        try await manager.configureAndEnable(configuration)

        guard let persisted = await preferences.persistedSnapshot() else {
            Issue.record("Expected persisted DNS proxy preferences")
            return
        }
        #expect(persisted.isEnabled)
        #expect(persisted.localizedDescription == "MClash DNS Proxy")
        #expect(
            persisted.providerBundleIdentifier
                == MClashNetworkExtensionIdentifiers.systemExtension
        )
        let savedRevision = (persisted.providerConfiguration?["revision"] as? NSNumber)?
            .uint64Value
        let savedActivation = persisted.providerConfiguration?["activationIdentifier"]
            as? String
        #expect(savedRevision == 41)
        #expect(savedActivation == configuration.activationIdentifier.uuidString)
        #expect(await preferences.loadCount() == 2)
        #expect(await preferences.saveCount() == 1)
    }

    @Test("Enable fails when the system-owned readback does not match")
    func enableRejectsMismatchedReadback() async throws {
        let fixture = Self.makeStatusFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preferences = StubDNSProxyPreferences(
            statusFile: fixture.file,
            readbackMutation: .replaceActivationIdentifier
        )
        let configuration = NetworkExtensionRuntimeConfiguration(
            revision: 42,
            dnsEnabled: true,
            activationIdentifier: UUID()
        )
        let manager = AppleDNSProxyManager(
            preferences: preferences,
            statusFile: fixture.file,
            operationalStatusTimeout: .milliseconds(100),
            operationalStatusPollInterval: .milliseconds(1)
        )

        do {
            try await manager.configureAndEnable(configuration)
            Issue.record("Expected mismatched readback to fail")
        } catch let failure as NetworkExtensionControlFailure {
            #expect(failure.operation == .configureDNSProxy)
            #expect(failure.message.contains("activation identifier"))
        }
    }

    @Test("Runtime heartbeat cannot mask a disabled persisted DNS proxy")
    func runtimeStatusRequiresEnabledPreferences() async throws {
        let fixture = Self.makeStatusFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configuration = NetworkExtensionRuntimeConfiguration(
            revision: 43,
            dnsEnabled: true,
            activationIdentifier: UUID()
        )
        try Self.writeOperationalStatus(configuration, to: fixture.file)
        let preferences = StubDNSProxyPreferences(
            initial: Self.preferenceSnapshot(configuration, enabled: false)
        )
        let manager = AppleDNSProxyManager(
            preferences: preferences,
            statusFile: fixture.file
        )

        do {
            _ = try await manager.runtimeStatus(for: configuration)
            Issue.record("Expected disabled persisted preferences to fail")
        } catch let failure as NetworkExtensionControlFailure {
            #expect(failure.operation == .inspectDNSProxy)
            #expect(failure.message.contains("disabled"))
        }
    }

    @Test("A terminal provider startup failure is returned without timing out")
    func terminalStartupFailureIsImmediate() async throws {
        let fixture = Self.makeStatusFile()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preferences = StubDNSProxyPreferences(
            statusFile: fixture.file,
            publishesStartupFailure: true
        )
        let configuration = NetworkExtensionRuntimeConfiguration(
            revision: 45,
            dnsEnabled: true,
            activationIdentifier: UUID()
        )
        let manager = AppleDNSProxyManager(
            preferences: preferences,
            statusFile: fixture.file,
            operationalStatusTimeout: .seconds(2),
            operationalStatusPollInterval: .milliseconds(1)
        )

        do {
            try await manager.configureAndEnable(configuration)
            Issue.record("Expected terminal provider failure")
        } catch let failure as NetworkExtensionControlFailure {
            #expect(failure.operation == .configureDNSProxy)
            #expect(failure.message == "DNS Provider reported backendUnavailable during startup")
        }
    }

    @Test("Disable preserves another application's DNS proxy preferences")
    func disableDoesNotTouchForeignPreferences() async throws {
        let preferences = StubDNSProxyPreferences(
            initial: DNSProxyPreferenceSnapshot(
                providerBundleIdentifier: "example.foreign.dns-proxy",
                providerConfiguration: nil,
                localizedDescription: "Foreign DNS",
                isEnabled: true
            )
        )
        let manager = AppleDNSProxyManager(
            preferences: preferences,
            statusFile: nil
        )

        try await manager.disable()

        #expect(await preferences.saveCount() == 0)
        #expect((await preferences.persistedSnapshot())?.isEnabled == true)
    }

    @Test("Disable is verified against a freshly loaded system-owned copy")
    func disablePersistsAndVerifies() async throws {
        let configuration = NetworkExtensionRuntimeConfiguration(
            revision: 44,
            dnsEnabled: true,
            activationIdentifier: UUID()
        )
        let preferences = StubDNSProxyPreferences(
            initial: Self.preferenceSnapshot(configuration, enabled: true)
        )
        let manager = AppleDNSProxyManager(
            preferences: preferences,
            statusFile: nil
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
        let preferences = StubDNSProxyPreferences(loadError: underlying)
        let manager = AppleDNSProxyManager(
            preferences: preferences,
            statusFile: nil
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

private actor StubDNSProxyPreferences: DNSProxyPreferenceManaging {
    enum ReadbackMutation: Sendable {
        case none
        case replaceActivationIdentifier
    }

    private var persisted: DNSProxyPreferenceSnapshot?
    private var loads = 0
    private var saves = 0
    private let statusFile: DNSProxyStatusFile?
    private let readbackMutation: ReadbackMutation
    private let loadError: NSError?
    private let publishesStartupFailure: Bool

    init(
        initial: DNSProxyPreferenceSnapshot? = nil,
        statusFile: DNSProxyStatusFile? = nil,
        readbackMutation: ReadbackMutation = .none,
        loadError: NSError? = nil,
        publishesStartupFailure: Bool = false
    ) {
        persisted = initial
        self.statusFile = statusFile
        self.readbackMutation = readbackMutation
        self.loadError = loadError
        self.publishesStartupFailure = publishesStartupFailure
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

    func save(_ snapshot: DNSProxyPreferenceSnapshot) throws {
        saves += 1
        persisted = snapshot

        if snapshot.isEnabled,
           let statusFile,
           let revision = Self.uint64(snapshot.providerConfiguration?["revision"]),
           let activationIdentifier = Self.uuid(
               snapshot.providerConfiguration?["activationIdentifier"]
           )
        {
            let configuration = NetworkExtensionRuntimeConfiguration(
                revision: revision,
                dnsEnabled: true,
                activationIdentifier: activationIdentifier
            )
            if publishesStartupFailure {
                try DNSProxyManagerClientTests.writeFailedStatus(
                    configuration,
                    to: statusFile
                )
            } else {
                try DNSProxyManagerClientTests.writeOperationalStatus(
                    configuration,
                    to: statusFile
                )
            }
        }

        if readbackMutation == .replaceActivationIdentifier {
            persisted?.providerConfiguration?["activationIdentifier"] = UUID().uuidString
        }
    }

    func persistedSnapshot() -> DNSProxyPreferenceSnapshot? { persisted }
    func loadCount() -> Int { loads }
    func saveCount() -> Int { saves }

    private static func uint64(_ value: Any?) -> UInt64? {
        switch value {
        case let value as NSNumber: value.uint64Value
        case let value as UInt64: value
        default: nil
        }
    }

    private static func uuid(_ value: Any?) -> UUID? {
        guard let string = value as? String else { return nil }
        return UUID(uuidString: string)
    }
}

private extension DNSProxyManagerClientTests {
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

    static func makeStatusFile() -> (root: URL, file: DNSProxyStatusFile) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MClash-DNSProxyManagerTests-\(UUID().uuidString)")
        return (
            root,
            DNSProxyStatusFile(statusURL: root.appendingPathComponent("status.json"))
        )
    }

    static func writeOperationalStatus(
        _ configuration: NetworkExtensionRuntimeConfiguration,
        to file: DNSProxyStatusFile
    ) throws {
        let now = Date()
        try file.write(DNSProxyRuntimeStatus(
            revision: configuration.revision,
            activationIdentifier: configuration.activationIdentifier,
            phase: .running,
            backendReady: true,
            startedAt: now,
            updatedAt: now,
            lastBackendAssociationAt: now
        ))
    }

    static func writeFailedStatus(
        _ configuration: NetworkExtensionRuntimeConfiguration,
        to file: DNSProxyStatusFile
    ) throws {
        let now = Date()
        try file.write(DNSProxyRuntimeStatus(
            revision: configuration.revision,
            activationIdentifier: configuration.activationIdentifier,
            phase: .failed,
            backendReady: false,
            totalFlows: 1,
            failedFlows: 1,
            startedAt: now,
            updatedAt: now,
            lastFailureAt: now,
            failureCategory: .backendUnavailable
        ))
    }
}
