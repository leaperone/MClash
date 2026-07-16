import Foundation

public struct FileReplacementReceipt: Hashable, Sendable {
    public let transactionID: UUID
    public let destinationURL: URL
    public let backupURL: URL?
    public let replacedExistingFile: Bool

    fileprivate init(
        transactionID: UUID,
        destinationURL: URL,
        backupURL: URL?,
        replacedExistingFile: Bool
    ) {
        self.transactionID = transactionID
        self.destinationURL = destinationURL
        self.backupURL = backupURL
        self.replacedExistingFile = replacedExistingFile
    }
}

/// Serializes replace/commit/rollback operations and keeps backups alive until
/// the caller explicitly commits or rolls back the returned receipt.
public actor AtomicFileReplacer {
    private let fileManager = FileManager.default
    private var activeTransactions: [UUID: FileReplacementReceipt] = [:]

    public init() {}

    public func stage(
        data: Data,
        in directory: URL,
        preferredName: String = "config.yaml"
    ) throws -> URL {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let stagedURL = directory.appendingPathComponent(
            ".\(UUID().uuidString.lowercased())-\(preferredName)",
            isDirectory: false
        )
        try data.write(to: stagedURL, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedURL.path)
        return stagedURL
    }

    public func replace(
        destinationURL: URL,
        withStagedFile stagedURL: URL
    ) throws -> FileReplacementReceipt {
        let destination = destinationURL.standardizedFileURL
        let staged = stagedURL.standardizedFileURL
        let destinationDirectory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: staged.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AtomicFileReplacementError.stagedFileMissing
        }

        let replacedExistingFile = fileManager.fileExists(atPath: destination.path)
        let backupURL: URL?
        if replacedExistingFile {
            let candidate = destinationDirectory.appendingPathComponent(
                ".\(UUID().uuidString.lowercased())-\(destination.lastPathComponent).backup",
                isDirectory: false
            )
            try fileManager.copyItem(at: destination, to: candidate)
            backupURL = candidate
        } else {
            backupURL = nil
        }

        do {
            if replacedExistingFile {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: staged,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            if !fileManager.fileExists(atPath: destination.path), let backupURL {
                try? fileManager.copyItem(at: backupURL, to: destination)
            }
            if let backupURL {
                try? fileManager.removeItem(at: backupURL)
            }
            throw error
        }

        let receipt = FileReplacementReceipt(
            transactionID: UUID(),
            destinationURL: destination,
            backupURL: backupURL,
            replacedExistingFile: replacedExistingFile
        )
        activeTransactions[receipt.transactionID] = receipt
        return receipt
    }

    public func commit(_ receipt: FileReplacementReceipt) throws {
        guard activeTransactions[receipt.transactionID] == receipt else {
            throw AtomicFileReplacementError.unknownTransaction
        }
        if let backupURL = receipt.backupURL, fileManager.fileExists(atPath: backupURL.path) {
            // The replacement is already durable. A stale private backup is a
            // cleanup concern and must not turn a successful transaction into
            // an activation failure that callers can no longer roll back.
            try? fileManager.removeItem(at: backupURL)
        }
        activeTransactions.removeValue(forKey: receipt.transactionID)
    }

    public func rollback(_ receipt: FileReplacementReceipt) throws {
        guard activeTransactions[receipt.transactionID] == receipt else {
            throw AtomicFileReplacementError.unknownTransaction
        }

        if receipt.replacedExistingFile {
            guard let backupURL = receipt.backupURL, fileManager.fileExists(atPath: backupURL.path) else {
                throw AtomicFileReplacementError.backupMissing
            }
            let rollbackStage = receipt.destinationURL.deletingLastPathComponent().appendingPathComponent(
                ".\(UUID().uuidString.lowercased())-rollback",
                isDirectory: false
            )
            try fileManager.copyItem(at: backupURL, to: rollbackStage)
            do {
                if fileManager.fileExists(atPath: receipt.destinationURL.path) {
                    _ = try fileManager.replaceItemAt(
                        receipt.destinationURL,
                        withItemAt: rollbackStage,
                        backupItemName: nil,
                        options: []
                    )
                } else {
                    try fileManager.moveItem(at: rollbackStage, to: receipt.destinationURL)
                }
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: receipt.destinationURL.path
                )
            } catch {
                try? fileManager.removeItem(at: rollbackStage)
                throw error
            }
            try fileManager.removeItem(at: backupURL)
        } else if fileManager.fileExists(atPath: receipt.destinationURL.path) {
            try fileManager.removeItem(at: receipt.destinationURL)
        }

        activeTransactions.removeValue(forKey: receipt.transactionID)
    }
}

public enum AtomicFileReplacementError: Error, Equatable, Sendable {
    case stagedFileMissing
    case backupMissing
    case unknownTransaction
}

extension AtomicFileReplacementError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .stagedFileMissing:
            "The staged configuration file is missing."
        case .backupMissing:
            "The previous configuration backup is missing."
        case .unknownTransaction:
            "The configuration transaction is no longer active."
        }
    }
}
