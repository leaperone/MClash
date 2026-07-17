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

public struct SubscriptionUsage: Codable, Equatable, Sendable {
    public var upload: Int64?
    public var download: Int64?
    public var total: Int64?
    public var expiresAt: Date?

    public init(
        upload: Int64? = nil,
        download: Int64? = nil,
        total: Int64? = nil,
        expiresAt: Date? = nil
    ) {
        self.upload = upload
        self.download = download
        self.total = total
        self.expiresAt = expiresAt
    }

    public var used: Int64? {
        guard upload != nil || download != nil else { return nil }
        return (upload ?? 0) + (download ?? 0)
    }
}

public struct RemoteSubscriptionMetadata: Equatable, Sendable {
    public let url: URL
    public var eTag: String?
    public var lastModified: String?
    public var lastCheckedAt: Date?
    public var lastSuccessfulUpdateAt: Date?
    public var automaticUpdatesEnabled: Bool
    public var updateIntervalHours: Int?
    public var providerSuggestedUpdateIntervalHours: Int?
    public var usage: SubscriptionUsage?
    public var webPageURL: URL?

    public init(
        url: URL,
        eTag: String? = nil,
        lastModified: String? = nil,
        lastCheckedAt: Date? = nil,
        lastSuccessfulUpdateAt: Date? = nil,
        automaticUpdatesEnabled: Bool = true,
        updateIntervalHours: Int? = nil,
        providerSuggestedUpdateIntervalHours: Int? = nil,
        usage: SubscriptionUsage? = nil,
        webPageURL: URL? = nil
    ) {
        self.url = url
        self.eTag = eTag
        self.lastModified = lastModified
        self.lastCheckedAt = lastCheckedAt
        self.lastSuccessfulUpdateAt = lastSuccessfulUpdateAt
        self.automaticUpdatesEnabled = automaticUpdatesEnabled
        self.updateIntervalHours = Self.normalizedInterval(updateIntervalHours)
        self.providerSuggestedUpdateIntervalHours = Self.normalizedInterval(
            providerSuggestedUpdateIntervalHours
        )
        self.usage = usage
        self.webPageURL = webPageURL
    }

    public var effectiveUpdateIntervalHours: Int {
        updateIntervalHours ?? providerSuggestedUpdateIntervalHours ?? 24
    }

    public func nextAutomaticUpdateAt() -> Date? {
        guard automaticUpdatesEnabled else { return nil }
        guard let anchor = lastCheckedAt ?? lastSuccessfulUpdateAt else { return nil }
        return anchor.addingTimeInterval(TimeInterval(effectiveUpdateIntervalHours) * 3_600)
    }

    public func isAutomaticUpdateDue(at date: Date) -> Bool {
        guard automaticUpdatesEnabled else { return false }
        guard let next = nextAutomaticUpdateAt() else { return true }
        return next <= date
    }

    private static func normalizedInterval(_ value: Int?) -> Int? {
        guard let value, (1...8_760).contains(value) else { return nil }
        return value
    }
}

extension RemoteSubscriptionMetadata: Codable {
    private enum CodingKeys: String, CodingKey {
        case url
        case eTag
        case lastModified
        case lastCheckedAt
        case lastSuccessfulUpdateAt
        case automaticUpdatesEnabled
        case updateIntervalHours
        case providerSuggestedUpdateIntervalHours
        case usage
        case webPageURL
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            url: try container.decode(URL.self, forKey: .url),
            eTag: try container.decodeIfPresent(String.self, forKey: .eTag),
            lastModified: try container.decodeIfPresent(String.self, forKey: .lastModified),
            lastCheckedAt: try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt),
            lastSuccessfulUpdateAt: try container.decodeIfPresent(
                Date.self,
                forKey: .lastSuccessfulUpdateAt
            ),
            automaticUpdatesEnabled: try container.decodeIfPresent(
                Bool.self,
                forKey: .automaticUpdatesEnabled
            ) ?? true,
            updateIntervalHours: try container.decodeIfPresent(
                Int.self,
                forKey: .updateIntervalHours
            ),
            providerSuggestedUpdateIntervalHours: try container.decodeIfPresent(
                Int.self,
                forKey: .providerSuggestedUpdateIntervalHours
            ),
            usage: try container.decodeIfPresent(SubscriptionUsage.self, forKey: .usage),
            webPageURL: try container.decodeIfPresent(URL.self, forKey: .webPageURL)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(eTag, forKey: .eTag)
        try container.encodeIfPresent(lastModified, forKey: .lastModified)
        try container.encodeIfPresent(lastCheckedAt, forKey: .lastCheckedAt)
        try container.encodeIfPresent(lastSuccessfulUpdateAt, forKey: .lastSuccessfulUpdateAt)
        try container.encode(automaticUpdatesEnabled, forKey: .automaticUpdatesEnabled)
        try container.encodeIfPresent(updateIntervalHours, forKey: .updateIntervalHours)
        try container.encodeIfPresent(
            providerSuggestedUpdateIntervalHours,
            forKey: .providerSuggestedUpdateIntervalHours
        )
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(webPageURL, forKey: .webPageURL)
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
