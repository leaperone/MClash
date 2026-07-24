import Foundation
import MClashNetworkShared
import Testing
@testable import MClashApp

@Suite("Network extension control")
struct NetworkExtensionControlTests {
    @Test("Reducer enforces the full enable order")
    func reducerEnableOrder() throws {
        var state = NetworkExtensionControlState.inactive
        state = try NetworkExtensionControlReducer.reduce(
            state,
            .beginEnable(revision: 42, dnsEnabled: true)
        )
        #expect(state.phase == .activatingSystemExtension)

        state = try NetworkExtensionControlReducer.reduce(
            state,
            .systemExtensionNeedsApproval
        )
        #expect(state.userApprovalRequired)

        state = try NetworkExtensionControlReducer.reduce(state, .systemExtensionActivated)
        #expect(state.phase == .configuringTransparentProxy)
        state = try NetworkExtensionControlReducer.reduce(state, .transparentProxyConfigured)
        #expect(state.phase == .startingTransparentProxy)
        state = try NetworkExtensionControlReducer.reduce(state, .transparentProxyStarted)
        #expect(state.phase == .configuringDNSProxy)
        state = try NetworkExtensionControlReducer.reduce(state, .dnsProxyConfigured)
        #expect(state.phase == .running)
        #expect(state.revision == 42)
    }

