import Foundation

enum CoreFleetEvent: Equatable, Sendable {
    case stateChanged(profileID: ProfileID, state: CoreRunState)
    case log(profileID: ProfileID, line: CoreLogLine)
}

enum CoreFleetReconcileOutcome: Equatable, Sendable {
    case started
    case restarted
    case unchanged
    case stopped
    case failed(String)
}

struct CoreFleetReconcileResult: Equatable, Sendable {
    let outcomes: [ProfileID: CoreFleetReconcileOutcome]

    subscript(profileID: ProfileID) -> CoreFleetReconcileOutcome? {
        outcomes[profileID]
    }

    var failures: [ProfileID: String] {
        outcomes.reduce(into: [:]) { result, element in
            guard case let .failed(message) = element.value else { return }
            result[element.key] = message
        }
    }
}

/// Owns one independent `CoreSupervisor` for every profile and reconciles the
/// running processes against a validated `ProfileRuntimePlan`.
actor CoreFleetSupervisor {
    typealias SupervisorFactory = @Sendable (ProfileID) -> CoreSupervisor

    nonisolated let events: AsyncStream<CoreFleetEvent>

    private struct ManagedSession {
        let supervisor: CoreSupervisor
        let eventForwarder: Task<Void, Never>
        var lastLaunchConfiguration: CoreLaunchConfiguration?
    }

    private let continuation: AsyncStream<CoreFleetEvent>.Continuation
    private let supervisorFactory: SupervisorFactory
    private let validator: ProfileRuntimePlanValidator
    private var sessions: [ProfileID: ManagedSession] = [:]

    /// CoreSupervisor calls suspend this actor. A small FIFO gate prevents a
    /// concurrent reconcile/stop from interleaving process mutations.
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var emergencyShutdownRequested = false

    init(
        validator: ProfileRuntimePlanValidator = ProfileRuntimePlanValidator(),
        supervisorFactory: @escaping SupervisorFactory = { _ in CoreSupervisor() }
    ) {
        self.validator = validator
        self.supervisorFactory = supervisorFactory
        let pair = AsyncStream<CoreFleetEvent>.makeStream(
            of: CoreFleetEvent.self,
            bufferingPolicy: .bufferingNewest(1_000)
        )
        events = pair.stream
        continuation = pair.continuation
    }

    deinit {
        for session in sessions.values {
            session.eventForwarder.cancel()
        }
        for waiter in mutationWaiters {
            waiter.resume()
        }
        continuation.finish()
    }

    /// Reconciles enabled sessions. Missing/invalid launch configuration for
    /// one profile is reported for that profile without stopping other desired
    /// sessions.
    func reconcile(
        plan: ProfileRuntimePlan,
        launchConfigurations: [ProfileID: CoreLaunchConfiguration]
    ) async throws -> CoreFleetReconcileResult {
        try validator.validate(plan)
        await beginMutation()
        defer { endMutation() }
        guard !emergencyShutdownRequested else {
            throw CancellationError()
        }

        let enabledSessions = plan.enabledSessions
        let desiredProfileIDs = Set(enabledSessions.map(\.profileID))
        var outcomes: [ProfileID: CoreFleetReconcileOutcome] = [:]

        let profilesToStop = sessions.keys
            .filter { !desiredProfileIDs.contains($0) }
            .sorted { $0.description < $1.description }
        for profileID in profilesToStop {
            guard !emergencyShutdownRequested else {
                throw CancellationError()
            }
            guard let session = sessions[profileID] else { continue }
            let state = await session.supervisor.state()
            if state == .stopped {
                outcomes[profileID] = .unchanged
                continue
            }
            let stopped = await session.supervisor.stop()
            outcomes[profileID] = stopped
                ? .stopped
                : .failed(Self.stopFailureMessage(profileID))
        }

        for spec in enabledSessions.sorted(by: {
            $0.profileID.description < $1.profileID.description
        }) {
            guard !emergencyShutdownRequested else {
                throw CancellationError()
            }
            let profileID = spec.profileID
            guard let configuration = launchConfigurations[profileID] else {
                outcomes[profileID] = .failed(
                    CoreFleetSupervisorError
                        .missingLaunchConfiguration(profileID)
                        .localizedDescription
                )
                continue
            }

            let supervisor = supervisor(for: profileID)
            let previousConfiguration = sessions[profileID]?.lastLaunchConfiguration
            let previousState = await supervisor.state()
            guard !emergencyShutdownRequested else {
                throw CancellationError()
            }
            if case .running = previousState,
               previousConfiguration == configuration {
                outcomes[profileID] = .unchanged
                continue
            }

            let isRestart = previousConfiguration != nil
            if previousState != .stopped {
                let stopped = await supervisor.stop()
                guard !emergencyShutdownRequested else {
                    throw CancellationError()
                }
                guard stopped else {
                    outcomes[profileID] = .failed(
                        Self.stopFailureMessage(profileID)
                    )
                    continue
                }
            }

            do {
                guard !emergencyShutdownRequested else {
                    throw CancellationError()
                }
                try await supervisor.start(configuration)
                guard !emergencyShutdownRequested else {
                    _ = await supervisor.stop()
                    throw CancellationError()
                }
                sessions[profileID]?.lastLaunchConfiguration = configuration
                outcomes[profileID] = isRestart ? .restarted : .started
            } catch {
                outcomes[profileID] = .failed(error.localizedDescription)
            }
        }

        return CoreFleetReconcileResult(outcomes: outcomes)
    }

    @discardableResult
    func stop(profileID: ProfileID) async -> Bool {
        await beginMutation()
        defer { endMutation() }
        guard let session = sessions[profileID] else { return true }
        return await session.supervisor.stop()
    }

    /// Stops every known session independently and returns per-profile results.
    @discardableResult
    func stopAll() async -> [ProfileID: Bool] {
        await beginMutation()
        defer { endMutation() }
        var results: [ProfileID: Bool] = [:]
        for profileID in sessions.keys.sorted(by: {
            $0.description < $1.description
        }) {
            guard let session = sessions[profileID] else { continue }
            results[profileID] = await session.supervisor.stop()
        }
        return results
    }

    /// Emergency application termination must not queue behind a reconcile or
    /// stop profiles serially. Mark the fleet terminal first so a reentrant
    /// reconcile cannot launch another process, then ask every known
    /// supervisor to perform its bounded TERM→KILL sequence in parallel.
    @discardableResult
    func forceStopAll() async -> [ProfileID: Bool] {
        emergencyShutdownRequested = true
        let supervisors = sessions.map { ($0.key, $0.value.supervisor) }
        return await withTaskGroup(
            of: (ProfileID, Bool).self,
            returning: [ProfileID: Bool].self
        ) { group in
            for (profileID, supervisor) in supervisors {
                group.addTask {
                    (profileID, await supervisor.stop())
                }
            }
            var results: [ProfileID: Bool] = [:]
            for await (profileID, stopped) in group {
                results[profileID] = stopped
            }
            return results
        }
    }

    func state(for profileID: ProfileID) async -> CoreRunState? {
        guard let session = sessions[profileID] else { return nil }
        return await session.supervisor.state()
    }

    func states() async -> [ProfileID: CoreRunState] {
        var result: [ProfileID: CoreRunState] = [:]
        for (profileID, session) in sessions {
            result[profileID] = await session.supervisor.state()
        }
        return result
    }

    func setProcessLogForwardingEnabled(
        _ enabled: Bool,
        for profileID: ProfileID
    ) {
        sessions[profileID]?.supervisor.setProcessLogForwardingEnabled(enabled)
    }

    func setProcessLogForwardingEnabledForAll(_ enabled: Bool) {
        for session in sessions.values {
            session.supervisor.setProcessLogForwardingEnabled(enabled)
        }
    }

    private func supervisor(for profileID: ProfileID) -> CoreSupervisor {
        if let existing = sessions[profileID] {
            return existing.supervisor
        }

        let supervisor = supervisorFactory(profileID)
        let eventForwarder = Task { [weak self, events = supervisor.events] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.forward(event, profileID: profileID)
            }
        }
        sessions[profileID] = ManagedSession(
            supervisor: supervisor,
            eventForwarder: eventForwarder,
            lastLaunchConfiguration: nil
        )
        return supervisor
    }

    private func forward(_ event: CoreEvent, profileID: ProfileID) {
        switch event {
        case let .stateChanged(state):
            continuation.yield(
                .stateChanged(profileID: profileID, state: state)
            )
        case let .log(line):
            continuation.yield(.log(profileID: profileID, line: line))
        }
    }

    private func beginMutation() async {
        guard mutationInProgress else {
            mutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func endMutation() {
        guard !mutationWaiters.isEmpty else {
            mutationInProgress = false
            return
        }
        mutationWaiters.removeFirst().resume()
    }

    private static func stopFailureMessage(_ profileID: ProfileID) -> String {
        "Profile \(profileID) did not stop before the core shutdown deadline."
    }
}

enum CoreFleetSupervisorError: LocalizedError, Equatable, Sendable {
    case missingLaunchConfiguration(ProfileID)

    var errorDescription: String? {
        switch self {
        case let .missingLaunchConfiguration(profileID):
            "Profile \(profileID) has no core launch configuration."
        }
    }
}
