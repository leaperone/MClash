import Foundation
import Testing
@testable import MClashApp

@Suite("Profile runtime plan")
struct ProfileRuntimePlanTests {
    @Test("Plan validates unique profile and mixed-port assignments")
    func validatesUniqueAssignments() throws {
        let first = ProfileID()
        let second = ProfileID()
        let plan = ProfileRuntimePlan(
            sessions: [
                ProfileSessionSpec(profileID: first, mixedPort: 7_890),
                ProfileSessionSpec(profileID: second, mixedPort: 7_891),
            ],
            primaryProfileID: first
        )

        try ProfileRuntimePlanValidator().validate(plan)
        #expect(plan.enabledSessions.map(\.profileID) == [first, second])
    }

    @Test("Plan rejects duplicate profiles")
    func rejectsDuplicateProfiles() {
        let profileID = ProfileID()
        let plan = ProfileRuntimePlan(sessions: [
            ProfileSessionSpec(profileID: profileID, mixedPort: 7_890),
            ProfileSessionSpec(profileID: profileID, mixedPort: 7_891),
        ])

        #expect(
            throws: ProfileRuntimePlanValidationError.duplicateProfile(profileID)
        ) {
            try ProfileRuntimePlanValidator().validate(plan)
        }
    }

    @Test("Plan rejects duplicate mixed ports, including disabled sessions")
    func rejectsDuplicateMixedPorts() {
        let plan = ProfileRuntimePlan(sessions: [
            ProfileSessionSpec(profileID: ProfileID(), mixedPort: 7_890),
            ProfileSessionSpec(
                profileID: ProfileID(),
                enabled: false,
                mixedPort: 7_890
            ),
        ])

        #expect(
            throws: ProfileRuntimePlanValidationError.duplicateMixedPort(7_890)
        ) {
            try ProfileRuntimePlanValidator().validate(plan)
        }
    }

    @Test(
        "Plan rejects listener ports outside the TCP port range",
        arguments: [0, -1, 65_536]
    )
    func rejectsInvalidPorts(port: Int) {
        let profileID = ProfileID()
        let plan = ProfileRuntimePlan(sessions: [
            ProfileSessionSpec(profileID: profileID, mixedPort: port),
        ])

        #expect(
            throws: ProfileRuntimePlanValidationError.invalidMixedPort(
                profileID: profileID,
                port: port
            )
        ) {
            try ProfileRuntimePlanValidator().validate(plan)
        }
    }

    @Test("Primary profile must exist but its dedicated port may be closed")
    func validatesPrimaryProfile() {
        let enabled = ProfileID()
        let disabled = ProfileID()
        let missing = ProfileID()
        let sessions = [
            ProfileSessionSpec(profileID: enabled, mixedPort: 7_890),
            ProfileSessionSpec(
                profileID: disabled,
                enabled: false,
                mixedPort: 7_891
            ),
        ]

        #expect(
            throws: ProfileRuntimePlanValidationError.primaryProfileMissing(missing)
        ) {
            try ProfileRuntimePlanValidator().validate(
                ProfileRuntimePlan(
                    sessions: sessions,
                    primaryProfileID: missing
                )
            )
        }
        #expect(throws: Never.self) {
            try ProfileRuntimePlanValidator().validate(
                ProfileRuntimePlan(
                    sessions: sessions,
                    primaryProfileID: disabled
                )
            )
        }
    }

    @Test("Virtual Default Profile port is distinct from every real profile")
    func validatesVirtualDefaultPort() {
        let profileID = ProfileID()
        let plan = ProfileRuntimePlan(
            defaultMixedPort: 7_890,
            sessions: [
                ProfileSessionSpec(profileID: profileID, mixedPort: 7_890),
            ],
            primaryProfileID: profileID
        )

        #expect(
            throws: ProfileRuntimePlanValidationError.defaultMixedPortConflict(7_890)
        ) {
            try ProfileRuntimePlanValidator().validate(plan)
        }
    }

    @Test("Store round-trips a versioned plan using private atomic storage")
    func storeRoundTripsVersionedPlanPrivately() async throws {
        let fixture = try ProfileRuntimePlanFixture()
        defer { fixture.cleanup() }
        let profileID = ProfileID()
        let plan = ProfileRuntimePlan(
            sessions: [
                ProfileSessionSpec(profileID: profileID, mixedPort: 18_900),
            ],
            primaryProfileID: profileID
        )

        #expect(try await fixture.store.load() == .empty)
        try await fixture.store.save(plan)

        let reopened = try ProfileRuntimePlanStore(layout: fixture.layout)
        #expect(try await reopened.load() == plan)

        let persistedData = try Data(contentsOf: fixture.layout.profileRuntimePlanURL)
        let persistedJSON = try #require(
            try JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
        )
        #expect(persistedJSON["schemaVersion"] as? Int == 3)
        #expect(persistedJSON["defaultMixedPort"] != nil)
        #expect(persistedJSON["primaryProfileID"] != nil)
        #expect(persistedJSON["sessions"] != nil)
        #expect(persistedJSON["routeListeners"] != nil)
        #expect(try permissions(of: fixture.layout.rootDirectory) == 0o700)
        #expect(try permissions(of: fixture.layout.stateDirectory) == 0o700)
        #expect(
            try permissions(
                of: fixture.layout.profileRuntimePlanStagingDirectory
            ) == 0o700
        )
        #expect(
            try permissions(of: fixture.layout.profileRuntimePlanURL) == 0o600
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: fixture.layout.profileRuntimePlanStagingDirectory,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    @Test("Schema 1 migrates its primary port to the virtual Default Profile")
    func migratesSchemaOne() throws {
        let profileID = ProfileID()
        let data = try JSONEncoder().encode(
            LegacyRuntimePlan(
                schemaVersion: 1,
                sessions: [
                    ProfileSessionSpec(
                        profileID: profileID,
                        mixedPort: 18_900
                    ),
                ],
                primaryProfileID: profileID
            )
        )

        let migrated = try JSONDecoder().decode(ProfileRuntimePlan.self, from: data)

        #expect(migrated.schemaVersion == 3)
        #expect(migrated.defaultMixedPort == 18_900)
        #expect(migrated.sessions.first?.mixedPort != 18_900)
        #expect(migrated.sessions.first?.enabled == false)
        try ProfileRuntimePlanValidator().validate(migrated)
    }

    @Test("Schema 2 migrates with an empty routing-port collection")
    func migratesSchemaTwo() throws {
        let profileID = ProfileID()
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "defaultMixedPort": 17890,
              "sessions": [
                {
                  "profileID": { "rawValue": "\(profileID.rawValue.uuidString)" },
                  "enabled": false,
                  "mixedPort": 17891
                }
              ],
              "primaryProfileID": { "rawValue": "\(profileID.rawValue.uuidString)" }
            }
            """.utf8
        )

        let migrated = try JSONDecoder().decode(ProfileRuntimePlan.self, from: data)

        #expect(migrated.schemaVersion == 3)
        #expect(migrated.routeListeners.isEmpty)
        try ProfileRuntimePlanValidator().validate(migrated)
    }

    @Test("Routing ports round-trip every protocol and target kind")
    func routeListenersRoundTrip() throws {
        let profileID = ProfileID()
        let listeners = [
            ProfileRouteListenerSpec(
                profileID: profileID,
                name: "Rules",
                protocolType: .mixed,
                port: 18_080,
                target: .profileRules
            ),
            ProfileRouteListenerSpec(
                profileID: profileID,
                name: "Sub-rule",
                protocolType: .http,
                port: 18_081,
                target: .subRule("developer-tools")
            ),
            ProfileRouteListenerSpec(
                profileID: profileID,
                name: "Node",
                protocolType: .socks,
                port: 18_082,
                target: .proxyNode("Tokyo 01")
            ),
        ]
        let plan = ProfileRuntimePlan(
            defaultMixedPort: 17_890,
            sessions: [
                ProfileSessionSpec(
                    profileID: profileID,
                    enabled: true,
                    mixedPort: 17_891
                ),
            ],
            primaryProfileID: profileID,
            routeListeners: listeners
        )

        try ProfileRuntimePlanValidator().validate(plan)
        let decoded = try JSONDecoder().decode(
            ProfileRuntimePlan.self,
            from: JSONEncoder().encode(plan)
        )
        #expect(decoded == plan)
    }

    @Test("Routing ports reserve ports globally and require an enabled Profile session")
    func validatesRouteListenerAssignments() {
        let profileID = ProfileID()
        let disabledSession = ProfileSessionSpec(
            profileID: profileID,
            enabled: false,
            mixedPort: 17_891
        )
        let listener = ProfileRouteListenerSpec(
            profileID: profileID,
            name: "Build",
            port: 18_080
        )

        #expect(
            throws: ProfileRuntimePlanValidationError
                .routeListenerProfileDisabled(profileID)
        ) {
            try ProfileRuntimePlanValidator().validate(ProfileRuntimePlan(
                defaultMixedPort: 17_890,
                sessions: [disabledSession],
                primaryProfileID: profileID,
                routeListeners: [listener]
            ))
        }

        var enabled = disabledSession
        enabled.enabled = true
        var conflicting = listener
        conflicting.port = 17_890
        #expect(
            throws: ProfileRuntimePlanValidationError
                .routeListenerPortConflict(17_890)
        ) {
            try ProfileRuntimePlanValidator().validate(ProfileRuntimePlan(
                defaultMixedPort: 17_890,
                sessions: [enabled],
                primaryProfileID: profileID,
                routeListeners: [conflicting]
            ))
        }
    }

    @Test("Rejected save leaves the previous durable plan intact")
    func rejectedSavePreservesPreviousPlan() async throws {
        let fixture = try ProfileRuntimePlanFixture()
        defer { fixture.cleanup() }
        let first = ProfileID()
        let previous = ProfileRuntimePlan(
            sessions: [
                ProfileSessionSpec(profileID: first, mixedPort: 18_901),
            ],
            primaryProfileID: first
        )
        try await fixture.store.save(previous)

        let invalid = ProfileRuntimePlan(sessions: [
            ProfileSessionSpec(profileID: ProfileID(), mixedPort: 18_902),
            ProfileSessionSpec(profileID: ProfileID(), mixedPort: 18_902),
        ])
        await #expect(throws: ProfileRuntimePlanValidationError.self) {
            try await fixture.store.save(invalid)
        }

        #expect(try await fixture.store.load() == previous)
    }

    @Test("Store rejects unsupported persisted schema versions")
    func rejectsUnsupportedPersistedSchema() async throws {
        let fixture = try ProfileRuntimePlanFixture()
        defer { fixture.cleanup() }
        let futurePlan = ProfileRuntimePlan(schemaVersion: 999)
        let data = try JSONEncoder().encode(futurePlan)
        try data.write(
            to: fixture.layout.profileRuntimePlanURL,
            options: .atomic
        )

        await #expect(
            throws: ProfileRuntimePlanValidationError.unsupportedSchemaVersion(999)
        ) {
            try await fixture.store.load()
        }
    }

    @Test("Store quarantines a readable invalid plan and returns a safe empty plan")
    func quarantinesInvalidPersistedPlan() async throws {
        let fixture = try ProfileRuntimePlanFixture()
        defer { fixture.cleanup() }
        let invalidData = Data(#"{"schemaVersion":999,"sessions":[]}"#.utf8)
        try invalidData.write(
            to: fixture.layout.profileRuntimePlanURL,
            options: .atomic
        )

        let recovery = try await fixture.store.loadRecoveringInvalidDocument()

        #expect(recovery.plan == .empty)
        #expect(recovery.recoveryReason != nil)
        let quarantinedURL = try #require(recovery.quarantinedURL)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.layout.profileRuntimePlanURL.path
        ))
        #expect(try Data(contentsOf: quarantinedURL) == invalidData)
        #expect(try permissions(of: quarantinedURL) == 0o600)
    }

    @Test("Layout isolates runtime config, staging, and core home per profile")
    func layoutIsolatesProfileRuntimeDirectories() throws {
        let fixture = try ProfileRuntimePlanFixture()
        defer { fixture.cleanup() }
        let first = ProfileID()
        let second = ProfileID()

        try fixture.layout.createRuntimeDirectories(for: first)
        try fixture.layout.createRuntimeDirectories(for: second)

        #expect(
            fixture.layout.runtimeConfigurationURL(for: first)
                != fixture.layout.runtimeConfigurationURL(for: second)
        )
        #expect(
            fixture.layout.runtimeConfigurationURL(for: first).path
                == fixture.layout.runtimeSessionDirectory(for: first)
                    .appendingPathComponent("config.yaml").path
        )
        for directory in [
            fixture.layout.runtimeSessionDirectory(for: first),
            fixture.layout.runtimeStagingDirectory(for: first),
            fixture.layout.coreHomeDirectory(for: first),
            fixture.layout.runtimeSessionDirectory(for: second),
            fixture.layout.runtimeStagingDirectory(for: second),
            fixture.layout.coreHomeDirectory(for: second),
        ] {
            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(
                    atPath: directory.path,
                    isDirectory: &isDirectory
                )
            )
            #expect(isDirectory.boolValue)
            #expect(try permissions(of: directory) == 0o700)
        }
    }
}

private struct ProfileRuntimePlanFixture {
    let root: URL
    let layout: ProfileDirectoryLayout
    let store: ProfileRuntimePlanStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mclash-profile-runtime-plan-\(UUID().uuidString)",
            isDirectory: true
        )
        layout = ProfileDirectoryLayout(rootDirectory: root)
        store = try ProfileRuntimePlanStore(layout: layout)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct LegacyRuntimePlan: Encodable {
    let schemaVersion: Int
    let sessions: [ProfileSessionSpec]
    let primaryProfileID: ProfileID?
}

private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