    @Test("Reducer rejects DNS configuration before transparent proxy start")
    func reducerRejectsOutOfOrderEvent() throws {
        var state = try NetworkExtensionControlReducer.reduce(
            .inactive,
            .beginEnable(revision: 1, dnsEnabled: true)
        )
        state = try NetworkExtensionControlReducer.reduce(state, .systemExtensionActivated)

        do {
            _ = try NetworkExtensionControlReducer.reduce(state, .dnsProxyConfigured)
            Issue.record("Expected an invalid transition")
        } catch let error as NetworkExtensionStateReductionError {
            #expect(
                error == .invalidTransition(
                    phase: .configuringTransparentProxy,
                    event: .dnsProxyConfigured
                )
            )
        }
    }

    @Test("Service enables and disables providers in safe order")
    func serviceOperationOrder() async throws {
        let recorder = NetworkExtensionOperationRecorder()
        let service = NetworkExtensionControlService(
            systemExtension: MockSystemExtensionController(recorder: recorder),
            transparentProxy: MockTransparentProxyManager(recorder: recorder),
            dnsProxy: MockDNSProxyManager(recorder: recorder)
        )

        let result = try await service.enable(
            NetworkExtensionRuntimeConfiguration(revision: 7, dnsEnabled: true)
        )
        #expect(result == .running)
        var operations = await recorder.snapshot()
        #expect(operations == [
            "dns.disable",
            "transparent.stop",
            "system.activate",
            "transparent.configure",
            "transparent.reload",
            "transparent.start",
            "transparent.status",
            "dns.configure",
            "dns.reload",
        ])

        await recorder.removeAll()
        try await service.disable()
        operations = await recorder.snapshot()
        #expect(operations == ["dns.disable", "transparent.stop"])
        let state = await service.currentState()
        #expect(state.phase == .inactive)
    }

    @Test("Advanced DNS opt-out actively disables stale MClash DNS preferences")
    func dnsOptOutDisablesPersistedManager() async throws {
        let recorder = NetworkExtensionOperationRecorder()
        let service = NetworkExtensionControlService(
            systemExtension: MockSystemExtensionController(recorder: recorder),
            transparentProxy: MockTransparentProxyManager(recorder: recorder),
            dnsProxy: MockDNSProxyManager(recorder: recorder)
        )

        let result = try await service.enable(
            NetworkExtensionRuntimeConfiguration(revision: 8, dnsEnabled: false)
        )

        #expect(result == .running)
        #expect(await recorder.snapshot() == [
            "dns.disable",
            "transparent.stop",
            "system.activate",
            "transparent.configure",
            "transparent.reload",
            "transparent.start",
            "transparent.status",
            "dns.disable",
        ])
    }

    @Test("DNS startup failure rolls back DNS before transparent capture")
    func dnsStartupFailureRollsBackBothProviders() async throws {
        let recorder = NetworkExtensionOperationRecorder()
        let service = NetworkExtensionControlService(
            systemExtension: MockSystemExtensionController(recorder: recorder),
            transparentProxy: MockTransparentProxyManager(recorder: recorder),
            dnsProxy: MockDNSProxyManager(
                recorder: recorder,
                configureError: NSError(
                    domain: "DNSProvider",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "bootstrap rejected"]
                )
            )
        )

        await #expect(throws: NetworkExtensionControlFailure.self) {
            try await service.enable(
                NetworkExtensionRuntimeConfiguration(revision: 9, dnsEnabled: true)
            )
        }

        #expect(Array((await recorder.snapshot()).suffix(3)) == [
            "dns.configure", "dns.disable", "transparent.stop",
        ])
        #expect(await service.currentState().phase == .failed)
    }

    @Test("A reboot result prevents proxy preferences from being configured")
    func rebootStopsEnableSequence() async throws {
        let recorder = NetworkExtensionOperationRecorder()
        let service = NetworkExtensionControlService(
            systemExtension: MockSystemExtensionController(
                recorder: recorder,
                activationOutcome: .requiresReboot
            ),
            transparentProxy: MockTransparentProxyManager(recorder: recorder),
            dnsProxy: MockDNSProxyManager(recorder: recorder)
        )

        let result = try await service.enable(
            NetworkExtensionRuntimeConfiguration(revision: 9)
        )
        #expect(result == .requiresReboot)
        let operations = await recorder.snapshot()
        #expect(operations == [
            "dns.disable",
            "transparent.stop",
            "system.activate",
        ])
        let state = await service.currentState()
        #expect(state.phase == .requiresReboot)
    }

    @Test("System Extension approval progress reaches the host")
    func approvalProgressIsForwarded() async throws {
        let recorder = NetworkExtensionOperationRecorder()
        let progressRecorder = NetworkExtensionProgressRecorder()
        let service = NetworkExtensionControlService(
            systemExtension: MockSystemExtensionController(recorder: recorder),
            transparentProxy: MockTransparentProxyManager(recorder: recorder),
            dnsProxy: MockDNSProxyManager(recorder: recorder)
        )

        _ = try await service.enable(
            NetworkExtensionRuntimeConfiguration(revision: 10),
            progress: { progressRecorder.record($0) }
        )

        #expect(progressRecorder.snapshot() == [.awaitingSystemExtensionApproval])
    }

    @Test("Disable invalidates an activation waiting for System Extension approval")
    func disableInvalidatesPendingSystemExtensionActivation() async throws {
        let recorder = NetworkExtensionOperationRecorder()
        let systemExtension = DeferredSystemExtensionController(recorder: recorder)
        let service = NetworkExtensionControlService(
            systemExtension: systemExtension,
            transparentProxy: MockTransparentProxyManager(recorder: recorder),
            dnsProxy: MockDNSProxyManager(recorder: recorder)
        )

        let activation = Task {
            try await service.enable(
                NetworkExtensionRuntimeConfiguration(revision: 11)
            )
        }
        while !(await recorder.snapshot()).contains("system.activate") {
            await Task.yield()
        }

        try await service.disable()
        await systemExtension.completeActivation()

        await #expect(throws: CancellationError.self) {
            try await activation.value
        }
        let operations = await recorder.snapshot()
        #expect(!operations.contains("transparent.configure"))
        #expect(!operations.contains("transparent.start"))
        #expect(await service.currentState().phase == .inactive)
    }

    @Test("Disable remains the final writer after a stale DNS activation returns")
    func disableSerializesWithInFlightDNSActivation() async throws {
        let recorder = NetworkExtensionOperationRecorder()
        let dnsProxy = DeferredDNSProxyManager(recorder: recorder)
        let service = NetworkExtensionControlService(
            systemExtension: MockSystemExtensionController(recorder: recorder),
            transparentProxy: MockTransparentProxyManager(recorder: recorder),
            dnsProxy: dnsProxy
        )
        let activation = Task {
            try await service.enable(
                NetworkExtensionRuntimeConfiguration(
                    revision: 12,
                    dnsEnabled: true
                )
            )
        }
        while !(await dnsProxy.configureHasStarted()) {
            await Task.yield()
        }

        let disabling = Task {
            try await service.disable()
        }
        while await service.currentState().phase != .disablingDNSProxy {
            await Task.yield()
        }
        await dnsProxy.completeConfiguration()

        try await disabling.value
        await #expect(throws: CancellationError.self) {
            try await activation.value
        }
        #expect(!(await dnsProxy.isEnabled()))
        #expect(await service.currentState().phase == .inactive)
    }

    @Test("Control failures preserve the localized system error")
    func controlFailurePresentation() {
        let underlying = NSError(
            domain: "NetworkExtensionErrorDomain",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "Invalid Mach service App Group"]
        )
        let failure = NetworkExtensionControlFailure(
            operation: .activateSystemExtension,
            underlying: underlying
        )

        #expect(
            failure.localizedDescription
                == "System extension installation: Invalid Mach service App Group (NetworkExtensionErrorDomain 6)"
        )
    }

    @Test("System Extension validation failures explain the recovery action")
    func systemExtensionValidationFailurePresentation() {
        let underlying = NSError(
            domain: "OSSystemExtensionErrorDomain",
            code: 9,
            userInfo: [
                NSLocalizedDescriptionKey: "extension category returned error"
            ]
        )
        let failure = NetworkExtensionControlFailure(
            operation: .activateSystemExtension,
            underlying: underlying
        )

        #expect(
            failure.localizedDescription
                == "System extension installation: macOS rejected the Network Extension package during validation. Install the latest MClash update or reinstall the application (OSSystemExtensionErrorDomain 9)"
        )
    }

    @Test("Connected provider must confirm the active revision")
    func providerRevisionIsVerified() async throws {
        let recorder = NetworkExtensionOperationRecorder()
        let service = NetworkExtensionControlService(
            systemExtension: MockSystemExtensionController(recorder: recorder),
            transparentProxy: MockTransparentProxyManager(
                recorder: recorder,
                statusOverride: TransparentProxyProviderStatus(
                    revision: 3,
                    running: true,
                    captureEnabled: true,
                    failOpen: true
                )
            ),
            dnsProxy: MockDNSProxyManager(recorder: recorder)
        )

        await #expect(throws: NetworkExtensionControlFailure.self) {
            try await service.enable(NetworkExtensionRuntimeConfiguration(revision: 4))
        }
        let operations = await recorder.snapshot()
        #expect(Array(operations.suffix(2)) == ["dns.disable", "transparent.stop"])
        let state = await service.currentState()
        #expect(state.phase == .failed)
    }

    @Test("Same revision fast path verifies the live provider")
    func sameRevisionFastPathVerifiesProvider() async throws {
        let recorder = NetworkExtensionOperationRecorder()
        let service = NetworkExtensionControlService(
            systemExtension: MockSystemExtensionController(recorder: recorder),
            transparentProxy: MockTransparentProxyManager(recorder: recorder),
            dnsProxy: MockDNSProxyManager(recorder: recorder)
        )
        let configuration = NetworkExtensionRuntimeConfiguration(
            revision: 12,
            dnsEnabled: true
        )

        _ = try await service.enable(configuration)
        await recorder.removeAll()

        let result = try await service.enable(configuration)

        #expect(result == .running)
        #expect(await recorder.snapshot() == ["transparent.status", "dns.status"])
    }

    @Test("Provider state drift forces a controlled restart")
    func providerStateDriftForcesRestart() async throws {
        let recorder = NetworkExtensionOperationRecorder()
        let service = NetworkExtensionControlService(
            systemExtension: MockSystemExtensionController(recorder: recorder),
            transparentProxy: MockTransparentProxyManager(recorder: recorder),
            dnsProxy: MockDNSProxyManager(recorder: recorder)
        )
        let configuration = NetworkExtensionRuntimeConfiguration(
            revision: 13,
            dnsEnabled: true
        )

        _ = try await service.enable(configuration)
        await recorder.removeAll()
        await recorder.enqueueProviderStatuses([
            TransparentProxyProviderStatus(
                revision: 13,
                running: false,
                captureEnabled: false,
                failOpen: true
            ),
        ])

        let result = try await service.enable(configuration)

        #expect(result == .running)
        #expect(await recorder.snapshot() == [
            "transparent.status",
            "dns.disable",
            "transparent.stop",
            "system.activate",
            "transparent.configure",
            "transparent.reload",
            "transparent.start",
            "transparent.status",
            "dns.configure",
            "dns.reload",
        ])
    }

    @Test("Disable checks persisted managers when actor state is inactive")
    func inactiveDisableStillStopsPersistedManager() async throws {
        let recorder = NetworkExtensionOperationRecorder()
        let service = NetworkExtensionControlService(
            systemExtension: MockSystemExtensionController(recorder: recorder),
            transparentProxy: MockTransparentProxyManager(recorder: recorder),
            dnsProxy: MockDNSProxyManager(recorder: recorder)
        )

        try await service.disable()

        #expect(await recorder.snapshot() == ["dns.disable", "transparent.stop"])
        #expect(await service.currentState().phase == .inactive)
    }

    @Test("Provider runtime status is available to the host")
    func providerRuntimeStatusIsExposed() async throws {
        let recorder = NetworkExtensionOperationRecorder()
        let service = NetworkExtensionControlService(
            systemExtension: MockSystemExtensionController(recorder: recorder),
            transparentProxy: MockTransparentProxyManager(recorder: recorder),
            dnsProxy: MockDNSProxyManager(recorder: recorder)
        )
        _ = try await service.enable(NetworkExtensionRuntimeConfiguration(revision: 21))
        await recorder.removeAll()

        let status = try await service.providerRuntimeStatus()

        #expect(status.running)
        #expect(status.captureEnabled)
        #expect(status.revision == 21)
        #expect(await recorder.snapshot() == ["transparent.status"])
    }

    @Test("Rule updates restart DNS so both providers receive the new snapshot")
    func ruleUpdateRestartsDNSProvider() async throws {
        let recorder = NetworkExtensionOperationRecorder()
        let service = NetworkExtensionControlService(
            systemExtension: MockSystemExtensionController(recorder: recorder),
            transparentProxy: MockTransparentProxyManager(recorder: recorder),
            dnsProxy: MockDNSProxyManager(recorder: recorder)
        )
        let initialActivation = UUID(
            uuidString: "30303030-3030-3030-3030-303030303030"
        )!
        let initial = try runtimeConfiguration(
            revision: 30,
            activationIdentifier: initialActivation
        )
        let candidate = try runtimeConfiguration(
            revision: 31,
            activationIdentifier: UUID(
                uuidString: "31313131-3131-3131-3131-313131313131"
            )!
        )
        _ = try await service.enable(initial)
        await recorder.removeAll()

        let result = try await service.updateRuntimeConfiguration(candidate)

        #expect(result == .running)
        let operations = await recorder.snapshot()
        #expect(operations.contains("dns.disable"))
        #expect(operations.contains("transparent.stop"))
        #expect(operations.contains("dns.configure"))
        #expect(!operations.contains("transparent.update"))
        #expect(await service.currentState().revision == 31)
        let appliedConfigurations = await recorder.configurations()
        let applied = try #require(appliedConfigurations.last)
        #expect(applied.revision == 31)
        #expect(applied.activationIdentifier == candidate.activationIdentifier)
        #expect(applied.encodedCaptureSnapshot == candidate.encodedCaptureSnapshot)
        #expect(applied.encodedDNSProxyBootstrap == candidate.encodedDNSProxyBootstrap)
        let dnsStatus = try await service.dnsProviderRuntimeStatus()
        #expect(dnsStatus?.revision == 31)
    }

    private func runtimeConfiguration(
        revision: UInt64,
        activationIdentifier: UUID
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
        return try NetworkExtensionRuntimeConfiguration(
            preferences: preferences,
            mihomoListener: NetworkExtensionMihomoListenerConfiguration(port: 17_891),
            activationIdentifier: activationIdentifier
        )
    }
}

