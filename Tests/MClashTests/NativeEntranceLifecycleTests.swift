@testable import MClashApp
import Foundation
import MClashNetworkShared
import Testing

@Suite("Native entrance lifecycle")
struct NativeEntranceLifecycleTests {
    @Test("Native activation applies App Routing without a Mihomo controller")
    func activatesAppRouting() async throws {
        let backend = RecordingEntranceBackend()
        let coordinator = NativeEntranceLifecycleCoordinator(backend: backend)

        let activation = try await coordinator.activate(
            revision: 12,
            enabled: [.appRouting]
        )

        #expect(activation.revision == 12)
        #expect(!activation.systemProxyEnabled)
        #expect(activation.appRoutingEnabled)
        #expect(await coordinator.state == .active(activation))
        #expect(await backend.applied.count == 1)
        #expect(await backend.applied.first?.transaction.activation == activation)
        #expect(await backend.applied.first?.previous == nil)
    }

    @Test("Failed replacement preserves no half-active state and can be retried")
    func failedActivationIsObservable() async throws {
        let backend = RecordingEntranceBackend()
        await backend.failNextApply()
        let coordinator = NativeEntranceLifecycleCoordinator(backend: backend)

        await #expect(throws: RecordingEntranceError.applyFailed) {
            try await coordinator.activate(revision: 1, enabled: [.appRouting])
        }
        #expect(await coordinator.state == .failed("recording backend apply failed"))
        _ = try await coordinator.activate(revision: 2, enabled: [.appRouting])
        #expect(await coordinator.state.activation?.revision == 2)
    }

    @Test("A failed replacement keeps the last committed activation")
    func failedReplacementPreservesCommittedActivation() async throws {
        let backend = RecordingEntranceBackend()
        let coordinator = NativeEntranceLifecycleCoordinator(backend: backend)
        let initial = try await coordinator.activate(revision: 1, enabled: [.appRouting])
        await backend.failNextApply()

        await #expect(throws: RecordingEntranceError.applyFailed) {
            try await coordinator.activate(revision: 2, enabled: [.systemProxy])
        }

        #expect(await coordinator.state == .active(initial))
        #expect(await backend.applied.map(\.transaction.activation) == [initial])
    }

    @Test("Deactivation is idempotent and calls the backend once")
    func deactivates() async throws {
        let backend = RecordingEntranceBackend()
        let coordinator = NativeEntranceLifecycleCoordinator(backend: backend)
        _ = try await coordinator.activate(revision: 3, enabled: [.systemProxy])
        try await coordinator.deactivate()
        try await coordinator.deactivate()

        #expect(await coordinator.state == .inactive)
        #expect(await backend.deactivated.count == 1)
    }

    @Test("Invalid, conflicting, and stale revisions fail before touching the backend")
    func validatesRevision() async throws {
        let backend = RecordingEntranceBackend()
        let coordinator = NativeEntranceLifecycleCoordinator(backend: backend)
        await #expect(throws: NativeEntranceLifecycleError.invalidRevision) {
            try await coordinator.activate(revision: 0, enabled: [.appRouting])
        }
        await #expect(throws: NativeEntranceLifecycleError.mutuallyExclusiveEntrances) {
            try await coordinator.activate(
                revision: 1,
                enabled: [.systemProxy, .appRouting]
            )
        }
        _ = try await coordinator.activate(revision: 4, enabled: [.appRouting])
        await #expect(throws: NativeEntranceLifecycleError.staleRevision(current: 4, requested: 2)) {
            try await coordinator.activate(revision: 2, enabled: [.appRouting])
        }
        #expect(await backend.applied.count == 1)
    }

    @Test("Replacement receives the exact committed rollback transaction")
    func replacementCarriesRollbackTransaction() async throws {
        let backend = RecordingEntranceBackend()
        let coordinator = NativeEntranceLifecycleCoordinator(backend: backend)
        let first = try await coordinator.activate(revision: 1, enabled: [.appRouting])
        let second = try await coordinator.activate(revision: 2, enabled: [.systemProxy])

        let applied = await backend.applied
        #expect(applied.count == 2)
        #expect(applied[0].transaction.activation == first)
        #expect(applied[0].previous == nil)
        #expect(applied[1].transaction.activation == second)
        #expect(applied[1].previous?.activation == first)
    }

    @Test("Requires-reboot outcome is preserved instead of reported as running")
    func requiresRebootIsExplicit() async throws {
        let backend = RecordingEntranceBackend()
        await backend.returnRequiresReboot()
        let coordinator = NativeEntranceLifecycleCoordinator(backend: backend)
        let activation = NativeEntranceActivation(
            revision: 5,
            enabled: [.appRouting],
            generation: 1
        )

        let result = try await coordinator.activate(
            NativeEntranceTransaction(activation: activation)
        )
        #expect(result.outcome == .requiresReboot)
        #expect(await coordinator.state == .requiresReboot(activation))
    }

    @Test("Network Extension backend preserves progress, reboot, and rollback")
    func networkExtensionBackendSemantics() async throws {
        let control = RecordingEntranceNetworkExtensionControl()
        let backend = NativeNetworkExtensionEntranceBackend(control: control)
        let progress = EntranceProgressRecorder()
        backend.setProgressHandler { value in
            Task { await progress.record(value) }
        }
        await control.returnRequiresRebootOnEnable()
        let initialConfiguration = NetworkExtensionRuntimeConfiguration(
            revision: 10,
            dnsEnabled: false
        )
        let initial = NativeEntranceTransaction(
            activation: NativeEntranceActivation(
                revision: 10,
                enabled: [.appRouting],
                generation: 1
            ),
            runtimeConfiguration: initialConfiguration
        )

        #expect(try await backend.apply(initial, replacing: nil) == .requiresReboot)
        for _ in 0..<20 {
            if !(await progress.values).isEmpty { break }
            await Task.yield()
        }
        #expect(await progress.values == [.awaitingSystemExtensionApproval])

        let replacementConfiguration = NetworkExtensionRuntimeConfiguration(
            revision: 11,
            dnsEnabled: false
        )
        let replacement = NativeEntranceTransaction(
            activation: NativeEntranceActivation(
                revision: 11,
                enabled: [.appRouting],
                generation: 2
            ),
            runtimeConfiguration: replacementConfiguration
        )
        await control.failNextUpdate()
        await #expect(throws: EntranceNetworkExtensionError.updateFailed) {
            _ = try await backend.apply(replacement, replacing: initial)
        }
        #expect(await control.updatedConfigurations == [
            replacementConfiguration,
            initialConfiguration,
        ])
    }

    @Test("System Proxy to App Routing restores the exact snapshot before activation")
    func systemProxyToAppRoutingIsTransactional() async throws {
        let control = RecordingEntranceNetworkExtensionControl()
        let proxy = RecordingSystemProxyBoundary()
        let backend = NativeNetworkExtensionEntranceBackend(control: control, systemProxy: proxy)
        let snapshotURL = URL(fileURLWithPath: "/tmp/mclash-test-snapshot.json")
        let endpoints = try LocalSystemProxyEndpoints(mixedPort: 18_901)
        let system = NativeEntranceTransaction(
            activation: NativeEntranceActivation(revision: 1, enabled: [.systemProxy], generation: 1),
            systemProxyConfiguration: NativeSystemProxyConfiguration(
                endpoints: endpoints, bypassDomains: ["localhost"], snapshotURL: snapshotURL
            )
        )
        _ = try await backend.apply(system, replacing: nil)

        let runtime = NetworkExtensionRuntimeConfiguration(revision: 2, dnsEnabled: false)
        let app = NativeEntranceTransaction(
            activation: NativeEntranceActivation(revision: 2, enabled: [.appRouting], generation: 2),
            runtimeConfiguration: runtime
        )
        _ = try await backend.apply(app, replacing: system)

        #expect(await proxy.restoredURLs == [snapshotURL])
        #expect(await control.enabledConfigurations == [runtime])
    }

    @Test("App Routing to System Proxy failure restores the previous connector")
    func appRoutingToSystemProxyRollsBack() async throws {
        let control = RecordingEntranceNetworkExtensionControl()
        let proxy = RecordingSystemProxyBoundary()
        let backend = NativeNetworkExtensionEntranceBackend(control: control, systemProxy: proxy)
        let runtime = NetworkExtensionRuntimeConfiguration(revision: 3, dnsEnabled: false)
        let app = NativeEntranceTransaction(
            activation: NativeEntranceActivation(revision: 3, enabled: [.appRouting], generation: 3),
            runtimeConfiguration: runtime
        )
        _ = try await backend.apply(app, replacing: nil)

        await proxy.failNextActivation()
        let system = NativeEntranceTransaction(
            activation: NativeEntranceActivation(revision: 4, enabled: [.systemProxy], generation: 4),
            systemProxyConfiguration: NativeSystemProxyConfiguration(
                endpoints: try LocalSystemProxyEndpoints(mixedPort: 18_902),
                bypassDomains: nil,
                snapshotURL: URL(fileURLWithPath: "/tmp/mclash-test-snapshot-2.json")
            )
        )
        await #expect(throws: RecordingSystemProxyError.activationFailed) {
            _ = try await backend.apply(system, replacing: app)
        }

        #expect(await control.disableCount == 1)
        #expect(await control.enabledConfigurations == [runtime])
    }

    @Test("Native lifecycle can commit an explicit same-revision rollback")
    func nativeLifecycleCommitsExplicitRollback() async throws {
        let control = RecordingEntranceNetworkExtensionControl()
        let coordinator = NativeEntranceLifecycleCoordinator(
            backend: NativeNetworkExtensionEntranceBackend(control: control)
        )
        let initialConfiguration = NetworkExtensionRuntimeConfiguration(
            revision: 20,
            dnsEnabled: false
        )
        let initial = NativeEntranceActivation(
            revision: 20,
            enabled: [.appRouting],
            generation: 20
        )
        _ = try await coordinator.activate(NativeEntranceTransaction(
            activation: initial,
            runtimeConfiguration: initialConfiguration
        ))

        let candidateConfiguration = NetworkExtensionRuntimeConfiguration(
            revision: 21,
            dnsEnabled: false
        )
        let candidate = NativeEntranceActivation(
            revision: 21,
            enabled: [.appRouting],
            generation: 21
        )
        _ = try await coordinator.activate(NativeEntranceTransaction(
            activation: candidate,
            runtimeConfiguration: candidateConfiguration
        ))

        // Runtime payload revision 20 is restored while lifecycle revision 21
        // remains monotonic. This is the shape AppModel uses after a later
        // stage rejects an otherwise successful live provider update.
        let rollback = NativeEntranceActivation(
            revision: 21,
            enabled: [.appRouting],
            generation: 22
        )
        _ = try await coordinator.activate(NativeEntranceTransaction(
            activation: rollback,
            runtimeConfiguration: initialConfiguration
        ))

        #expect(await control.updatedConfigurations == [
            candidateConfiguration,
            initialConfiguration,
        ])
        #expect(await coordinator.state == .active(rollback))
        try await coordinator.deactivate()
        #expect(await control.disableCount == 1)
        #expect(await coordinator.state == .inactive)
    }
}

