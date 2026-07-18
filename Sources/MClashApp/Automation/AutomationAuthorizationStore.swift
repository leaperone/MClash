import CryptoKit
import Darwin
import Foundation
import MClashAutomationProtocol
import Security

struct AutomationPeerIdentity: Sendable {
    let processIdentifier: Int32
    let userIdentifier: uid_t
    let executablePath: String
    let signingIdentifier: String?
    let teamIdentifier: String?
    let codeHash: String?

    init(
        processIdentifier: Int32,
        userIdentifier: uid_t,
        executablePath: String,
        signingIdentifier: String?,
        teamIdentifier: String?,
        codeHash: String? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.userIdentifier = userIdentifier
        self.executablePath = URL(fileURLWithPath: executablePath)
            .standardizedFileURL.path
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.codeHash = codeHash
    }

    var displayName: String {
        URL(fileURLWithPath: executablePath).lastPathComponent.isEmpty
            ? "PID \(processIdentifier)"
            : URL(fileURLWithPath: executablePath).lastPathComponent
    }
}

@MainActor
final class AutomationAuthorizationStore {
    enum Storage: Equatable {
        case keychain
        case ephemeral
    }

    struct Client: Codable, Sendable {
        let id: UUID
        let name: String
        let tokenHash: String
        let scopes: Set<AutomationClientScope>
        let executablePath: String
        let signingIdentifier: String?
        let teamIdentifier: String?
        let codeHash: String?
        let createdAt: Date
        let expiresAt: Date
    }

    struct PublicClient: Codable, Sendable {
        let id: UUID
        let name: String
        let scopes: Set<AutomationClientScope>
        let executablePath: String
        let signingIdentifier: String?
        let teamIdentifier: String?
        let createdAt: Date
        let expiresAt: Date
    }

    private struct Document: Codable {
        let schemaVersion: Int
        var clients: [Client]
    }

    private static let keychainService = "one.leaper.mclash.automation.authorization"
    private static let keychainAccount = "authorized-clients-v1"
    private static let keychainAccessGroup = "5UAHRS482C.one.leaper.mclash.authorization"
    private let storage: Storage
    private var clients: [Client]

    init(directory: URL, storage: Storage = .keychain) throws {
        try Self.ensurePrivateDirectory(directory)
        self.storage = storage
        if storage == .keychain, let data = try Self.loadKeychainDocument() {
            guard data.count <= 256 * 1_024 else {
                throw AuthorizationError.insecureDocument
            }
            let document = try JSONDecoder.automation.decode(Document.self, from: data)
            guard document.schemaVersion == 1 else {
                throw AuthorizationError.unsupportedSchema(document.schemaVersion)
            }
            clients = document.clients.filter { $0.expiresAt > Date() }
        } else {
            clients = []
        }
    }

