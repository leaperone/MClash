import Foundation

/// The connector-neutral description of an MClash traffic entrance.
///
/// This is intentionally independent from Mihomo's YAML/listener vocabulary.
/// The legacy compiler can project this model to `listeners` while native
/// transports can bind the same entries directly.
public enum MClashListenerKind: String, Codable, CaseIterable, Sendable {
    case http
    case socks5
    case appRouting
    case tun

    public var requiresSocketEndpoint: Bool {
        switch self {
        case .http, .socks5: true
        case .appRouting, .tun: false
        }
    }
}

public enum MClashListenerRoute: Codable, Equatable, Hashable, Sendable {
    case direct
    case reject
    case outbound(OutboundRoute)
}

public struct MClashListenerSpec: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var kind: MClashListenerKind
    public var enabled: Bool
    public var bindAddress: String
    public var port: UInt16?
    public var route: MClashListenerRoute

    public init(
        id: UUID = UUID(),
        name: String,
        kind: MClashListenerKind,
        enabled: Bool = false,
        bindAddress: String = "127.0.0.1",
        port: Int? = nil,
        route: MClashListenerRoute = .direct
    ) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MClashListenerRegistryError.invalidName(name)
        }
        let normalizedAddress = bindAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isLoopback(normalizedAddress) else {
            throw MClashListenerRegistryError.nonLoopbackBindAddress(normalizedAddress)
        }
        let normalizedPort: UInt16?
        if let port {
            guard (1...Int(UInt16.max)).contains(port) else {
                throw MClashListenerRegistryError.invalidPort(port)
            }
            normalizedPort = UInt16(port)
        } else {
            normalizedPort = nil
        }
        if kind.requiresSocketEndpoint, normalizedPort == nil {
            throw MClashListenerRegistryError.missingPort(kind)
        }
        if !kind.requiresSocketEndpoint, normalizedPort != nil {
            throw MClashListenerRegistryError.unexpectedPort(kind)
        }
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.enabled = enabled
        self.bindAddress = normalizedAddress
        self.port = normalizedPort
        self.route = route
    }

    public var endpoint: String? {
        guard let port else { return nil }
        let host = bindAddress.contains(":") ? "[\(bindAddress)]" : bindAddress
        return "\(host):\(port)"
    }

    public static func isLoopback(_ address: String) -> Bool {
        address == "127.0.0.1" || address == "::1" || address == "localhost"
    }
}

public enum MClashListenerRegistryError: Error, Equatable, Sendable {
    case invalidName(String)
    case nonLoopbackBindAddress(String)
    case invalidPort(Int)
    case missingPort(MClashListenerKind)
    case unexpectedPort(MClashListenerKind)
    case duplicateID(UUID)
    case duplicateName(String)
    case duplicateEndpoint(String)
    case tooManyListeners(Int, maximum: Int)
    case encodedRegistryTooLarge(Int, maximum: Int)
}

extension MClashListenerRegistryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidName(name): "Listener name is empty: \(name)"
        case let .nonLoopbackBindAddress(address):
            "MClash listeners must bind to loopback; received \(address)."
        case let .invalidPort(port): "Listener port is invalid: \(port)."
        case let .missingPort(kind): "\(kind.rawValue) listeners require a port."
        case let .unexpectedPort(kind): "\(kind.rawValue) listeners do not accept a TCP port."
        case let .duplicateID(id): "Listener ID is duplicated: \(id)."
        case let .duplicateName(name): "Listener name is duplicated: \(name)."
        case let .duplicateEndpoint(endpoint): "Listener endpoint is duplicated: \(endpoint)."
        case let .tooManyListeners(actual, maximum):
            "Listener registry contains \(actual) entries; maximum is \(maximum)."
        case let .encodedRegistryTooLarge(actual, maximum):
            "Encoded listener registry is \(actual) bytes; maximum is \(maximum)."
        }
    }
}

/// Owns all user-visible entrances before any compatibility projection.
public struct MClashListenerRegistry: Codable, Equatable, Sendable {
    public static let maximumListeners = 256
    public static let maximumEncodedSize = 64 * 1_024

    public private(set) var listeners: [MClashListenerSpec]

    public init(listeners: [MClashListenerSpec] = []) throws {
        try Self.validate(listeners)
        self.listeners = listeners.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public var enabledListeners: [MClashListenerSpec] { listeners.filter(\.enabled) }

    public func listener(id: UUID) -> MClashListenerSpec? {
        listeners.first { $0.id == id }
    }

    public static func validate(_ listeners: [MClashListenerSpec]) throws {
        guard listeners.count <= maximumListeners else {
            throw MClashListenerRegistryError.tooManyListeners(
                listeners.count,
                maximum: maximumListeners
            )
        }
        var ids = Set<UUID>()
        var names = Set<String>()
        var endpoints = Set<String>()
        for listener in listeners {
            _ = try MClashListenerSpec(
                id: listener.id,
                name: listener.name,
                kind: listener.kind,
                enabled: listener.enabled,
                bindAddress: listener.bindAddress,
                port: listener.port.map(Int.init),
                route: listener.route
            )
            guard ids.insert(listener.id).inserted else {
                throw MClashListenerRegistryError.duplicateID(listener.id)
            }
            let name = listener.name.lowercased()
            guard names.insert(name).inserted else {
                throw MClashListenerRegistryError.duplicateName(listener.name)
            }
            if let endpoint = listener.endpoint {
                guard endpoints.insert(endpoint).inserted else {
                    throw MClashListenerRegistryError.duplicateEndpoint(endpoint)
                }
            }
        }
    }

    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumEncodedSize else {
            throw MClashListenerRegistryError.encodedRegistryTooLarge(
                data.count,
                maximum: Self.maximumEncodedSize
            )
        }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedSize else {
            throw MClashListenerRegistryError.encodedRegistryTooLarge(
                data.count,
                maximum: maximumEncodedSize
            )
        }
        let registry = try JSONDecoder().decode(Self.self, from: data)
        try validate(registry.listeners)
        return registry
    }
}