private actor RecordingEntranceBackend: NativeEntranceLifecycleBackend {
    struct ApplyRecord: Sendable {
        let transaction: NativeEntranceTransaction
        let previous: NativeEntranceTransaction?
    }

    var applied: [ApplyRecord] = []
    var deactivated: [NativeEntranceTransaction] = []
    private var shouldFail = false
    private var nextOutcome: NativeEntranceApplyOutcome = .running

    func apply(
        _ transaction: NativeEntranceTransaction,
        replacing previous: NativeEntranceTransaction?
    ) async throws -> NativeEntranceApplyOutcome {
        if shouldFail {
            shouldFail = false
            throw RecordingEntranceError.applyFailed
        }
        applied.append(ApplyRecord(transaction: transaction, previous: previous))
        let outcome = nextOutcome
        nextOutcome = .running
        return outcome
    }

    func deactivate(_ transaction: NativeEntranceTransaction) async throws {
        deactivated.append(transaction)
    }

    func failNextApply() { shouldFail = true }
    func returnRequiresReboot() { nextOutcome = .requiresReboot }
}

private actor RecordingSystemProxyBoundary: NativeSystemProxySideEffectBoundary {
    private(set) var activations: [NativeSystemProxyConfiguration] = []
    private(set) var restoredURLs: [URL] = []
    private(set) var deactivatedURLs: [URL?] = []
    private var shouldFailActivation = false

    func activate(_ configuration: NativeSystemProxyConfiguration) async throws {
        if shouldFailActivation {
            shouldFailActivation = false
            throw RecordingSystemProxyError.activationFailed
        }
        activations.append(configuration)
    }

    func restore(snapshotAt url: URL) async throws { restoredURLs.append(url) }
    func deactivate(snapshotAt url: URL?) async throws { deactivatedURLs.append(url) }
    func failNextActivation() { shouldFailActivation = true }
}

