import Darwin
import Foundation
import Testing
@testable import MClashApp

@Suite("Core fleet supervisor")
struct CoreFleetSupervisorTests {
    @Test("Reconcile starts and queries independent profile sessions")
    func reconcileStartsIndependentSessions() async throws {
        let fixture = try CoreFleetFixture()
        defer { fixture.cleanup() }
        let first = ProfileID()
        let second = ProfileID()
        let plan = ProfileRuntimePlan(
            sessions: [
                ProfileSessionSpec(profileID: first, mixedPort: 17_890),
                ProfileSessionSpec(profileID: second, mixedPort: 17_891),
            ],
            primaryProfileID: first
        )
        let configurations = try fixture.configurations(
            for: [first, second]
        )

        let result = try await fixture.fleet.reconcile(
            plan: plan,
            launchConfigurations: configurations
        )

        #expect(result[first] == .started)
        #expect(result[second] == .started)
        guard case .running = await fixture.fleet.state(for: first) else {
            Issue.record("Expected the first profile core to be running")
            return
        }
        guard case .running = await fixture.fleet.state(for: second) else {
            Issue.record("Expected the second profile core to be running")
            return
        }
        #expect(await fixture.fleet.states().count == 2)

        let stopped = await fixture.fleet.stopAll()
        #expect(stopped == [first: true, second: true])
        #expect(await fixture.fleet.state(for: first) == .stopped)
        #expect(await fixture.fleet.state(for: second) == .stopped)
    }

    @Test("Reconcile stops only sessions removed from desired state")
    func reconcileStopsRemovedSessionOnly() async throws {
        let fixture = try CoreFleetFixture()
        defer { fixture.cleanup() }
        let first = ProfileID()
        let second = ProfileID()
        let configurations = try fixture.configurations(for: [first, second])
        let initialPlan = ProfileRuntimePlan(sessions: [
            ProfileSessionSpec(profileID: first, mixedPort: 17_892),
            ProfileSessionSpec(profileID: second, mixedPort: 17_893),
        ])
        _ = try await fixture.fleet.reconcile(
            plan: initialPlan,
            launchConfigurations: configurations
        )
        guard case let .running(secondSessionBefore) =
            await fixture.fleet.state(for: second)
        else {
            Issue.record("Expected the second profile core to be running")
            return
        }

        let reducedPlan = ProfileRuntimePlan(
            sessions: [
                ProfileSessionSpec(
                    profileID: first,
                    enabled: false,
                    mixedPort: 17_892
                ),
                ProfileSessionSpec(profileID: second, mixedPort: 17_893),
            ],
            primaryProfileID: second
        )
        let result = try await fixture.fleet.reconcile(
            plan: reducedPlan,
            launchConfigurations: configurations
        )

        #expect(result[first] == .stopped)
        #expect(result[second] == .unchanged)
        #expect(await fixture.fleet.state(for: first) == .stopped)
        guard case let .running(secondSessionAfter) =
            await fixture.fleet.state(for: second)
        else {
            Issue.record("Expected the second profile core to remain running")
            return
        }
        #expect(secondSessionAfter == secondSessionBefore)

        #expect(await fixture.fleet.stop(profileID: second))
    }

    @Test("One profile launch failure does not stop an unrelated session")
    func launchFailureIsIsolated() async throws {
        let fixture = try CoreFleetFixture()
        defer { fixture.cleanup() }
        let first = ProfileID()
        let second = ProfileID()
        let plan = ProfileRuntimePlan(sessions: [
            ProfileSessionSpec(profileID: first, mixedPort: 17_894),
            ProfileSessionSpec(profileID: second, mixedPort: 17_895),
        ])
        var configurations = try fixture.configurations(for: [first, second])
        _ = try await fixture.fleet.reconcile(
            plan: plan,
            launchConfigurations: configurations
        )
        guard case let .running(secondSessionBefore) =
            await fixture.fleet.state(for: second)
        else {
            Issue.record("Expected the second profile core to be running")
            return
        }

        configurations[first] = fixture.missingBinaryConfiguration(
            for: first,
            controllerPort: 19_120
        )
        let result = try await fixture.fleet.reconcile(
            plan: plan,
            launchConfigurations: configurations
        )

        guard case .failed = result[first] else {
            Issue.record("Expected the first profile restart to fail")
            return
        }
        #expect(result[second] == .unchanged)
        guard case let .running(secondSessionAfter) =
            await fixture.fleet.state(for: second)
        else {
            Issue.record("Expected the unrelated profile core to remain running")
            return
        }
        #expect(secondSessionAfter == secondSessionBefore)

        _ = await fixture.fleet.stopAll()
    }

    @Test("Missing launch configuration is isolated to its profile")
    func missingLaunchConfigurationIsIsolated() async throws {
        let fixture = try CoreFleetFixture()
        defer { fixture.cleanup() }
        let first = ProfileID()
        let second = ProfileID()
        let plan = ProfileRuntimePlan(sessions: [
            ProfileSessionSpec(profileID: first, mixedPort: 17_896),
            ProfileSessionSpec(profileID: second, mixedPort: 17_897),
        ])
        let configurations = try fixture.configurations(for: [second])

        let result = try await fixture.fleet.reconcile(
            plan: plan,
            launchConfigurations: configurations
        )

        guard case let .failed(message) = result[first] else {
            Issue.record("Expected a profile-scoped missing configuration failure")
            return
        }
        #expect(message.contains(first.description))
        #expect(result[second] == .started)
        #expect(await fixture.fleet.state(for: first) == nil)
        guard case .running = await fixture.fleet.state(for: second) else {
            Issue.record("Expected the configured profile core to be running")
            return
        }

        _ = await fixture.fleet.stopAll()
    }

