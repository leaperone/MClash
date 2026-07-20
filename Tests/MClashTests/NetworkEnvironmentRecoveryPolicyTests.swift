import Foundation
import Testing
@testable import MClashApp

@Suite("Network environment recovery policy")
struct NetworkEnvironmentRecoveryPolicyTests {
    private let base = Date(timeIntervalSince1970: 1_000)

    @Test("A disconnected session never schedules automatic recovery")
    func disarmedPolicyIgnoresEnvironmentChanges() {
        var policy = makePolicy()

        #expect(policy.receive(.didWake, at: base) == .none)
        #expect(
            policy.receive(
                .pathChanged(NetworkEnvironmentPath(status: .satisfied)),
                at: base
            ) == .none
        )
        #expect(!policy.recoveryIsScheduled)
    }

    @Test("Path loss cancels pending work and recovery waits for a usable path")
    func pathAvailabilityGatesRecovery() {
        var policy = makePolicy()
        #expect(policy.setArmed(true, at: base) == .none)

        #expect(
            policy.receive(
                .pathChanged(NetworkEnvironmentPath(status: .unsatisfied)),
                at: base
            ) == .cancelScheduledRecovery
        )
        #expect(
            policy.receive(
                .pathChanged(NetworkEnvironmentPath(status: .satisfied)),
                at: base.addingTimeInterval(1)
            ) == .schedule(after: 2)
        )
        #expect(policy.recoveryIsScheduled)
    }

    @Test("Sleep cancels debounce and wake schedules one verification")
    func sleepWakeCoalescesRecovery() {
        var policy = makePolicy()
        _ = policy.setArmed(true, at: base)
        _ = policy.receive(
            .pathChanged(NetworkEnvironmentPath(status: .satisfied)),
            at: base
        )

        #expect(policy.receive(.willSleep, at: base) == .cancelScheduledRecovery)
        #expect(policy.isSleeping)
        #expect(!policy.recoveryIsScheduled)
        #expect(
            policy.receive(.didWake, at: base.addingTimeInterval(5))
                == .schedule(after: 2)
        )
        #expect(!policy.isSleeping)
    }

    @Test("A failed recovery observes the cooldown before retrying")
    func failedRecoveryUsesCooldown() {
        var policy = makePolicy()
        _ = policy.setArmed(true, at: base)
        _ = policy.receive(.didWake, at: base)

        #expect(
            policy.scheduledRecoveryFired(at: base.addingTimeInterval(2)) == .recover
        )
        #expect(
            policy.recoveryCompleted(
                succeeded: false,
                at: base.addingTimeInterval(3)
            ) == .schedule(after: 9)
        )
        #expect(
            policy.scheduledRecoveryFired(at: base.addingTimeInterval(12)) == .recover
        )
    }

    @Test("Repeated failures are bounded inside the failure window")
    func repeatedFailuresAreSuppressed() {
        var policy = NetworkEnvironmentRecoveryPolicy(
            configuration: .init(
                debounceInterval: 0,
                minimumRecoveryInterval: 0,
                failureWindow: 300,
                maximumFailedRecoveries: 2
            )
        )
        _ = policy.setArmed(true, at: base)
        _ = policy.receive(.didWake, at: base)

        #expect(policy.scheduledRecoveryFired(at: base) == .recover)
        #expect(
            policy.recoveryCompleted(succeeded: false, at: base)
                == .schedule(after: 0)
        )
        #expect(policy.scheduledRecoveryFired(at: base) == .recover)
        #expect(
            policy.recoveryCompleted(succeeded: false, at: base)
                == .schedule(after: 0)
        )
        #expect(
            policy.scheduledRecoveryFired(at: base)
                == .suppressAfterRepeatedFailures
        )
    }

    private func makePolicy() -> NetworkEnvironmentRecoveryPolicy {
        NetworkEnvironmentRecoveryPolicy(
            configuration: .init(
                debounceInterval: 2,
                minimumRecoveryInterval: 10,
                failureWindow: 60,
                maximumFailedRecoveries: 3
            )
        )
    }
}
