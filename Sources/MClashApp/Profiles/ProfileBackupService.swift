import Foundation

public struct MClashBackupManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let createdAt: Date
    public let hasSettings: Bool
    public let hasActiveProfileState: Bool

    public init(
        createdAt: Date = Date(),
        hasSettings: Bool,
        hasActiveProfileState: Bool
    ) {
        formatVersion = Self.currentFormatVersion
        self.createdAt = createdAt
        self.hasSettings = hasSettings
        self.hasActiveProfileState = hasActiveProfileState
    }
}

public actor ProfileBackupService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func exportBackup(
        from layout: ProfileDirectoryLayout,
        to destinationURL: URL,
        at date: Date = Date()
    ) throws {
        let destination = destinationURL.standardizedFileURL
        let sourceRoot = layout.rootDirectory.standardizedFileURL
        guard !isDescendant(destination, of: sourceRoot) else {
            throw ProfileBackupError.destinationInsideApplicationData
        }

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".\(UUID().uuidString.lowercased())-MClash-backup",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }
        try createPrivateDirectory(staging)

        try fileManager.copyItem(
            at: layout.profilesDirectory,
            to: staging.appendingPathComponent("Profiles", isDirectory: true)
        )
        let settings = sourceRoot.appendingPathComponent("Settings", isDirectory: true)
        let hasSettings = fileManager.fileExists(atPath: settings.path)
        if hasSettings {
            try fileManager.copyItem(
                at: settings,
                to: staging.appendingPathComponent("Settings", isDirectory: true)
            )
        }
        let activeState = layout.activeProfileStateURL
        let hasActiveState = fileManager.fileExists(atPath: activeState.path)
        if hasActiveState {
            let stateDirectory = staging.appendingPathComponent("State", isDirectory: true)
            try createPrivateDirectory(stateDirectory)
            try fileManager.copyItem(
                at: activeState,
                to: stateDirectory.appendingPathComponent("active-profile.json")
            )
        }

        let manifest = MClashBackupManifest(
            createdAt: date,
            hasSettings: hasSettings,
            hasActiveProfileState: hasActiveState
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: staging.appendingPathComponent("manifest.json"),
            options: [.atomic]
        )

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: staging, to: destination)
    }

    @discardableResult
    public func restoreBackup(
        from backupURL: URL,
        to layout: ProfileDirectoryLayout
    ) throws -> MClashBackupManifest {
        let backup = backupURL.standardizedFileURL
        try validateBackupTree(backup)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            MClashBackupManifest.self,
            from: Data(contentsOf: backup.appendingPathComponent("manifest.json"))
        )
        guard manifest.formatVersion == MClashBackupManifest.currentFormatVersion else {
            throw ProfileBackupError.unsupportedFormat(manifest.formatVersion)
        }
        let backupProfiles = backup.appendingPathComponent("Profiles", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: backupProfiles.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProfileBackupError.missingProfiles
        }

        let transactionRoot = layout.rootDirectory
            .appendingPathComponent("BackupRestoreStaging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let incoming = transactionRoot.appendingPathComponent("Incoming", isDirectory: true)
        let previous = transactionRoot.appendingPathComponent("Previous", isDirectory: true)
        try createPrivateDirectory(incoming)
        try createPrivateDirectory(previous)
        defer { try? fileManager.removeItem(at: transactionRoot) }

        try fileManager.copyItem(
            at: backupProfiles,
            to: incoming.appendingPathComponent("Profiles", isDirectory: true)
        )
        if manifest.hasSettings {
            let backupSettings = backup.appendingPathComponent("Settings", isDirectory: true)
            guard fileManager.fileExists(atPath: backupSettings.path) else {
                throw ProfileBackupError.incompleteBackup("Settings")
            }
            try fileManager.copyItem(
                at: backupSettings,
                to: incoming.appendingPathComponent("Settings", isDirectory: true)
            )
        }
        if manifest.hasActiveProfileState {
            let backupActive = backup
                .appendingPathComponent("State", isDirectory: true)
                .appendingPathComponent("active-profile.json")
            guard fileManager.fileExists(atPath: backupActive.path) else {
                throw ProfileBackupError.incompleteBackup("State/active-profile.json")
            }
            let incomingState = incoming.appendingPathComponent("State", isDirectory: true)
            try createPrivateDirectory(incomingState)
            try fileManager.copyItem(
                at: backupActive,
                to: incomingState.appendingPathComponent("active-profile.json")
            )
        }

        let targets = restoreTargets(
            layout: layout,
            incoming: incoming,
            previous: previous,
            manifest: manifest
        )
        var completed: [RestoreTarget] = []
        do {
            for target in targets {
                try fileManager.createDirectory(
                    at: target.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: target.destination.path) {
                    try fileManager.moveItem(at: target.destination, to: target.previous)
                }
                completed.append(target)
                if let staged = target.incoming {
                    try fileManager.moveItem(at: staged, to: target.destination)
                }
            }
        } catch {
            for target in completed.reversed() {
                try? fileManager.removeItem(at: target.destination)
                if fileManager.fileExists(atPath: target.previous.path) {
                    try? fileManager.moveItem(at: target.previous, to: target.destination)
                }
            }
            throw error
        }
        return manifest
    }

    private struct RestoreTarget {
        let incoming: URL?
        let destination: URL
        let previous: URL
    }

    private func restoreTargets(
        layout: ProfileDirectoryLayout,
        incoming: URL,
        previous: URL,
        manifest: MClashBackupManifest
    ) -> [RestoreTarget] {
        let root = layout.rootDirectory
        return [
            RestoreTarget(
                incoming: incoming.appendingPathComponent("Profiles", isDirectory: true),
                destination: layout.profilesDirectory,
                previous: previous.appendingPathComponent("Profiles", isDirectory: true)
            ),
            RestoreTarget(
                incoming: manifest.hasSettings
                    ? incoming.appendingPathComponent("Settings", isDirectory: true)
                    : nil,
                destination: root.appendingPathComponent("Settings", isDirectory: true),
                previous: previous.appendingPathComponent("Settings", isDirectory: true)
            ),
            RestoreTarget(
                incoming: manifest.hasActiveProfileState
                    ? incoming.appendingPathComponent("State/active-profile.json")
                    : nil,
                destination: layout.activeProfileStateURL,
                previous: previous.appendingPathComponent("active-profile.json")
            ),
        ]
    }

    private func validateBackupTree(_ root: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProfileBackupError.notABackupPackage
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ProfileBackupError.notABackupPackage
        }
        var totalBytes = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            if values.isSymbolicLink == true {
                throw ProfileBackupError.symbolicLinksUnsupported
            }
            if values.isRegularFile == true {
                totalBytes += values.fileSize ?? 0
                if totalBytes > 512 * 1_024 * 1_024 {
                    throw ProfileBackupError.backupTooLarge
                }
            }
        }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let root = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return candidate.path == directory.path || candidate.path.hasPrefix(root)
    }
}

public enum ProfileBackupError: Error, Equatable, LocalizedError, Sendable {
    case destinationInsideApplicationData
    case notABackupPackage
    case unsupportedFormat(Int)
    case missingProfiles
    case incompleteBackup(String)
    case symbolicLinksUnsupported
    case backupTooLarge

    public var errorDescription: String? {
        switch self {
        case .destinationInsideApplicationData:
            "Choose a backup destination outside MClash application data."
        case .notABackupPackage:
            "The selected item is not an MClash backup package."
        case let .unsupportedFormat(version):
            "Unsupported MClash backup format \(version)."
        case .missingProfiles:
            "The backup does not contain a Profiles directory."
        case let .incompleteBackup(component):
            "The backup is missing \(component)."
        case .symbolicLinksUnsupported:
            "Backup packages containing symbolic links are not supported."
        case .backupTooLarge:
            "The backup is larger than the 512 MB safety limit."
        }
    }
}
