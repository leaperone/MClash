import Foundation

/// The durable, strategy-owned configuration document. Profile YAML is not
/// embedded here: sources and their raw snapshots are inputs, while this
/// document is the only user-editable configuration truth.
public struct ConfigurationDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sources: [Source]
    public var nodes: [Node]
    public var proxyGroups: [ProxyGroup]
    public var rules: [RoutingRule]
    public var ruleSets: [RuleSet]
    public var dnsPolicies: [DNSPolicy]
    public var entrances: [Entrance]
    public var workspaces: [Workspace]
    public var currentWorkspaceID: WorkspaceID?
    public var lastRuntimeSnapshot: RuntimeSnapshot?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sources: [Source] = [],
        nodes: [Node] = [],
        proxyGroups: [ProxyGroup] = [],
        rules: [RoutingRule] = [],
        ruleSets: [RuleSet] = [],
        dnsPolicies: [DNSPolicy] = [],
        entrances: [Entrance] = [],
        workspaces: [Workspace] = [],
        currentWorkspaceID: WorkspaceID? = nil,
        lastRuntimeSnapshot: RuntimeSnapshot? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sources = sources
        self.nodes = nodes
        self.proxyGroups = proxyGroups
        self.rules = rules
        self.ruleSets = ruleSets
        self.dnsPolicies = dnsPolicies
        self.entrances = entrances
        self.workspaces = workspaces
        self.currentWorkspaceID = currentWorkspaceID
        self.lastRuntimeSnapshot = lastRuntimeSnapshot
    }

    public static var empty: Self { Self() }

    public var currentWorkspace: Workspace? {
        guard let currentWorkspaceID else { return workspaces.first }
        return workspaces.first(where: { $0.id == currentWorkspaceID })
    }

    public func diagnostics(for workspace: Workspace? = nil) -> [ConfigurationDiagnostic] {
        guard let workspace = workspace ?? currentWorkspace else { return [] }
        return ConfigurationValidator.validate(
            workspace: workspace,
            nodes: nodes,
            groups: proxyGroups,
            rules: rules,
            ruleSets: ruleSets,
            dnsPolicies: dnsPolicies,
            entrances: entrances
        )
    }
}

public struct ConfigurationStoreRecovery: Equatable, Sendable {
    public let document: ConfigurationDocument
    public let quarantinedURL: URL?
    public let reason: String?

    public init(document: ConfigurationDocument, quarantinedURL: URL? = nil, reason: String? = nil) {
        self.document = document
        self.quarantinedURL = quarantinedURL
        self.reason = reason
    }
}

/// Serializes the authoritative configuration document with private file
/// permissions and recoverable quarantine for malformed state.
public actor ConfigurationStore {
    public let layout: ProfileDirectoryLayout

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(layout: ProfileDirectoryLayout, fileManager: FileManager = .default) throws {
        self.layout = layout
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        try layout.createDirectories(fileManager: fileManager)
        try Self.setPrivatePermissions(at: layout.configurationDirectory, fileManager: fileManager)
    }

    public func load() throws -> ConfigurationDocument {
        guard fileManager.fileExists(atPath: layout.configurationManifestURL.path) else {
            return .empty
        }
        let data = try Data(contentsOf: layout.configurationManifestURL, options: .mappedIfSafe)
        let document = try decoder.decode(ConfigurationDocument.self, from: data)
        guard document.schemaVersion == ConfigurationDocument.currentSchemaVersion else {
            throw ConfigurationStoreError.unsupportedSchemaVersion(document.schemaVersion)
        }
        return document
    }

    public func loadRecoveringInvalidDocument() throws -> ConfigurationStoreRecovery {
        guard fileManager.fileExists(atPath: layout.configurationManifestURL.path) else {
            return ConfigurationStoreRecovery(document: .empty)
        }
        let data = try Data(contentsOf: layout.configurationManifestURL, options: .mappedIfSafe)
        do {
            let document = try decoder.decode(ConfigurationDocument.self, from: data)
            guard document.schemaVersion == ConfigurationDocument.currentSchemaVersion else {
                throw ConfigurationStoreError.unsupportedSchemaVersion(document.schemaVersion)
            }
            return ConfigurationStoreRecovery(document: document)
        } catch let error as ConfigurationStoreError {
            throw error
        } catch {
            let quarantine = layout.configurationDirectory.appendingPathComponent(
                "manifest.invalid-\(UUID().uuidString.lowercased()).json"
            )
            try fileManager.moveItem(at: layout.configurationManifestURL, to: quarantine)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: quarantine.path)
            return ConfigurationStoreRecovery(
                document: .empty,
                quarantinedURL: quarantine,
                reason: error.localizedDescription
            )
        }
    }

    public func save(_ document: ConfigurationDocument) throws {
        guard document.schemaVersion == ConfigurationDocument.currentSchemaVersion else {
            throw ConfigurationStoreError.unsupportedSchemaVersion(document.schemaVersion)
        }
        let data = try encoder.encode(document)
        try data.write(to: layout.configurationManifestURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: layout.configurationManifestURL.path)
    }

    public func update(_ mutation: (inout ConfigurationDocument) throws -> Void) throws -> ConfigurationDocument {
        var document = try load()
        try mutation(&document)
        try save(document)
        return document
    }

    private static func setPrivatePermissions(at url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

public enum ConfigurationStoreError: Error, Equatable, Sendable {
    case unavailable
    case unsupportedSchemaVersion(Int)
}

extension ConfigurationStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            AppLocalization.string("MClash configuration storage is unavailable.")
        case let .unsupportedSchemaVersion(version):
            AppLocalization.format(
                "MClash configuration uses unsupported schema version %d.",
                version
            )
        }
    }
}
