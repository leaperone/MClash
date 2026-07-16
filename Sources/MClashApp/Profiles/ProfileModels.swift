import Foundation

public struct ProfileID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init() {
        self.rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString.lowercased()
    }
}

public struct RemoteSubscriptionMetadata: Codable, Equatable, Sendable {
    public let url: URL
    public var eTag: String?
    public var lastModified: String?
    public var lastCheckedAt: Date?
    public var lastSuccessfulUpdateAt: Date?

    public init(
        url: URL,
        eTag: String? = nil,
        lastModified: String? = nil,
        lastCheckedAt: Date? = nil,
        lastSuccessfulUpdateAt: Date? = nil
    ) {
        self.url = url
        self.eTag = eTag
        self.lastModified = lastModified
        self.lastCheckedAt = lastCheckedAt
        self.lastSuccessfulUpdateAt = lastSuccessfulUpdateAt
    }
}

public enum ProfileOrigin: Equatable, Sendable {
    case local
    case imported(originalFileName: String)
    case remote(RemoteSubscriptionMetadata)
}

extension ProfileOrigin: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case originalFileName
        case remote
    }

    private enum Kind: String, Codable {
        case local
        case imported
        case remote
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .local:
            self = .local
        case .imported:
            self = .imported(
                originalFileName: try container.decode(String.self, forKey: .originalFileName)
            )
        case .remote:
            self = .remote(
                try container.decode(RemoteSubscriptionMetadata.self, forKey: .remote)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode(Kind.local, forKey: .kind)
        case let .imported(originalFileName):
            try container.encode(Kind.imported, forKey: .kind)
            try container.encode(originalFileName, forKey: .originalFileName)
        case let .remote(remote):
            try container.encode(Kind.remote, forKey: .kind)
            try container.encode(remote, forKey: .remote)
        }
    }
}

public struct ProfileMetadata: Identifiable, Codable, Equatable, Sendable {
    public let id: ProfileID
    public var name: String
    public var origin: ProfileOrigin
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: ProfileID = ProfileID(),
        name: String,
        origin: ProfileOrigin,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ActiveProfileState: Codable, Equatable, Sendable {
    public var profileID: ProfileID?

    public init(profileID: ProfileID?) {
        self.profileID = profileID
    }
}

public enum RemoteProfileRefreshResult: Equatable, Sendable {
    case notModified(ProfileMetadata)
    case updated(ProfileMetadata)
}

public struct RuntimeConfigurationActivation: Equatable, Sendable {
    public let profileID: ProfileID
    public let previousProfileID: ProfileID?
    public let configurationURL: URL

    public init(profileID: ProfileID, previousProfileID: ProfileID?, configurationURL: URL) {
        self.profileID = profileID
        self.previousProfileID = previousProfileID
        self.configurationURL = configurationURL
    }
}
