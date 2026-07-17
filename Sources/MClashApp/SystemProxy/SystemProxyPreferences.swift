import Foundation

public struct SystemProxyPreferences: Codable, Equatable, Sendable {
    public var customBypassDomains: [String]
    public var bypassPrivateNetworks: Bool
    public var guardEnabled: Bool
    public var guardIntervalSeconds: Int

    public init(
        customBypassDomains: [String] = [],
        bypassPrivateNetworks: Bool = true,
        guardEnabled: Bool = true,
        guardIntervalSeconds: Int = 10
    ) {
        self.customBypassDomains = customBypassDomains
        self.bypassPrivateNetworks = bypassPrivateNetworks
        self.guardEnabled = guardEnabled
        self.guardIntervalSeconds = guardIntervalSeconds
    }

    public static let defaults = SystemProxyPreferences()

    public var effectiveBypassDomains: [String] {
        var values = ["localhost", "127.0.0.1", "::1", "*.local"]
        if bypassPrivateNetworks {
            values += ["10.*", "172.16.*", "172.17.*", "172.18.*", "172.19.*",
                       "172.20.*", "172.21.*", "172.22.*", "172.23.*", "172.24.*",
                       "172.25.*", "172.26.*", "172.27.*", "172.28.*", "172.29.*",
                       "172.30.*", "172.31.*", "192.168.*", "169.254.*"]
        }
        values += customBypassDomains
        var seen: Set<String> = []
        return values.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }
    }

    public func validated() throws -> SystemProxyPreferences {
        guard (2...300).contains(guardIntervalSeconds) else {
            throw SystemProxyPreferencesError.invalidGuardInterval(guardIntervalSeconds)
        }
        for domain in customBypassDomains {
            let normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  normalized.count <= 255,
                  !normalized.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else {
                throw SystemProxyPreferencesError.invalidBypassDomain(domain)
            }
        }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case customBypassDomains
        case bypassPrivateNetworks
        case guardEnabled
        case guardIntervalSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customBypassDomains = try container.decodeIfPresent(
            [String].self,
            forKey: .customBypassDomains
        ) ?? []
        bypassPrivateNetworks = try container.decodeIfPresent(
            Bool.self,
            forKey: .bypassPrivateNetworks
        ) ?? true
        guardEnabled = try container.decodeIfPresent(Bool.self, forKey: .guardEnabled) ?? true
        guardIntervalSeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .guardIntervalSeconds
        ) ?? 10
    }
}

public enum SystemProxyPreferencesError: Error, Equatable, LocalizedError, Sendable {
    case invalidBypassDomain(String)
    case invalidGuardInterval(Int)
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidBypassDomain(domain):
            "Invalid system proxy bypass entry: \(domain)"
        case let .invalidGuardInterval(seconds):
            "System proxy guard interval must be between 2 and 300 seconds; received \(seconds)."
        case let .unsupportedSchemaVersion(version):
            "System proxy settings use unsupported schema version \(version)."
        }
    }
}

public actor SystemProxyPreferencesStore {
    public static let currentSchemaVersion = 1

    private struct Document: Codable {
        let schemaVersion: Int
        let preferences: SystemProxyPreferences
    }

    private struct VersionProbe: Decodable {
        let schemaVersion: Int?
    }

    public let settingsURL: URL
    private let stagingDirectory: URL
    private let fileManager: FileManager
    private let replacer: AtomicFileReplacer

    public init(
        profileLayout: ProfileDirectoryLayout,
        fileManager: FileManager = .default,
        replacer: AtomicFileReplacer = AtomicFileReplacer()
    ) throws {
        let directory = profileLayout.rootDirectory
            .appendingPathComponent("Settings", isDirectory: true)
        settingsURL = directory.appendingPathComponent("system-proxy.json")
        stagingDirectory = directory.appendingPathComponent("Staging", isDirectory: true)
        self.fileManager = fileManager
        self.replacer = replacer
        try Self.createPrivateDirectory(directory, fileManager: fileManager)
        try Self.createPrivateDirectory(stagingDirectory, fileManager: fileManager)
    }

    public func load() throws -> SystemProxyPreferences {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return .defaults }
        let data = try Data(contentsOf: settingsURL, options: .mappedIfSafe)
        let decoder = JSONDecoder()
        let version = try decoder.decode(VersionProbe.self, from: data).schemaVersion ?? 0
        let preferences: SystemProxyPreferences
        switch version {
        case 0:
            preferences = try decoder.decode(SystemProxyPreferences.self, from: data)
        case Self.currentSchemaVersion:
            preferences = try decoder.decode(Document.self, from: data).preferences
        default:
            throw SystemProxyPreferencesError.unsupportedSchemaVersion(version)
        }
        return try preferences.validated()
    }

    public func save(_ preferences: SystemProxyPreferences) async throws {
        let preferences = try preferences.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(
            Document(schemaVersion: Self.currentSchemaVersion, preferences: preferences)
        )
        let stagedURL = try await replacer.stage(
            data: data,
            in: stagingDirectory,
            preferredName: settingsURL.lastPathComponent
        )
        let receipt = try await replacer.replace(
            destinationURL: settingsURL,
            withStagedFile: stagedURL
        )
        try await replacer.commit(receipt)
    }

    private static func createPrivateDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
