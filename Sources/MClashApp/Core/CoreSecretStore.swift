import Foundation
import Security

protocol CoreSecretProviding: Sendable {
    func loadOrCreate() throws -> String
}

/// Keeps the local controller credential private to a single app launch.
///
/// The controller only listens on localhost and is restarted with MClash, so persisting this
/// credential in Keychain adds no user value. More importantly, development and ad-hoc builds are
/// signed with changing identities, which can make macOS request Keychain approval on every
/// connection. An in-memory secret avoids that prompt while still protecting the controller API.
final class EphemeralCoreSecretProvider: CoreSecretProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var cachedSecret: String?

    func loadOrCreate() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cachedSecret { return cachedSecret }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CoreSecretStoreError.randomGenerationFailed(status)
        }

        let secret = Data(bytes).base64EncodedString()
        cachedSecret = secret
        return secret
    }
}

enum CoreSecretStoreError: LocalizedError {
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .randomGenerationFailed(status):
            "Could not generate the local controller secret (status \(status))."
        }
    }
}