private final class NetworkExtensionProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NetworkExtensionEnableProgress] = []

    func record(_ value: NetworkExtensionEnableProgress) {
        lock.withLock { values.append(value) }
    }

    func snapshot() -> [NetworkExtensionEnableProgress] {
        lock.withLock { values }
    }
}

private actor NetworkExtensionOperationRecorder {
    private var operations: [String] = []
    private var configuredRevision: UInt64 = 0
    private var capturedConfigurations: [NetworkExtensionRuntimeConfiguration] = []
    private var providerStatuses: [TransparentProxyProviderStatus] = []

    func append(_ operation: String) {
        operations.append(operation)
    }

    func snapshot() -> [String] {
        operations
    }

    func removeAll() {
        operations.removeAll()
        capturedConfigurations.removeAll()
    }

    func setConfiguredRevision(_ revision: UInt64) {
        configuredRevision = revision
    }

    func capture(_ configuration: NetworkExtensionRuntimeConfiguration) {
        capturedConfigurations.append(configuration)
    }

    func configurations() -> [NetworkExtensionRuntimeConfiguration] {
        capturedConfigurations
    }

    func revision() -> UInt64 {
        configuredRevision
    }

    func enqueueProviderStatuses(_ statuses: [TransparentProxyProviderStatus]) {
        providerStatuses.append(contentsOf: statuses)
    }

    func nextProviderStatus() -> TransparentProxyProviderStatus? {
        guard !providerStatuses.isEmpty else { return nil }
        return providerStatuses.removeFirst()
    }
}

