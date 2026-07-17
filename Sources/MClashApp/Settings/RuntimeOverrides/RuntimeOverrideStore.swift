import Foundation

public struct RuntimeOverrideStorageLayout: Equatable, Sendable {
    public let settingsDirectory: URL

    public init(applicationRoot: URL) {
        settingsDirectory = applicationRoot.standardizedFileURL
            .appendingPathComponent("Settings", isDirectory: true)
    }

    public var overridesURL: URL {
        settingsDirectory.appendingPathComponent("runtime-overrides.json", isDirectory: false)
    }

    public var stagingDirectory: URL {
        settingsDirectory.appendingPathComponent("Staging", isDirectory: true)
    }
}

/// Owns the durable runtime override document. Writes are serialized, staged
/// with mode 0600, and atomically renamed into place.
public actor RuntimeOverrideStore {
    public static let currentSchemaVersion = 1

    public let layout: RuntimeOverrideStorageLayout

    private let fileManager: FileManager
    private let replacer: AtomicFileReplacer
    private let validator: RuntimeOverrideValidator
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        applicationRoot: URL,
        fileManager: FileManager = .default,
        replacer: AtomicFileReplacer = AtomicFileReplacer(),
        validator: RuntimeOverrideValidator = RuntimeOverrideValidator()
    ) throws {
        layout = RuntimeOverrideStorageLayout(applicationRoot: applicationRoot)
        self.fileManager = fileManager
        self.replacer = replacer
        self.validator = validator

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        decoder = JSONDecoder()

        try Self.createPrivateDirectory(layout.settingsDirectory, fileManager: fileManager)
        try Self.createPrivateDirectory(layout.stagingDirectory, fileManager: fileManager)
    }

    public init(
        profileLayout: ProfileDirectoryLayout,
        fileManager: FileManager = .default,
        replacer: AtomicFileReplacer = AtomicFileReplacer(),
        validator: RuntimeOverrideValidator = RuntimeOverrideValidator()
    ) throws {
        try self.init(
            applicationRoot: profileLayout.rootDirectory,
            fileManager: fileManager,
            replacer: replacer,
            validator: validator
        )
    }

    public func load() throws -> RuntimeOverrides {
        guard fileManager.fileExists(atPath: layout.overridesURL.path) else {
            return .empty
        }

        let data = try Data(contentsOf: layout.overridesURL, options: .mappedIfSafe)
        let version = try decoder.decode(SchemaVersionProbe.self, from: data).schemaVersion ?? 0
        let overrides: RuntimeOverrides
        switch version {
        case 0:
            overrides = try decodeLegacyDocument(from: data)
        case Self.currentSchemaVersion:
            overrides = try decoder.decode(CurrentDocument.self, from: data).overrides
        default:
            throw RuntimeOverrideStoreError.unsupportedSchemaVersion(version)
        }
        try validator.validate(overrides)
        return overrides
    }

    public func save(_ overrides: RuntimeOverrides) async throws {
        try validator.validate(overrides)
        let data = try encoder.encode(
            CurrentDocument(
                schemaVersion: Self.currentSchemaVersion,
                overrides: overrides
            )
        )
        let stagedURL = try await replacer.stage(
            data: data,
            in: layout.stagingDirectory,
            preferredName: layout.overridesURL.lastPathComponent
        )
        let receipt: FileReplacementReceipt
        do {
            receipt = try await replacer.replace(
                destinationURL: layout.overridesURL,
                withStagedFile: stagedURL
            )
        } catch {
            try? fileManager.removeItem(at: stagedURL)
            throw error
        }
        do {
            try await replacer.commit(receipt)
        } catch {
            try? await replacer.rollback(receipt)
            throw error
        }
    }

    @discardableResult
    public func update(
        _ mutation: @Sendable (inout RuntimeOverrides) throws -> Void
    ) async throws -> RuntimeOverrides {
        var overrides = try load()
        try mutation(&overrides)
        try await save(overrides)
        return overrides
    }

    public func reset() async throws {
        try await save(.empty)
    }

    private func decodeLegacyDocument(from data: Data) throws -> RuntimeOverrides {
        if let wrapped = try? decoder.decode(LegacyWrappedDocument.self, from: data) {
            return wrapped.overrides
        }
        return try decoder.decode(RuntimeOverrides.self, from: data)
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

public enum RuntimeOverrideStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

extension RuntimeOverrideStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "Runtime overrides use unsupported schema version \(version)."
        }
    }
}

private struct SchemaVersionProbe: Decodable {
    let schemaVersion: Int?
}

private struct CurrentDocument: Codable {
    let schemaVersion: Int
    let overrides: RuntimeOverrides
}

/// Schema 0 accepted an optional wrapper but did not require a version field.
private struct LegacyWrappedDocument: Decodable {
    let overrides: RuntimeOverrides
}
