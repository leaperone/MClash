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

public enum ProfileRouteListenerProtocol: String, Codable, CaseIterable, Sendable {
    case mixed
    case socks
    case http
}

public enum ProfileRouteListenerTarget: Equatable, Hashable, Sendable {
    case profileRules
    case subRule(String)
    case global
    case policyGroup(String)
    case proxyNode(String)

    var outboundProxy: String? {
        switch self {
        case .profileRules, .subRule:
            nil
        case .global:
            "GLOBAL"
        case let .policyGroup(name), let .proxyNode(name):
            name
        }
    }

    var subRuleName: String? {
        if case let .subRule(name) = self { return name }
        return nil
    }

    var presentationName: String {
        switch self {
        case .profileRules: "Profile Rules"
        case let .subRule(name): name
        case .global: "GLOBAL"
        case let .policyGroup(name), let .proxyNode(name): name
        }
    }
}

extension ProfileRouteListenerTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case name
    }

    private enum Kind: String, Codable {
        case profileRules
        case subRule
        case global
        case policyGroup
        case proxyNode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .profileRules:
            self = .profileRules
        case .subRule:
            self = .subRule(try container.decode(String.self, forKey: .name))
        case .global:
            self = .global
        case .policyGroup:
            self = .policyGroup(try container.decode(String.self, forKey: .name))
        case .proxyNode:
            self = .proxyNode(try container.decode(String.self, forKey: .name))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .profileRules:
            try container.encode(Kind.profileRules, forKey: .kind)
        case let .subRule(name):
            try container.encode(Kind.subRule, forKey: .kind)
            try container.encode(name, forKey: .name)
        case .global:
            try container.encode(Kind.global, forKey: .kind)
        case let .policyGroup(name):
            try container.encode(Kind.policyGroup, forKey: .kind)
            try container.encode(name, forKey: .name)
        case let .proxyNode(name):
            try container.encode(Kind.proxyNode, forKey: .kind)
            try container.encode(name, forKey: .name)
        }
    }
}

/// A stable local proxy entry point tied to one real Profile.
public struct ProfileRouteListenerSpec: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var profileID: ProfileID
    public var enabled: Bool
    public var name: String
    public var protocolType: ProfileRouteListenerProtocol
    public var port: Int
    public var target: ProfileRouteListenerTarget

    public init(
        id: UUID = UUID(),
        profileID: ProfileID,
        enabled: Bool = true,
        name: String,
        protocolType: ProfileRouteListenerProtocol = .socks,
        port: Int,
        target: ProfileRouteListenerTarget = .profileRules
    ) {
        self.id = id
        self.profileID = profileID
        self.enabled = enabled
        self.name = name
        self.protocolType = protocolType
        self.port = port
        self.target = target
    }

    var mihomoListenerName: String {
        "mclash-route-\(id.uuidString.lowercased())"
    }
}