private struct MockSystemExtensionController: SystemExtensionControlling {
    let recorder: NetworkExtensionOperationRecorder
    var activationOutcome: SystemExtensionRequestOutcome = .completed

    func activate(
        progress: @escaping @Sendable (SystemExtensionRequestProgress) -> Void
    ) async throws -> SystemExtensionRequestOutcome {
        await recorder.append("system.activate")
        progress(.awaitingUserApproval)
        return activationOutcome
    }

    func deactivate(
        progress: @escaping @Sendable (SystemExtensionRequestProgress) -> Void
    ) async throws -> SystemExtensionRequestOutcome {
        await recorder.append("system.deactivate")
        return .completed
    }
}

private actor DeferredSystemExtensionController: SystemExtensionControlling {
    let recorder: NetworkExtensionOperationRecorder
    private var activationContinuation:
        CheckedContinuation<SystemExtensionRequestOutcome, Error>?

    init(recorder: NetworkExtensionOperationRecorder) {
        self.recorder = recorder
    }

    func activate(
        progress: @escaping @Sendable (SystemExtensionRequestProgress) -> Void
    ) async throws -> SystemExtensionRequestOutcome {
        await recorder.append("system.activate")
        progress(.awaitingUserApproval)
        return try await withCheckedThrowingContinuation { continuation in
            activationContinuation = continuation
        }
    }

    func completeActivation() {
        activationContinuation?.resume(returning: .completed)
        activationContinuation = nil
    }

    func deactivate(
        progress: @escaping @Sendable (SystemExtensionRequestProgress) -> Void
    ) async throws -> SystemExtensionRequestOutcome {
        await recorder.append("system.deactivate")
        return .completed
    }
}

