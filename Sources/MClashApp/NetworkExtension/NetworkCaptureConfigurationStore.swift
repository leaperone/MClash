import Foundation
import MClashNetworkShared

struct NetworkCapturePreferences: Codable, Equatable, Sendable {
    let enabled: Bool
    let dnsEnabled: Bool
    let failOpen: Bool
    let snapshot: CaptureConfigurationSnapshot

    init(
        enabled: Bool,
        dnsEnabled: Bool = false,
        failOpen: Bool = true,
        snapshot: CaptureConfigurationSnapshot
    ) throws {
        try snapshot.validate()
        self.enabled = enabled
        self.dnsEnabled = dnsEnabled
        self.failOpen = failOpen
        self.snapshot = snapshot
    }

    static func disabled() -> NetworkCapturePreferences {
        // The empty, current-schema snapshot is structurally infallible. Keeping
        // the fallback here lets a missing settings document always fail open.
        let snapshot = try! CaptureConfigurationSnapshot(revision: 0, rules: [])
        return try! NetworkCapturePreferences(enabled: false, snapshot: snapshot)
    }
}

struct NetworkCaptureStorageLayout: Equatable, Sendable {
    let settingsDirectory: URL
    let stagingDirectory: URL
    let preferencesURL: URL

    init(applicationRoot: URL) {
        settingsDirectory = applicationRoot.standardizedFileURL
            .appendingPathComponent("Settings", isDirectory: true)
        stagingDirectory = settingsDirectory
            .appendingPathComponent("NetworkCaptureStaging", isDirectory: true)
        preferencesURL = settingsDirectory
            .appendingPathComponent("network-capture.json", isDirectory: false)
    }
}

enum NetworkCaptureConfigurationStoreError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case tooManyRules(actual: Int, maximum: Int)
    case documentTooLarge(actual: Int, maximum: Int)
    case revisionDidNotAdvance(previous: UInt64, proposed: UInt64)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Network capture settings use unsupported schema version \(version)."
        case let .tooManyRules(actual, maximum):
            "Network capture has \(actual) rules; the maximum is \(maximum)."
        case let .documentTooLarge(actual, maximum):
            "Network capture settings are \(actual) bytes; the maximum is \(maximum)."
        case let .revisionDidNotAdvance(previous, proposed):
            "Network capture revision must advance beyond \(previous), but \(proposed) was supplied."
        }
    }
}

/// Durable, versioned source of truth for host-to-provider capture rules.
///
/// The actor serializes revisions and writes a private document through the
/// same staged atomic replacement path used by runtime configuration. A bad or
/// missing document never silently enables interception.
actor NetworkCaptureConfigurationStore {
    static let currentSchemaVersion = 1
    static let maximumRuleCount = 10_000
    static let maximumDocumentSize = 8 * 1_024 * 1_024

    let layout: NetworkCaptureStorageLayout

    private let fileManager: FileManager
    private let replacer: AtomicFileReplacer
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(
        applicationRoot: URL,
        fileManager: FileManager = .default,
        replacer: AtomicFileReplacer = AtomicFileReplacer()
    ) throws {
        layout = NetworkCaptureStorageLayout(applicationRoot: applicationRoot)
        self.fileManager = fileManager
        self.replacer = replacer

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        try Self.createPrivateDirectory(layout.settingsDirectory, fileManager: fileManager)
        try Self.createPrivateDirectory(layout.stagingDirectory, fileManager: fileManager)
    }

    init(
        profileLayout: ProfileDirectoryLayout,
        fileManager: FileManager = .default,
        replacer: AtomicFileReplacer = AtomicFileReplacer()
    ) throws {
        try self.init(
            applicationRoot: profileLayout.rootDirectory,
            fileManager: fileManager,
            replacer: replacer
        )
    }

    func load() throws -> NetworkCapturePreferences {
        guard fileManager.fileExists(atPath: layout.preferencesURL.path) else {
            return .disabled()
        }
        let data = try Data(
            contentsOf: layout.preferencesURL,
            options: [.mappedIfSafe, .uncached]
        )
        guard data.count <= Self.maximumDocumentSize else {
            throw NetworkCaptureConfigurationStoreError.documentTooLarge(
                actual: data.count,
                maximum: Self.maximumDocumentSize
            )
        }
        let probe = try decoder.decode(SchemaVersionProbe.self, from: data)
        guard probe.schemaVersion == Self.currentSchemaVersion else {
            throw NetworkCaptureConfigurationStoreError.unsupportedSchemaVersion(
                probe.schemaVersion
            )
        }
        let preferences = try decoder.decode(Document.self, from: data).preferences
        try validate(preferences)
        return preferences
    }

    func save(_ preferences: NetworkCapturePreferences) async throws {
        try validate(preferences)

        if fileManager.fileExists(atPath: layout.preferencesURL.path) {
            let previous = try load()
            guard preferences.snapshot.revision > previous.snapshot.revision else {
                throw NetworkCaptureConfigurationStoreError.revisionDidNotAdvance(
                    previous: previous.snapshot.revision,
                    proposed: preferences.snapshot.revision
                )
            }
        }

        let data = try encoder.encode(
            Document(
                schemaVersion: Self.currentSchemaVersion,
                preferences: preferences
            )
        )
        guard data.count <= Self.maximumDocumentSize else {
            throw NetworkCaptureConfigurationStoreError.documentTooLarge(
                actual: data.count,
                maximum: Self.maximumDocumentSize
            )
        }

        let stagedURL = try await replacer.stage(
            data: data,
            in: layout.stagingDirectory,
            preferredName: layout.preferencesURL.lastPathComponent
        )
        let receipt: FileReplacementReceipt
        do {
            receipt = try await replacer.replace(
                destinationURL: layout.preferencesURL,
                withStagedFile: stagedURL
            )
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }
        do {
            try await replacer.commit(receipt)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: layout.preferencesURL.path
            )
        } catch {
            try? await replacer.rollback(receipt)
            throw error
        }
    }

    @discardableResult
    func replaceRules(
        _ rules: [CaptureRule],
        enabled: Bool,
        dnsEnabled: Bool,
        failOpen: Bool = true
    ) async throws -> NetworkCapturePreferences {
        let current = try load()
        let revision = try nextRevision(after: current.snapshot.revision)
        let snapshot = try CaptureConfigurationSnapshot(revision: revision, rules: rules)
        let preferences = try NetworkCapturePreferences(
            enabled: enabled,
            dnsEnabled: dnsEnabled,
            failOpen: failOpen,
            snapshot: snapshot
        )
        try await save(preferences)
        return preferences
    }

    private func validate(_ preferences: NetworkCapturePreferences) throws {
        try preferences.snapshot.validate()
        guard preferences.snapshot.rules.count <= Self.maximumRuleCount else {
            throw NetworkCaptureConfigurationStoreError.tooManyRules(
                actual: preferences.snapshot.rules.count,
                maximum: Self.maximumRuleCount
            )
        }
    }

    private func nextRevision(after revision: UInt64) throws -> UInt64 {
        guard revision < UInt64.max else {
            throw NetworkCaptureConfigurationStoreError.revisionDidNotAdvance(
                previous: revision,
                proposed: revision
            )
        }
        return revision + 1
    }

    private static func createPrivateDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

private struct SchemaVersionProbe: Decodable {
    let schemaVersion: Int
}

private struct Document: Codable {
    let schemaVersion: Int
    let preferences: NetworkCapturePreferences
}
