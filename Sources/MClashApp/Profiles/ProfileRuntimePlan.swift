import Foundation

/// The durable runtime assignment for one profile.
///
/// Listener ports are represented as `Int` so invalid imported documents can
/// be decoded and reported by `ProfileRuntimePlanValidator` instead of failing
/// with an opaque integer decoding error.
public struct ProfileSessionSpec: Codable, Equatable, Sendable {
    public var profileID: ProfileID
    /// Whether this real profile's dedicated MClash-managed Mixed listener
    /// should run. The virtual Default Profile listener is stored separately
    /// on `ProfileRuntimePlan`.
    public var enabled: Bool
    public var mixedPort: Int

    public init(
        profileID: ProfileID,
        enabled: Bool = true,
        mixedPort: Int
    ) {
        self.profileID = profileID
        self.enabled = enabled
        self.mixedPort = mixedPort
    }
}

/// Versioned, durable desired state for the profile core fleet.
public struct ProfileRuntimePlan: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    /// Stable listener for the virtual Default Profile. Changing which real
    /// profile is primary never changes this entry point.
    public var defaultMixedPort: Int
    public var sessions: [ProfileSessionSpec]
    /// The real profile currently backing the virtual Default Profile.
    public var primaryProfileID: ProfileID?

    public init(
        schemaVersion: Int = ProfileRuntimePlan.currentSchemaVersion,
        defaultMixedPort: Int? = nil,
        sessions: [ProfileSessionSpec] = [],
        primaryProfileID: ProfileID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.defaultMixedPort = defaultMixedPort
            ?? Self.firstAvailablePort(excluding: Set(sessions.map(\.mixedPort)))
        self.sessions = sessions
        self.primaryProfileID = primaryProfileID
    }

    public static let empty = ProfileRuntimePlan()

    public var enabledSessions: [ProfileSessionSpec] {
        sessions.filter(\.enabled)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case defaultMixedPort
        case sessions
        case primaryProfileID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(Int.self, forKey: .schemaVersion)
        var decodedSessions = try container.decode(
            [ProfileSessionSpec].self,
            forKey: .sessions
        )
        let decodedPrimary = try container.decodeIfPresent(
            ProfileID.self,
            forKey: .primaryProfileID
        )

        if decodedVersion == 1 {
            // Schema 1 used the primary profile's port as both its identity and
            // the app-wide default entry point. Preserve that public endpoint,
            // then give the real profile a separate, initially closed port.
            let legacyPrimaryIndex = decodedPrimary.flatMap { primary in
                decodedSessions.firstIndex { $0.profileID == primary }
            }
            let legacyDefaultPort = legacyPrimaryIndex.map {
                decodedSessions[$0].mixedPort
            } ?? Self.firstAvailablePort(
                excluding: Set(decodedSessions.map(\.mixedPort))
            )
            if let legacyPrimaryIndex {
                var reservedPorts = Set(decodedSessions.map(\.mixedPort))
                reservedPorts.remove(decodedSessions[legacyPrimaryIndex].mixedPort)
                reservedPorts.insert(legacyDefaultPort)
                decodedSessions[legacyPrimaryIndex].mixedPort =
                    Self.firstAvailablePort(excluding: reservedPorts)
                decodedSessions[legacyPrimaryIndex].enabled = false
            }
            schemaVersion = Self.currentSchemaVersion
            defaultMixedPort = legacyDefaultPort
        } else {
            schemaVersion = decodedVersion
            defaultMixedPort = try container.decodeIfPresent(
                Int.self,
                forKey: .defaultMixedPort
            ) ?? 0
        }
        sessions = decodedSessions
        primaryProfileID = decodedPrimary
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(defaultMixedPort, forKey: .defaultMixedPort)
        try container.encode(sessions, forKey: .sessions)
        try container.encodeIfPresent(primaryProfileID, forKey: .primaryProfileID)
    }

    private static func firstAvailablePort(excluding ports: Set<Int>) -> Int {
        (7_890...65_535).first { !ports.contains($0) }
            ?? (1..<7_890).first { !ports.contains($0) }
            ?? 0
    }
}

public struct ProfileRuntimePlanValidator: Sendable {
    public init() {}

    public func validate(_ plan: ProfileRuntimePlan) throws {
        guard plan.schemaVersion == ProfileRuntimePlan.currentSchemaVersion else {
            throw ProfileRuntimePlanValidationError.unsupportedSchemaVersion(
                plan.schemaVersion
            )
        }

        var profileIDs = Set<ProfileID>()
        guard (1...65_535).contains(plan.defaultMixedPort) else {
            throw ProfileRuntimePlanValidationError.invalidDefaultMixedPort(
                plan.defaultMixedPort
            )
        }

        var mixedPorts = Set<Int>([plan.defaultMixedPort])
        for session in plan.sessions {
            guard profileIDs.insert(session.profileID).inserted else {
                throw ProfileRuntimePlanValidationError.duplicateProfile(
                    session.profileID
                )
            }
            guard (1...65_535).contains(session.mixedPort) else {
                throw ProfileRuntimePlanValidationError.invalidMixedPort(
                    profileID: session.profileID,
                    port: session.mixedPort
                )
            }
            guard mixedPorts.insert(session.mixedPort).inserted else {
                if session.mixedPort == plan.defaultMixedPort {
                    throw ProfileRuntimePlanValidationError.defaultMixedPortConflict(
                        session.mixedPort
                    )
                }
                throw ProfileRuntimePlanValidationError.duplicateMixedPort(
                    session.mixedPort
                )
            }
        }

        guard let primaryProfileID = plan.primaryProfileID else { return }
        guard let primarySession = plan.sessions.first(where: {
            $0.profileID == primaryProfileID
        }) else {
            throw ProfileRuntimePlanValidationError.primaryProfileMissing(
                primaryProfileID
            )
        }
        _ = primarySession
    }
}

public enum ProfileRuntimePlanValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case duplicateProfile(ProfileID)
    case invalidDefaultMixedPort(Int)
    case invalidMixedPort(profileID: ProfileID, port: Int)
    case defaultMixedPortConflict(Int)
    case duplicateMixedPort(Int)
    case primaryProfileMissing(ProfileID)
}

extension ProfileRuntimePlanValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "The profile runtime plan uses unsupported schema version \(version)."
        case let .duplicateProfile(profileID):
            "Profile \(profileID) appears more than once in the runtime plan."
        case let .invalidDefaultMixedPort(port):
            "The virtual Default Profile has invalid Mixed port \(port). Use a port from 1 through 65535."
        case let .invalidMixedPort(profileID, port):
            "Profile \(profileID) has invalid mixed port \(port). Use a port from 1 through 65535."
        case let .defaultMixedPortConflict(port):
            "Mixed port \(port) is assigned to both the virtual Default Profile and a real profile."
        case let .duplicateMixedPort(port):
            "Mixed port \(port) is assigned to more than one profile."
        case let .primaryProfileMissing(profileID):
            "Primary profile \(profileID) is not present in the runtime plan."
        }
    }
}
