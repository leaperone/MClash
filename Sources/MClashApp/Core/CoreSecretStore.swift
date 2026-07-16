import Foundation
import Security

protocol CoreSecretProviding: Sendable {
    func loadOrCreate() throws -> String
}

struct CoreSecretStore: CoreSecretProviding, Sendable {
    private let service = "app.mclash.core-controller"
    private let account = "local-controller-secret"

    func loadOrCreate() throws -> String {
        if let existing = try load() {
            return existing
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CoreSecretStoreError.randomGenerationFailed(status)
        }

        let secret = Data(bytes).base64EncodedString()
        try save(secret)
        return secret
    }

    private func load() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw CoreSecretStoreError.keychainFailure(status)
        }
        return secret
    }

    private func save(_ secret: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(secret.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CoreSecretStoreError.keychainFailure(status)
        }
    }
}

enum CoreSecretStoreError: LocalizedError {
    case randomGenerationFailed(OSStatus)
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .randomGenerationFailed(status):
            "Could not generate the local controller secret (status \(status))."
        case let .keychainFailure(status):
            "Could not access the MClash Keychain item (status \(status))."
        }
    }
}