    func issue(
        name: String,
        scopes requestedScopes: Set<AutomationClientScope>,
        peer: AutomationPeerIdentity
    ) throws -> (client: PublicClient, token: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 80 else {
            throw AuthorizationError.invalidClientName
        }
        guard !requestedScopes.isEmpty,
              requestedScopes.isSubset(of: Set(AutomationClientScope.allCases)) else {
            throw AuthorizationError.invalidScopes
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AuthorizationError.randomGenerationFailed
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let now = Date()
        let existingClient = clients.first {
            $0.name == trimmedName
                && $0.expiresAt > now
                && Self.matches(client: $0, peer: peer)
        }
        let effectiveScopes = scopesForPairing(
            name: trimmedName,
            requestedScopes: requestedScopes,
            peer: peer
        )
        let client = Client(
            id: existingClient?.id ?? UUID(),
            name: trimmedName,
            tokenHash: Self.hash(token),
            scopes: effectiveScopes,
            executablePath: peer.executablePath,
            signingIdentifier: peer.signingIdentifier,
            teamIdentifier: peer.teamIdentifier,
            codeHash: peer.codeHash,
            createdAt: existingClient?.createdAt ?? now,
            expiresAt: now.addingTimeInterval(180 * 24 * 60 * 60)
        )
        var updatedClients = clients
        updatedClients.removeAll { existing in
            existing.name == client.name
                && Self.matches(client: existing, peer: peer)
        }
        updatedClients.append(client)
        try persist(updatedClients)
        clients = updatedClients
        return (publicClient(client), token)
    }

    func scopesForPairing(
        name: String,
        requestedScopes: Set<AutomationClientScope>,
        peer: AutomationPeerIdentity
    ) -> Set<AutomationClientScope> {
        let existing = clients.first {
            $0.name == name
                && $0.expiresAt > Date()
                && Self.matches(client: $0, peer: peer)
        }
        return requestedScopes.union(existing?.scopes ?? [])
    }

    func authorize(
        token: String?,
        requiredScope: AutomationClientScope,
        peer: AutomationPeerIdentity
    ) throws -> PublicClient {
        guard let token, token.utf8.count <= 256 else {
            throw AuthorizationError.authenticationRequired
        }
        let hash = Self.hash(token)
        guard let client = clients.first(where: {
            $0.tokenHash == hash && $0.expiresAt > Date()
        }) else {
            throw AuthorizationError.authenticationRequired
        }
        guard client.scopes.contains(requiredScope) else {
            throw AuthorizationError.scopeRequired(requiredScope)
        }
        guard Self.matches(client: client, peer: peer) else {
            throw AuthorizationError.clientIdentityChanged
        }
        return publicClient(client)
    }

    func list() -> [PublicClient] {
        clients.filter { $0.expiresAt > Date() }.map(publicClient)
    }

    func revoke(id: UUID) throws {
        var updatedClients = clients
        updatedClients.removeAll { $0.id == id }
        guard updatedClients.count != clients.count else {
            throw AuthorizationError.clientNotFound
        }
        try persist(updatedClients)
        clients = updatedClients
    }

    private func publicClient(_ client: Client) -> PublicClient {
        PublicClient(
            id: client.id,
            name: client.name,
            scopes: client.scopes,
            executablePath: client.executablePath,
            signingIdentifier: client.signingIdentifier,
            teamIdentifier: client.teamIdentifier,
            createdAt: client.createdAt,
            expiresAt: client.expiresAt
        )
    }

    private func persist(_ clients: [Client]) throws {
        guard storage == .keychain else { return }
        let document = Document(schemaVersion: 1, clients: clients)
        let data = try JSONEncoder.automation.encode(document)
        guard data.count <= 256 * 1_024 else {
            throw AuthorizationError.insecureDocument
        }
        let key: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: Self.keychainAccount,
            kSecAttrAccessGroup: Self.keychainAccessGroup,
            kSecUseDataProtectionKeychain: true,
        ]
        let updateStatus = SecItemUpdate(
            key as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var item = key
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw AuthorizationError.keychain(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw AuthorizationError.keychain(updateStatus)
        }
    }

    private static func loadKeychainDocument() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecAttrAccessGroup: keychainAccessGroup,
            kSecUseDataProtectionKeychain: true,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AuthorizationError.keychain(status)
        }
        return data
    }

    private static func matches(
        client: Client,
        peer: AutomationPeerIdentity
    ) -> Bool {
        if let signingIdentifier = client.signingIdentifier {
            if let teamIdentifier = client.teamIdentifier,
               !teamIdentifier.isEmpty {
                return signingIdentifier == peer.signingIdentifier
                    && teamIdentifier == peer.teamIdentifier
            }
            guard let clientCodeHash = client.codeHash,
                  let peerCodeHash = peer.codeHash else { return false }
            return client.executablePath == peer.executablePath
                && signingIdentifier == peer.signingIdentifier
                && clientCodeHash == peerCodeHash
        }
        guard let clientCodeHash = client.codeHash,
              let peerCodeHash = peer.codeHash else { return false }
        return client.executablePath == peer.executablePath
            && peer.signingIdentifier == nil
            && clientCodeHash == peerCodeHash
    }

    private static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid() else {
            throw AuthorizationError.insecurePath(url.path)
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw AuthorizationError.systemCall("chmod", errno)
        }
    }

}

enum AuthorizationError: Error, LocalizedError {
    case authenticationRequired
    case scopeRequired(AutomationClientScope)
    case clientIdentityChanged
    case invalidClientName
    case invalidScopes
    case randomGenerationFailed
    case clientNotFound
    case unsupportedSchema(Int)
    case insecureDocument
    case insecurePath(String)
    case keychain(OSStatus)
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case .authenticationRequired: "This client is not paired with MClash."
        case let .scopeRequired(scope): "This client requires the \(scope.rawValue) scope."
        case .clientIdentityChanged: "The paired client identity no longer matches."
        case .invalidClientName: "The automation client name is invalid."
        case .invalidScopes: "The requested automation scopes are invalid."
        case .randomGenerationFailed: "A secure client token could not be generated."
        case .clientNotFound: "The automation client was not found."
        case let .unsupportedSchema(version): "Automation authorization schema \(version) is unsupported."
        case .insecureDocument: "Automation authorization data is invalid or too large."
        case let .insecurePath(path): "Automation refused an insecure path: \(path)"
        case let .keychain(status): "Automation authorization Keychain access failed (\(status))."
        case let .systemCall(name, code):
            "Automation \(name) failed: \(String(cString: strerror(code)))"
        }
    }
}
