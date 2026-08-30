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

    private enum LinkState: Equatable {
        case missing
        case managed
        case occupied
    }

    private static let localDirectoryName = ".local"
    private static let binDirectoryName = "bin"
    private static let linkName = "mclashctl"
    private static let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    private let helperPath: String
    private let homePath: String

    init(bundle: Bundle = .main, fileManager: FileManager = .default) {
        helperPath = bundle.bundleURL
            .appendingPathComponent("Contents/Helpers/mclashctl", isDirectory: false)
            .standardizedFileURL
            .path
        homePath = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
    }

    var status: Status {
        guard let homeDescriptor = try? openHomeDirectory() else {
            return .unsafeParent
        }
        defer { close(homeDescriptor) }

        do {
            guard let localDescriptor = try openDirectory(
                at: homeDescriptor,
                name: Self.localDirectoryName,
                createIfMissing: false
            ) else {
                return missingLinkStatus
            }
            defer { close(localDescriptor) }

            guard let binDescriptor = try openDirectory(
                at: localDescriptor,
                name: Self.binDirectoryName,
                createIfMissing: false
            ) else {
                return missingLinkStatus
            }
            defer { close(binDescriptor) }

            return switch linkState(in: binDescriptor) {
            case .managed: .installed
            case .occupied: .conflict
            case .missing: missingLinkStatus
            }
        } catch {
            return .unsafeParent
        }
    }

    func install() throws {
        let homeDescriptor = try openHomeDirectory()
        defer { close(homeDescriptor) }

        guard helperIsAvailable else {
            throw CommandLineToolInstallationError.helperUnavailable
        }
        guard let localDescriptor = try openDirectory(
            at: homeDescriptor,
            name: Self.localDirectoryName,
            createIfMissing: true
        ) else {
            throw CommandLineToolInstallationError.unsafeParentDirectory
        }
        defer { close(localDescriptor) }
        guard let binDescriptor = try openDirectory(
            at: localDescriptor,
            name: Self.binDirectoryName,
            createIfMissing: true
        ) else {
            throw CommandLineToolInstallationError.unsafeParentDirectory
        }
        defer { close(binDescriptor) }

        switch linkState(in: binDescriptor) {
        case .managed:
            return
        case .occupied:
            throw CommandLineToolInstallationError.destinationOccupied
        case .missing:
            break
        }

        guard symlinkat(helperPath, binDescriptor, Self.linkName) == 0 else {
            let code = errno
            if code == EEXIST {
                if linkState(in: binDescriptor) == .managed {
                    return
                }
                throw CommandLineToolInstallationError.destinationOccupied
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    func remove() throws {
        let homeDescriptor = try openHomeDirectory()
        defer { close(homeDescriptor) }

        guard let localDescriptor = try openDirectory(
            at: homeDescriptor,
            name: Self.localDirectoryName,
            createIfMissing: false
        ) else {
            return
        }
        defer { close(localDescriptor) }
        guard let binDescriptor = try openDirectory(
            at: localDescriptor,
            name: Self.binDirectoryName,
            createIfMissing: false
        ) else {
            return
        }
        defer { close(binDescriptor) }

        switch linkState(in: binDescriptor) {
        case .missing:
            return
        case .occupied:
            throw CommandLineToolInstallationError.destinationNotManaged
        case .managed:
            break
        }

        guard unlinkat(binDescriptor, Self.linkName, 0) == 0 else {
            let code = errno
            if code == ENOENT {
                return
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    private var missingLinkStatus: Status {
        helperIsAvailable ? .notInstalled : .unavailable
    }

    private var helperIsAvailable: Bool {
        guard helperPath.hasPrefix("/") else {
            return false
        }
        var metadata = stat()
        return lstat(helperPath, &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFREG
            && access(helperPath, X_OK) == 0
    }

    private func openHomeDirectory() throws -> Int32 {
        let descriptor = open(homePath, Self.directoryOpenFlags)
        guard descriptor >= 0 else {
            throw CommandLineToolInstallationError.unsafeParentDirectory
        }
        return try validateDirectory(descriptor)
    }

    private func openDirectory(
        at parentDescriptor: Int32,
        name: String,
        createIfMissing: Bool
    ) throws -> Int32? {
        var descriptor = openat(parentDescriptor, name, Self.directoryOpenFlags)
        if descriptor < 0 {
            let openError = errno
            if !createIfMissing, openError == ENOENT {
                return nil
            }
            guard createIfMissing, openError == ENOENT else {
                throw CommandLineToolInstallationError.unsafeParentDirectory
            }
            if mkdirat(parentDescriptor, name, mode_t(0o700)) != 0, errno != EEXIST {
                throw CommandLineToolInstallationError.unsafeParentDirectory
            }
            descriptor = openat(parentDescriptor, name, Self.directoryOpenFlags)
        }
        guard descriptor >= 0 else {
            throw CommandLineToolInstallationError.unsafeParentDirectory
        }
        return try validateDirectory(descriptor)
    }

    private func validateDirectory(_ descriptor: Int32) throws -> Int32 {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_mode & mode_t(0o022) == 0 else {
            close(descriptor)
            throw CommandLineToolInstallationError.unsafeParentDirectory
        }
        return descriptor
    }

    private func linkState(in binDescriptor: Int32) -> LinkState {
        let expectedTarget = helperPath.utf8.map { CChar(bitPattern: $0) }
        var target = [CChar](repeating: 0, count: expectedTarget.count + 1)
        let length = target.withUnsafeMutableBufferPointer {
            readlinkat(binDescriptor, Self.linkName, $0.baseAddress, $0.count)
        }
        guard length >= 0 else {
            return errno == ENOENT ? .missing : .occupied
        }
        guard helperPath.hasPrefix("/"), length == expectedTarget.count else {
            return .occupied
        }
        return target.prefix(Int(length)).elementsEqual(expectedTarget)
            ? .managed
            : .occupied
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
