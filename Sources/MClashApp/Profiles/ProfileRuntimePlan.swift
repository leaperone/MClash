import Foundation

/// The durable runtime assignment for one profile.
///
/// Listener ports are represented as `Int` so invalid imported documents can
/// be decoded and reported by `ProfileRuntimePlanValidator` instead of failing
/// with an opaque integer decoding error.
public struct ProfileSessionSpec: Codable, Equatable, Sendable {
    public var profileID: ProfileID
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
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sessions: [ProfileSessionSpec]
    public var primaryProfileID: ProfileID?

    public init(
        schemaVersion: Int = ProfileRuntimePlan.currentSchemaVersion,
        sessions: [ProfileSessionSpec] = [],
        primaryProfileID: ProfileID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessions = sessions
        self.primaryProfileID = primaryProfileID
    }

    public static let empty = ProfileRuntimePlan()

    public var enabledSessions: [ProfileSessionSpec] {
        sessions.filter(\.enabled)
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
        var mixedPorts = Set<Int>()
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
        guard primarySession.enabled else {
            throw ProfileRuntimePlanValidationError.primaryProfileDisabled(
                primaryProfileID
            )
        }
    }
}

public enum ProfileRuntimePlanValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case duplicateProfile(ProfileID)
    case invalidMixedPort(profileID: ProfileID, port: Int)
    case duplicateMixedPort(Int)
    case primaryProfileMissing(ProfileID)
    case primaryProfileDisabled(ProfileID)
}

extension ProfileRuntimePlanValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "The profile runtime plan uses unsupported schema version \(version)."
        case let .duplicateProfile(profileID):
            "Profile \(profileID) appears more than once in the runtime plan."
        case let .invalidMixedPort(profileID, port):
            "Profile \(profileID) has invalid mixed port \(port). Use a port from 1 through 65535."
        case let .duplicateMixedPort(port):
            "Mixed port \(port) is assigned to more than one profile."
        case let .primaryProfileMissing(profileID):
            "Primary profile \(profileID) is not present in the runtime plan."
        case let .primaryProfileDisabled(profileID):
            "Primary profile \(profileID) must be enabled."
        }
    }
}