private actor DeferredDNSProxyManager: DNSProxyManaging {
    let recorder: NetworkExtensionOperationRecorder
    private var configureStarted = false
    private var enabled = false
    private var configureContinuation: CheckedContinuation<Void, Never>?

    init(recorder: NetworkExtensionOperationRecorder) {
        self.recorder = recorder
    }

    func configureAndEnable(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async throws {
        await recorder.append("dns.configure")
        configureStarted = true
        await withCheckedContinuation { continuation in
            configureContinuation = continuation
        }
        enabled = true
    }

    func reload() async throws {
        await recorder.append("dns.reload")
    }

    func runtimeStatus(
        for configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> DNSProxyRuntimeStatus {
        let now = Date()
        return DNSProxyRuntimeStatus(
            revision: configuration.revision,
            activationIdentifier: configuration.activationIdentifier,
            phase: enabled ? .running : .stopped,
            backendReady: enabled,
            startedAt: now
        )
    }

    func disable() async throws {
        await recorder.append("dns.disable")
        enabled = false
    }

    func configureHasStarted() -> Bool {
        configureStarted
    }

    func completeConfiguration() {
        configureContinuation?.resume()
        configureContinuation = nil
    }

    func isEnabled() -> Bool {
        enabled
    }
}

private struct MockTransparentProxyManager: TransparentProxyManaging {
    let recorder: NetworkExtensionOperationRecorder
    var statusOverride: TransparentProxyProviderStatus?

    init(
        recorder: NetworkExtensionOperationRecorder,
        statusOverride: TransparentProxyProviderStatus? = nil
    ) {
        self.recorder = recorder
        self.statusOverride = statusOverride
    }

    func configure(_ configuration: NetworkExtensionRuntimeConfiguration) async throws {
        await recorder.append("transparent.configure")
        await recorder.setConfiguredRevision(configuration.revision)
        await recorder.capture(configuration)
    }

    func reload() async throws {
        await recorder.append("transparent.reload")
    }

    func start() async throws {
        await recorder.append("transparent.start")
    }

    func stop() async throws {
        await recorder.append("transparent.stop")
    }

    func providerStatus() async throws -> TransparentProxyProviderStatus {
        await recorder.append("transparent.status")
        if let status = await recorder.nextProviderStatus() { return status }
        if let statusOverride { return statusOverride }
        let revision = await recorder.revision()
        return TransparentProxyProviderStatus(
            revision: revision,
            running: true,
            captureEnabled: true,
            failOpen: true
        )
    }

    func quiesceProvider(revision: UInt64) async throws -> TransparentProxyProviderStatus {
        TransparentProxyProviderStatus(
            revision: revision,
            running: true,
            captureEnabled: false,
            failOpen: true
        )
    }

    func applyProviderConfiguration(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> TransparentProxyProviderStatus {
        TransparentProxyProviderStatus(
            revision: configuration.revision,
            running: true,
            captureEnabled: configuration.captureEnabled,
            failOpen: configuration.failOpen
        )
    }

    func updateProviderConfiguration(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> TransparentProxyProviderStatus {
        await recorder.append("transparent.update")
        await recorder.setConfiguredRevision(configuration.revision)
        await recorder.capture(configuration)
        return try await applyProviderConfiguration(configuration)
    }

    func appRoutingActivity(
        after cursor: UInt64,
        limit: Int
    ) async throws -> AppRoutingActivityBatch {
        AppRoutingActivityBatch(
            activities: [],
            nextCursor: cursor,
            droppedBeforeSequence: nil,
            hasMore: false
        )
    }

    func clearAppRoutingActivity() async throws {}
}

private struct MockDNSProxyManager: DNSProxyManaging {
    let recorder: NetworkExtensionOperationRecorder
    var configureError: NSError?

    init(
        recorder: NetworkExtensionOperationRecorder,
        configureError: NSError? = nil
    ) {
        self.recorder = recorder
        self.configureError = configureError
    }

    func configureAndEnable(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async throws {
        await recorder.append("dns.configure")
        if let configureError { throw configureError }
    }

    func reload() async throws {
        await recorder.append("dns.reload")
    }

    func runtimeStatus(
        for configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> DNSProxyRuntimeStatus {
        await recorder.append("dns.status")
        let now = Date()
        return DNSProxyRuntimeStatus(
            revision: configuration.revision,
            activationIdentifier: configuration.activationIdentifier,
            phase: .running,
            backendReady: true,
            startedAt: now
        )
    }

    func disable() async throws {
        await recorder.append("dns.disable")
    }
}
