import Darwin
import Foundation

/// A process-wide, per-user lock that prevents two host applications from
/// owning MClash's shared profile, proxy, and core state at the same time.
final class ApplicationInstanceLock {
    private(set) var isOwner: Bool
    private var fileDescriptor: Int32 = -1

    init(
        lockURL: URL = ApplicationInstanceLock.defaultLockURL(),
        fileManager: FileManager = .default
    ) {
        do {
            try fileManager.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            // Launch Services and the Info.plist policy remain as fallbacks if
            // the cache directory is temporarily unavailable.
            isOwner = true
            return
        }

        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(
                path,
                O_CREAT | O_RDWR | O_CLOEXEC | O_EXLOCK | O_NONBLOCK,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            isOwner = errno != EWOULDBLOCK && errno != EAGAIN
            return
        }

        fileDescriptor = descriptor
        isOwner = true
    }

    deinit {
        release()
    }

    func release() {
        guard fileDescriptor >= 0 else { return }
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
        isOwner = false
    }

    static func defaultLockURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent("one.leaper.mclash", isDirectory: true)
            .appendingPathComponent("application-instance.lock", isDirectory: false)
    }
}
