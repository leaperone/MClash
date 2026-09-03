@testable import MClashApp
import Foundation
import Testing

@Suite("Native entrance lifecycle")
struct NativeEntranceLifecycleTests {
    @Test("Native activation applies both entrances without a Mihomo controller")
    func activatesSystemProxyAndAppRouting() async throws {
        let backend = RecordingEntranceBackend()
        let coordinator = NativeEntranceLifecycleCoordinator(backend: backend)

        let activation = try await coordinator.activate(
            revision: 12,
            enabled: [.systemProxy, .appRouting]
        )

        #expect(activation.revision == 12)
        #expect(activation.systemProxyEnabled)
        #expect(activation.appRoutingEnabled)
        #expect(await coordinator.state == .active(activation))
        #expect(await backend.applied.count == 1)
        #expect(await backend.applied.first == activation)
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
        #expect(await backend.applied == [initial])
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

    @Test("Invalid and stale revisions fail before touching the backend")
    func validatesRevision() async throws {
        let backend = RecordingEntranceBackend()
        let coordinator = NativeEntranceLifecycleCoordinator(backend: backend)
        await #expect(throws: NativeEntranceLifecycleError.invalidRevision) {
            try await coordinator.activate(revision: 0, enabled: [.appRouting])
        }
        _ = try await coordinator.activate(revision: 4, enabled: [.appRouting])
        await #expect(throws: NativeEntranceLifecycleError.staleRevision(current: 4, requested: 2)) {
            try await coordinator.activate(revision: 2, enabled: [.appRouting])
        }
        #expect(await backend.applied.count == 1)
    }
}

private actor RecordingEntranceBackend: NativeEntranceLifecycleBackend {
    var applied: [NativeEntranceActivation] = []
    var deactivated: [NativeEntranceActivation] = []
    private var shouldFail = false

    func apply(_ activation: NativeEntranceActivation) async throws {
        if shouldFail {
            shouldFail = false
            throw RecordingEntranceError.applyFailed
        }
        applied.append(activation)
    }

    func deactivate(_ activation: NativeEntranceActivation) async throws {
        deactivated.append(activation)
    }

    func failNextApply() { shouldFail = true }
}

private enum RecordingEntranceError: Error, Equatable, LocalizedError {
    case applyFailed

    var errorDescription: String? { "recording backend apply failed" }
}