/// Versioned, durable desired state for the profile core fleet.
public struct ProfileRuntimePlan: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    /// Stable listener for the virtual Default Profile. Changing which real
    /// profile is primary never changes this entry point.
    public var defaultMixedPort: Int
    public var sessions: [ProfileSessionSpec]
    /// The real profile currently backing the virtual Default Profile.
    public var primaryProfileID: ProfileID?
    public var routeListeners: [ProfileRouteListenerSpec]

    public init(
        schemaVersion: Int = ProfileRuntimePlan.currentSchemaVersion,
        defaultMixedPort: Int? = nil,
        sessions: [ProfileSessionSpec] = [],
        primaryProfileID: ProfileID? = nil,
        routeListeners: [ProfileRouteListenerSpec] = []
    ) {
        self.schemaVersion = schemaVersion
        self.defaultMixedPort = defaultMixedPort
            ?? Self.firstAvailablePort(
                excluding: Set(sessions.map(\.mixedPort) + routeListeners.map(\.port))
            )
        self.sessions = sessions
        self.primaryProfileID = primaryProfileID
        self.routeListeners = routeListeners
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
        case routeListeners
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
            schemaVersion = decodedVersion == 2
                ? Self.currentSchemaVersion
                : decodedVersion
            defaultMixedPort = try container.decodeIfPresent(
                Int.self,
                forKey: .defaultMixedPort
            ) ?? 0
        }
        sessions = decodedSessions
        primaryProfileID = decodedPrimary
        routeListeners = try container.decodeIfPresent(
            [ProfileRouteListenerSpec].self,
            forKey: .routeListeners
        ) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(defaultMixedPort, forKey: .defaultMixedPort)
        try container.encode(sessions, forKey: .sessions)
        try container.encodeIfPresent(primaryProfileID, forKey: .primaryProfileID)
        try container.encode(routeListeners, forKey: .routeListeners)
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
        var sessionsByProfileID: [ProfileID: ProfileSessionSpec] = [:]
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
            sessionsByProfileID[session.profileID] = session
        }

        var listenerIDs = Set<UUID>()
        var listenerNames = Set<String>()
        for listener in plan.routeListeners {
            guard listenerIDs.insert(listener.id).inserted else {
                throw ProfileRuntimePlanValidationError.duplicateRouteListenerID(
                    listener.id
                )
            }
            guard let session = sessionsByProfileID[listener.profileID] else {
                throw ProfileRuntimePlanValidationError.routeListenerProfileMissing(
                    listener.profileID
                )
            }
            if listener.enabled, !session.enabled {
                throw ProfileRuntimePlanValidationError.routeListenerProfileDisabled(
                    listener.profileID
                )
            }
            let name = listener.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !Self.containsUnsafeScalar(listener.name) else {
                throw ProfileRuntimePlanValidationError.invalidRouteListenerName(
                    listener.name
                )
            }
            let normalizedName = name.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard listenerNames.insert(normalizedName).inserted else {
                throw ProfileRuntimePlanValidationError.duplicateRouteListenerName(
                    name
                )
            }
            guard (1...65_535).contains(listener.port) else {
                throw ProfileRuntimePlanValidationError.invalidRouteListenerPort(
                    listener.port
                )
            }
            guard mixedPorts.insert(listener.port).inserted else {
                throw ProfileRuntimePlanValidationError.routeListenerPortConflict(
                    listener.port
                )
            }
            switch listener.target {
            case .profileRules, .global:
                break
            case let .subRule(value),
                 let .policyGroup(value),
                 let .proxyNode(value):
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !Self.containsUnsafeScalar(value) else {
                    throw ProfileRuntimePlanValidationError.invalidRouteListenerTarget(
                        value
                    )
                }
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

    private static func containsUnsafeScalar(_ value: String) -> Bool {
        value.contains { $0 == "\n" || $0 == "\r" || $0 == "\0" }
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
    case duplicateRouteListenerID(UUID)
    case duplicateRouteListenerName(String)
    case invalidRouteListenerName(String)
    case invalidRouteListenerPort(Int)
    case routeListenerPortConflict(Int)
    case routeListenerProfileMissing(ProfileID)
    case routeListenerProfileDisabled(ProfileID)
    case invalidRouteListenerTarget(String)
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
        case let .duplicateRouteListenerID(id):
            "Two routing ports use the same identifier (\(id.uuidString))."
        case let .duplicateRouteListenerName(name):
            "Routing port names must be unique; “\(name)” is used more than once."
        case let .invalidRouteListenerName(name):
            "“\(name)” is not a valid routing port name."
        case let .invalidRouteListenerPort(port):
            "Routing port \(port) is outside the valid range of 1 through 65535."
        case let .routeListenerPortConflict(port):
            "Port \(port) is already assigned to another MClash listener."
        case let .routeListenerProfileMissing(profileID):
            "A routing port refers to Profile \(profileID), which is not present in the runtime plan."
        case let .routeListenerProfileDisabled(profileID):
            "Enable the dedicated session for Profile \(profileID) before enabling its routing ports."
        case let .invalidRouteListenerTarget(target):
            "“\(target)” is not a valid routing target."
        }
    }
}
