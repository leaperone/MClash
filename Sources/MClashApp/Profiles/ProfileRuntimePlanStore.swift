import Foundation

public struct ProfileRuntimePlanRecovery: Equatable, Sendable {
    public let plan: ProfileRuntimePlan
    public let quarantinedURL: URL?
    public let recoveryReason: String?
}

/// Owns the private, atomically replaced profile fleet desired-state document.
public actor ProfileRuntimePlanStore {
    public let layout: ProfileDirectoryLayout

    private let fileManager: FileManager
    private let replacer: AtomicFileReplacer
    private let validator: ProfileRuntimePlanValidator
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        layout: ProfileDirectoryLayout,
        fileManager: FileManager = .default,
        replacer: AtomicFileReplacer = AtomicFileReplacer(),
        validator: ProfileRuntimePlanValidator = ProfileRuntimePlanValidator()
    ) throws {
        self.layout = layout
        self.fileManager = fileManager
        self.replacer = replacer
        self.validator = validator

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        decoder = JSONDecoder()

        try Self.createPrivateDirectory(
            layout.rootDirectory,
            fileManager: fileManager
        )
        try Self.createPrivateDirectory(
            layout.stateDirectory,
            fileManager: fileManager
        )
        try Self.createPrivateDirectory(
            layout.profileRuntimePlanStagingDirectory,
            fileManager: fileManager
        )
    }

    public func load() throws -> ProfileRuntimePlan {
        guard fileManager.fileExists(atPath: layout.profileRuntimePlanURL.path) else {
            return .empty
        }

        let data = try Data(
            contentsOf: layout.profileRuntimePlanURL,
            options: .mappedIfSafe
        )
        let plan = try decoder.decode(ProfileRuntimePlan.self, from: data)
        try validator.validate(plan)
        return plan
    }

    public func loadRecoveringInvalidDocument() throws
        -> ProfileRuntimePlanRecovery
    {
        guard fileManager.fileExists(atPath: layout.profileRuntimePlanURL.path) else {
            return ProfileRuntimePlanRecovery(
                plan: .empty,
                quarantinedURL: nil,
                recoveryReason: nil
            )
        }

        // Filesystem read failures are not document corruption and must remain
        // visible. Only a document that was read successfully but cannot be
        // decoded or validated is quarantined.
        let data = try Data(
            contentsOf: layout.profileRuntimePlanURL,
            options: .mappedIfSafe
        )
        do {
            let plan = try decoder.decode(ProfileRuntimePlan.self, from: data)
            try validator.validate(plan)
            return ProfileRuntimePlanRecovery(
                plan: plan,
                quarantinedURL: nil,
                recoveryReason: nil
            )
        } catch {
            let quarantinedURL = layout.stateDirectory.appendingPathComponent(
                "profile-runtime-plan.invalid-\(UUID().uuidString.lowercased()).json"
            )
            try fileManager.moveItem(
                at: layout.profileRuntimePlanURL,
                to: quarantinedURL
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: quarantinedURL.path
            )
            return ProfileRuntimePlanRecovery(
                plan: .empty,
                quarantinedURL: quarantinedURL,
                recoveryReason: error.localizedDescription
            )
        }
    }

    public func save(_ plan: ProfileRuntimePlan) async throws {
        try validator.validate(plan)
        let data = try encoder.encode(plan)
        let stagedURL = try await replacer.stage(
            data: data,
            in: layout.profileRuntimePlanStagingDirectory,
            preferredName: layout.profileRuntimePlanURL.lastPathComponent
        )

        let receipt: FileReplacementReceipt
        do {
            receipt = try await replacer.replace(
                destinationURL: layout.profileRuntimePlanURL,
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
        _ mutation: @Sendable (inout ProfileRuntimePlan) throws -> Void
    ) async throws -> ProfileRuntimePlan {
        var plan = try load()
        try mutation(&plan)
        try await save(plan)
        return plan
    }

    public func reset() async throws {
        try await save(.empty)
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
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }
}
