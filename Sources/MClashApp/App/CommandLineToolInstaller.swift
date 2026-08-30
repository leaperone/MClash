import Darwin
import Foundation

struct CommandLineToolInstaller {
    enum Status: Equatable {
        case notInstalled
        case installed
        case conflict
        case unsafeSource
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
    private static let applicationsPath = "/Applications"
    private static let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    private let helperPath: String
    private let homePath: String
    private let appBundleName: String
    private let appIsDirectlyInApplications: Bool

    init(bundle: Bundle = .main, fileManager: FileManager = .default) {
        let bundleURL = bundle.bundleURL.standardizedFileURL
        helperPath = bundleURL
            .appendingPathComponent("Contents/Helpers/mclashctl", isDirectory: false)
            .path
        homePath = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        appBundleName = bundleURL.lastPathComponent
        appIsDirectlyInApplications = bundleURL.deletingLastPathComponent().path
            == Self.applicationsPath
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

        guard appIsDirectlyInApplications else {
            throw CommandLineToolInstallationError.unsafeSource
        }
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
        guard appIsDirectlyInApplications else { return .unsafeSource }
        return helperIsAvailable ? .notInstalled : .unavailable
    }

    private var helperIsAvailable: Bool {
        guard appIsDirectlyInApplications else { return false }
        let applicationsDescriptor = open(Self.applicationsPath, Self.directoryOpenFlags)
        guard applicationsDescriptor >= 0,
              isTrustedApplicationsDirectory(applicationsDescriptor) else {
            if applicationsDescriptor >= 0 { close(applicationsDescriptor) }
            return false
        }
        defer { close(applicationsDescriptor) }
        guard let bundleDescriptor = openTrustedSourceDirectory(
            at: applicationsDescriptor,
            name: appBundleName
        ) else { return false }
        defer { close(bundleDescriptor) }
        guard let contentsDescriptor = openTrustedSourceDirectory(
            at: bundleDescriptor,
            name: "Contents"
        ) else { return false }
        defer { close(contentsDescriptor) }
        guard let helpersDescriptor = openTrustedSourceDirectory(
            at: contentsDescriptor,
            name: "Helpers"
        ) else { return false }
        defer { close(helpersDescriptor) }
        let helperDescriptor = openat(
            helpersDescriptor,
            Self.linkName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard helperDescriptor >= 0 else { return false }
        defer { close(helperDescriptor) }
        var metadata = stat()
        return fstat(helperDescriptor, &metadata) == 0
            && metadata.st_mode & S_IFMT == S_IFREG
            && isTrustedSource(metadata, descriptor: helperDescriptor)
            && isExecutableByCurrentUser(metadata)
    }

    private func openTrustedSourceDirectory(
        at parentDescriptor: Int32,
        name: String
    ) -> Int32? {
        let descriptor = openat(parentDescriptor, name, Self.directoryOpenFlags)
        guard descriptor >= 0 else { return nil }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              isTrustedSource(metadata, descriptor: descriptor) else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    private func isTrustedApplicationsDirectory(_ descriptor: Int32) -> Bool {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { return false }
        let groupWriteIsTrusted = metadata.st_mode & mode_t(0o020) == 0
            || getgrnam("admin")?.pointee.gr_gid == metadata.st_gid
        return metadata.st_mode & S_IFMT == S_IFDIR
            && metadata.st_uid == 0
            && metadata.st_mode & mode_t(0o002) == 0
            && groupWriteIsTrusted
            && !hasUnsafeExtendedACL(descriptor)
    }

    private func isTrustedSource(_ metadata: stat, descriptor: Int32) -> Bool {
        (metadata.st_uid == 0 || metadata.st_uid == getuid())
            && metadata.st_mode & mode_t(0o022) == 0
            && !hasUnsafeExtendedACL(descriptor)
    }

    private func isExecutableByCurrentUser(_ metadata: stat) -> Bool {
        let permission = metadata.st_uid == getuid() ? S_IXUSR : S_IXOTH
        return metadata.st_mode & mode_t(permission) != 0
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
              metadata.st_mode & mode_t(0o022) == 0,
              !hasUnsafeExtendedACL(descriptor) else {
            close(descriptor)
            throw CommandLineToolInstallationError.unsafeParentDirectory
        }
        return descriptor
    }

    private func hasUnsafeExtendedACL(_ descriptor: Int32) -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno != ENOENT
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var result = acl_get_entry(
            acl,
            Int32(ACL_FIRST_ENTRY.rawValue),
            &entry
        )
        while result == 0 {
            guard let currentEntry = entry else { return true }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(currentEntry, &tag) == 0 else { return true }
            if tag == ACL_EXTENDED_ALLOW {
                var permissions: acl_permset_t?
                guard acl_get_permset(currentEntry, &permissions) == 0,
                      let permissions else { return true }
                for permission in [
                    ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE,
                    ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES,
                    ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY,
                    ACL_CHANGE_OWNER,
                ] where acl_get_perm_np(permissions, permission) != 0 {
                    return true
                }
            }
            result = acl_get_entry(
                acl,
                Int32(ACL_NEXT_ENTRY.rawValue),
                &entry
            )
        }
        return result != -1 || errno != EINVAL
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
    case unsafeSource
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
        case .unsafeSource:
            AppLocalization.string(
                "Move MClash directly to /Applications before installing its command-line tool."
            )
        case .unsafeParentDirectory:
            AppLocalization.string(
                "~/.local and ~/.local/bin must be directories owned by you and not writable by other users."
            )
        }
    }
}