private enum RecordingSystemProxyError: Error, Equatable {
    case activationFailed
}

private enum RecordingEntranceError: Error, Equatable, LocalizedError {
    case applyFailed

    var errorDescription: String? { "recording backend apply failed" }
}

private actor EntranceProgressRecorder {
    var values: [NetworkExtensionEnableProgress] = []
    func record(_ value: NetworkExtensionEnableProgress) { values.append(value) }
}

private actor RecordingEntranceNetworkExtensionControl: NetworkExtensionControlling {
    private var nextEnableOutcome: NetworkExtensionEnableOutcome = .running
    private var shouldFailNextUpdate = false
    private(set) var updatedConfigurations: [NetworkExtensionRuntimeConfiguration] = []
    private(set) var enabledConfigurations: [NetworkExtensionRuntimeConfiguration] = []
    private(set) var disableCount = 0

    func returnRequiresRebootOnEnable() {
        nextEnableOutcome = .requiresReboot
    }

    func failNextUpdate() {
        shouldFailNextUpdate = true
    }

    func enable(
        _ configuration: NetworkExtensionRuntimeConfiguration,
        progress reportProgress: @escaping @Sendable (
            NetworkExtensionEnableProgress
        ) -> Void
    ) async throws -> NetworkExtensionEnableOutcome {
        enabledConfigurations.append(configuration)
        reportProgress(.awaitingSystemExtensionApproval)
        let outcome = nextEnableOutcome
        nextEnableOutcome = .running
        return outcome
    }

    func updateRuntimeConfiguration(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> NetworkExtensionEnableOutcome {
        updatedConfigurations.append(configuration)
        if shouldFailNextUpdate {
            shouldFailNextUpdate = false
            throw EntranceNetworkExtensionError.updateFailed
        }
        return .running
    }

    func disable() async throws { disableCount += 1 }
    func uninstall() async throws -> NetworkExtensionUninstallOutcome { .uninstalled }
    func currentState() async -> NetworkExtensionControlState { .inactive }
    func providerRuntimeStatus() async throws -> TransparentProxyProviderStatus {
        throw EntranceNetworkExtensionError.unavailable
    }
    func appRoutingActivity(
        after cursor: UInt64,
        limit: Int
    ) async throws -> AppRoutingActivityBatch {
        _ = limit
        return AppRoutingActivityBatch(
            activities: [],
            nextCursor: cursor,
            droppedBeforeSequence: nil,
            hasMore: false
        )
    }
    func clearAppRoutingActivity() async throws {}
}

private enum EntranceNetworkExtensionError: Error, Equatable {
    case updateFailed
    case unavailable
}
