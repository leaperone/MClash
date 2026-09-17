import Foundation
import Darwin

public enum XrayLogRetentionError: Error, Equatable, Sendable {
    case directoryUnavailable
    case unsafePath(String)
    case renameFailed(String)
    case restartFailed
    case restoreFailed
    case alreadyRotating
}

extension XrayLogRetentionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .directoryUnavailable: AppLocalization.string("The Xray log directory is unavailable.")
        case let .unsafePath(name): AppLocalization.format("The Xray log path is not a regular file: %@.", name)
        case let .renameFailed(name): AppLocalization.format("The Xray log could not be rotated: %@.", name)
        case .restartFailed: AppLocalization.string("The Xray logger restart did not complete; retry log rotation.")
        case .restoreFailed: AppLocalization.string("The previous Xray log could not be restored; retry log rotation.")
        case .alreadyRotating: AppLocalization.string("Xray log rotation is already in progress.")
        }
    }
}

/// Keeps the two Xray log files bounded without stopping the proxy process.
/// The active file is renamed before LoggerService is restarted, so an open
/// writer continues to refer to the previous inode while the new logger opens
/// the canonical path.
public actor XrayLogRetention {
    public static let targetBytes = 8 * 1_024 * 1_024

    private struct LogFile {
        let name: String
        var activeURL: URL { directory.appendingPathComponent(name) }
        var previousURL: URL { directory.appendingPathComponent(name + ".previous") }
        let directory: URL
    }

    private let directory: URL
    private let restartLogger: @Sendable () async throws -> Void
    private let fileManager: FileManager
    private let files: [LogFile]
    private var rotating = false

    public init(
        directory: URL,
        restartLogger: @escaping @Sendable () async throws -> Void,
        fileManager: FileManager = .default
    ) {
        self.directory = directory.standardizedFileURL
        self.restartLogger = restartLogger
        self.fileManager = fileManager
        self.files = [
            LogFile(name: "access.log", directory: directory.standardizedFileURL),
            LogFile(name: "error.log", directory: directory.standardizedFileURL),
        ]
    }

    /// Returns true when at least one log was rotated. All files are kept in
    /// the caller-owned runtime directory and at most one previous file per
    /// log is retained.
    public func rotateIfNeeded() async throws -> Bool {
        guard !rotating else { throw XrayLogRetentionError.alreadyRotating }
        rotating = true
        defer { rotating = false }
        guard isOwnedDirectory(directory) else { throw XrayLogRetentionError.directoryUnavailable }
        let candidates = try files.filter { file in
            guard isOwnedRegularFile(file.activeURL) else { return false }
            let attributes = try fileManager.attributesOfItem(atPath: file.activeURL.path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0 >= Int64(Self.targetBytes)
        }
        guard !candidates.isEmpty else { return false }

        var moved: [LogFile] = []
        do {
            for file in candidates {
                try preparePrevious(file.previousURL)
                do {
                    try fileManager.moveItem(at: file.activeURL, to: file.previousURL)
                } catch {
                    throw XrayLogRetentionError.renameFailed(file.name)
                }
                moved.append(file)
            }
            // A failed RPC is surfaced and the old files are restored below.
            // The process stays alive throughout this operation.
            do {
                try await restartLogger()
            } catch {
                throw XrayLogRetentionError.restartFailed
            }
            for file in moved {
                if !fileManager.fileExists(atPath: file.activeURL.path) {
                    guard Self.createExclusiveFile(at: file.activeURL) else {
                        throw XrayLogRetentionError.renameFailed(file.name)
                    }
                }
                guard isOwnedRegularFile(file.activeURL) else { throw XrayLogRetentionError.unsafePath(file.name) }
            }
            return true
        } catch {
            do {
                for file in moved.reversed() {
                    if fileManager.fileExists(atPath: file.activeURL.path) {
                        // A timed-out restart may have succeeded and opened a
                        // new writer. Preserve its canonical file and records.
                        continue
                    }
                    guard fileManager.fileExists(atPath: file.previousURL.path) else { throw XrayLogRetentionError.restoreFailed }
                    try fileManager.moveItem(at: file.previousURL, to: file.activeURL)
                }
            } catch {
                throw XrayLogRetentionError.restoreFailed
            }
            throw error
        }
    }

    private func preparePrevious(_ url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path) else {
            guard isOwnedRegularFile(url) else { throw XrayLogRetentionError.unsafePath(url.lastPathComponent) }
            try fileManager.removeItem(at: url)
            return
        }
        if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw XrayLogRetentionError.unsafePath(url.lastPathComponent)
        }
    }

    private func isOwnedDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func isOwnedRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func createExclusiveFile(at url: URL) -> Bool {
        let descriptor = url.path.withCString { path in
            open(path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            guard errno == EEXIST else { return false }
            var info = stat()
            return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
        }
        close(descriptor)
        return true
    }
}