    @Test("Forwarded core events carry their profile identity")
    func eventsCarryProfileIdentity() async throws {
        let fixture = try CoreFleetFixture()
        defer { fixture.cleanup() }
        let profileID = ProfileID()
        let plan = ProfileRuntimePlan(
            sessions: [
                ProfileSessionSpec(profileID: profileID, mixedPort: 17_898),
            ],
            primaryProfileID: profileID
        )
        let configuration = try fixture.configurations(for: [profileID])
        let runningEvent = Task { () -> ProfileID? in
            for await event in fixture.fleet.events {
                if case let .stateChanged(observedProfileID, .running) = event {
                    return observedProfileID
                }
            }
            return nil
        }

        _ = try await fixture.fleet.reconcile(
            plan: plan,
            launchConfigurations: configuration
        )

        #expect(await runningEvent.value == profileID)
        #expect(await fixture.fleet.stop(profileID: profileID))
    }

    @Test("Invalid desired plan is rejected before changing running sessions")
    func invalidPlanDoesNotMutateFleet() async throws {
        let fixture = try CoreFleetFixture()
        defer { fixture.cleanup() }
        let profileID = ProfileID()
        let validPlan = ProfileRuntimePlan(
            sessions: [
                ProfileSessionSpec(profileID: profileID, mixedPort: 17_899),
            ],
            primaryProfileID: profileID
        )
        let configurations = try fixture.configurations(for: [profileID])
        _ = try await fixture.fleet.reconcile(
            plan: validPlan,
            launchConfigurations: configurations
        )
        guard case let .running(sessionBefore) =
            await fixture.fleet.state(for: profileID)
        else {
            Issue.record("Expected the profile core to be running")
            return
        }

        let invalidPlan = ProfileRuntimePlan(sessions: [
            ProfileSessionSpec(profileID: profileID, mixedPort: 17_899),
            ProfileSessionSpec(profileID: ProfileID(), mixedPort: 17_899),
        ])
        await #expect(throws: ProfileRuntimePlanValidationError.self) {
            _ = try await fixture.fleet.reconcile(
                plan: invalidPlan,
                launchConfigurations: configurations
            )
        }

        guard case let .running(sessionAfter) =
            await fixture.fleet.state(for: profileID)
        else {
            Issue.record("Expected the profile core to remain running")
            return
        }
        #expect(sessionAfter == sessionBefore)

        #expect(await fixture.fleet.stop(profileID: profileID))
    }
}

private final class CoreFleetFixture: @unchecked Sendable {
    let fleet: CoreFleetSupervisor

    private let root: URL
    private let executableURL: URL
    private var homeDirectories: [URL] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mclash-core-fleet-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        executableURL = root.appendingPathComponent(
            "fleet-test-core",
            isDirectory: false
        )
        try Data(
            """
            #!/bin/sh
            if [ "$1" = "-t" ]; then
              exit 0
            fi
            printf '%s' "$$" > "$2/pid"
            trap 'exit 0' TERM INT
            while :; do sleep 1; done
            """.utf8
        ).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        fleet = CoreFleetSupervisor(
            supervisorFactory: { _ in
                CoreSupervisor(readinessProbe: { _ in "fleet-test-core" })
            }
        )
    }

    func configurations(
        for profileIDs: [ProfileID]
    ) throws -> [ProfileID: CoreLaunchConfiguration] {
        var result: [ProfileID: CoreLaunchConfiguration] = [:]
        for (offset, profileID) in profileIDs.enumerated() {
            result[profileID] = try configuration(
                for: profileID,
                controllerPort: UInt16(19_100 + offset)
            )
        }
        return result
    }

    func missingBinaryConfiguration(
        for profileID: ProfileID,
        controllerPort: UInt16
    ) -> CoreLaunchConfiguration {
        let homeDirectory = root
            .appendingPathComponent("home", isDirectory: true)
            .appendingPathComponent(profileID.description, isDirectory: true)
        let configURL = root.appendingPathComponent(
            "\(profileID.description).yaml",
            isDirectory: false
        )
        return CoreLaunchConfiguration(
            binaryURL: root.appendingPathComponent("missing-core"),
            homeDirectory: homeDirectory,
            configURL: configURL,
            controllerPort: controllerPort,
            secret: "secret-\(profileID.description)"
        )
    }

    func cleanup() {
        for homeDirectory in homeDirectories {
            let pidURL = homeDirectory.appendingPathComponent("pid")
            guard
                let contents = try? String(contentsOf: pidURL, encoding: .utf8),
                let processIdentifier = Int32(contents)
            else {
                continue
            }
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func configuration(
        for profileID: ProfileID,
        controllerPort: UInt16
    ) throws -> CoreLaunchConfiguration {
        let homeDirectory = root
            .appendingPathComponent("home", isDirectory: true)
            .appendingPathComponent(profileID.description, isDirectory: true)
        homeDirectories.append(homeDirectory)
        let configURL = root.appendingPathComponent(
            "\(profileID.description).yaml",
            isDirectory: false
        )
        try Data("mixed-port: \(controllerPort + 1_000)\n".utf8)
            .write(to: configURL)
        return CoreLaunchConfiguration(
            binaryURL: executableURL,
            homeDirectory: homeDirectory,
            configURL: configURL,
            controllerPort: controllerPort,
            secret: "secret-\(profileID.description)"
        )
    }
}
