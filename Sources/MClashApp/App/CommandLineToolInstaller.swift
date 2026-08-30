import Darwin
import Foundation

struct CommandLineToolInstaller {
    enum Status: Equatable {
        case notInstalled
        case installed
        case conflict
        case unsafeParent
        case unavailable
    }

    private enum ItemKind: Equatable {
        case missing
        case regularFile
        case directory
        case symbolicLink
        case other
    }

    private let fileManager: FileManager
    private let helperURL: URL
    private let linkURL: URL

    init(bundle: Bundle = .main, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        helperURL = bundle.bundleURL
            .appendingPathComponent("Contents/Helpers/mclashctl", isDirectory: false)
            .standardizedFileURL
        linkURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/mclashctl", isDirectory: false)
            .standardizedFileURL
    }

    var status: Status {
        guard parentDirectoriesAreSafe else {
            return .unsafeParent
        }
        if isManagedLink {
            return .installed
        }
        if itemExistsAtLinkURL {
            return .conflict
        }
        return helperIsAvailable
            ? .notInstalled
            : .unavailable
    }

    func install() throws {
        guard parentDirectoriesAreSafe else {
            throw CommandLineToolInstallationError.unsafeParentDirectory
        }
        if isManagedLink {
            return
        }
        guard helperIsAvailable else {
            throw CommandLineToolInstallationError.helperUnavailable
        }
        guard !itemExistsAtLinkURL else {
            throw CommandLineToolInstallationError.destinationOccupied
        }

        try createDirectoryIfMissing(localDirectoryURL)
        try createDirectoryIfMissing(binDirectoryURL)
        guard parentDirectoriesAreSafe else {
            throw CommandLineToolInstallationError.unsafeParentDirectory
        }
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: helperURL)
    }

    func remove() throws {
        guard parentDirectoriesAreSafe else {
            throw CommandLineToolInstallationError.unsafeParentDirectory
        }
        if isManagedLink {
            try fileManager.removeItem(at: linkURL)
            return
        }
        guard !itemExistsAtLinkURL else {
            throw CommandLineToolInstallationError.destinationNotManaged
        }
    }

    private var localDirectoryURL: URL {
        linkURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    private var binDirectoryURL: URL {
        linkURL.deletingLastPathComponent()
    }

    private var helperIsAvailable: Bool {
        itemKind(at: helperURL) == .regularFile
            && access(helperURL.path, X_OK) == 0
    }

    private var parentDirectoriesAreSafe: Bool {
        [localDirectoryURL, binDirectoryURL].allSatisfy {
            let kind = itemKind(at: $0)
            return kind == .missing || kind == .directory
        }
    }

    private var isManagedLink: Bool {
        guard let destination = try? fileManager.destinationOfSymbolicLink(
            atPath: linkURL.path
        ) else {
            return false
        }
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = linkURL.deletingLastPathComponent()
                .appendingPathComponent(destination)
        }
        return destinationURL.standardizedFileURL == helperURL
    }

    private var itemExistsAtLinkURL: Bool {
        itemKind(at: linkURL) != .missing
    }

    private func createDirectoryIfMissing(_ url: URL) throws {
        switch itemKind(at: url) {
        case .missing:
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        case .directory:
            return
        case .regularFile, .symbolicLink, .other:
            throw CommandLineToolInstallationError.unsafeParentDirectory
        }
    }

    private func itemKind(at url: URL) -> ItemKind {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            return errno == ENOENT ? .missing : .other
        }
        return switch metadata.st_mode & S_IFMT {
        case S_IFREG: .regularFile
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        default: .other
        }
    }
}

private enum CommandLineToolInstallationError: LocalizedError {
    case helperUnavailable
    case destinationOccupied
    case destinationNotManaged
    case unsafeParentDirectory

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            AppLocalization.string(
                "The bundled mclashctl helper is missing or not executable."
            )
        case .destinationOccupied:
            AppLocalization.string(
                "~/.local/bin/mclashctl already exists. MClash will not replace it."
            )
        case .destinationNotManaged:
            AppLocalization.string(
                "MClash only removes a command-line link that points to this copy of the app."
            )
        case .unsafeParentDirectory:
            AppLocalization.string(
                "MClash will not install through a file or symbolic link at ~/.local or ~/.local/bin."
            )
        }
    }
}
