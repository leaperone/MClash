import CoreFoundation
import Foundation

/// A Codable representation of values accepted by SystemConfiguration proxy dictionaries.
public enum SystemProxyPropertyValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case data(Data)
    case date(Date)
    case array([SystemProxyPropertyValue])
    case dictionary([String: SystemProxyPropertyValue])

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum Kind: String, Codable {
        case string
        case integer
        case double
        case bool
        case data
        case date
        case array
        case dictionary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .integer:
            self = .integer(try container.decode(Int64.self, forKey: .value))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .value))
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case .data:
            self = .data(try container.decode(Data.self, forKey: .value))
        case .date:
            self = .date(try container.decode(Date.self, forKey: .value))
        case .array:
            self = .array(try container.decode([SystemProxyPropertyValue].self, forKey: .value))
        case .dictionary:
            self = .dictionary(
                try container.decode([String: SystemProxyPropertyValue].self, forKey: .value)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(value):
            try container.encode(Kind.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .double(value):
            try container.encode(Kind.double, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .bool(value):
            try container.encode(Kind.bool, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .data(value):
            try container.encode(Kind.data, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .date(value):
            try container.encode(Kind.date, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .array(value):
            try container.encode(Kind.array, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .dictionary(value):
            try container.encode(Kind.dictionary, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }

    init(propertyListValue value: Any, path: String) throws {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
                return
            }

            let numericType = String(cString: number.objCType)
            if "cCsSiIlLqQ".contains(numericType) {
                self = .integer(number.int64Value)
            } else {
                self = .double(number.doubleValue)
            }
            return
        }

        if let value = value as? String {
            self = .string(value)
        } else if let value = value as? Data {
            self = .data(value)
        } else if let value = value as? Date {
            self = .date(value)
        } else if let value = value as? [Any] {
            self = .array(
                try value.enumerated().map { index, element in
                    try SystemProxyPropertyValue(
                        propertyListValue: element,
                        path: "\(path)[\(index)]"
                    )
                }
            )
        } else if let value = value as? [String: Any] {
            self = .dictionary(try Self.dictionary(from: value, path: path))
        } else {
            throw SystemProxyError.invalidPropertyListValue(
                path: path,
                type: String(describing: Swift.type(of: value))
            )
        }
    }

    var propertyListValue: Any {
        switch self {
        case let .string(value):
            return value
        case let .integer(value):
            return NSNumber(value: value)
        case let .double(value):
            return NSNumber(value: value)
        case let .bool(value):
            return NSNumber(value: value)
        case let .data(value):
            return value
        case let .date(value):
            return value
        case let .array(value):
            return value.map(\.propertyListValue)
        case let .dictionary(value):
            return value.mapValues(\.propertyListValue)
        }
    }

    static func dictionary(
        from propertyList: [String: Any],
        path: String = "proxyConfiguration"
    ) throws -> [String: SystemProxyPropertyValue] {
        try propertyList.reduce(into: [:]) { result, pair in
            result[pair.key] = try SystemProxyPropertyValue(
                propertyListValue: pair.value,
                path: "\(path).\(pair.key)"
            )
        }
    }
}

public typealias SystemProxyDictionary = [String: SystemProxyPropertyValue]

public enum SystemProxyKeys {
    public static let httpEnable = "HTTPEnable"
    public static let httpHost = "HTTPProxy"
    public static let httpPort = "HTTPPort"

    public static let httpsEnable = "HTTPSEnable"
    public static let httpsHost = "HTTPSProxy"
    public static let httpsPort = "HTTPSPort"

    public static let socksEnable = "SOCKSEnable"
    public static let socksHost = "SOCKSProxy"
    public static let socksPort = "SOCKSPort"

    public static let pacEnable = "ProxyAutoConfigEnable"
    public static let pacURL = "ProxyAutoConfigURLString"
    public static let autoDiscoveryEnable = "ProxyAutoDiscoveryEnable"
}

public struct SystemProxyEndpoint: Codable, Equatable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String = "127.0.0.1", port: Int) throws {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else {
            throw SystemProxyError.invalidEndpoint(reason: "Proxy host must not be empty.")
        }
        guard (1...65_535).contains(port) else {
            throw SystemProxyError.invalidEndpoint(
                reason: "Proxy port must be between 1 and 65535; received \(port)."
            )
        }

        self.host = normalizedHost
        self.port = port
    }
}

public struct LocalSystemProxyEndpoints: Codable, Equatable, Sendable {
    public let http: SystemProxyEndpoint
    public let https: SystemProxyEndpoint
    public let socks: SystemProxyEndpoint

    public init(
        http: SystemProxyEndpoint,
        https: SystemProxyEndpoint,
        socks: SystemProxyEndpoint
    ) {
        self.http = http
        self.https = https
        self.socks = socks
    }

    /// Uses mihomo's mixed port for all three macOS proxy protocols.
    public init(mixedPort: Int, host: String = "127.0.0.1") throws {
        let endpoint = try SystemProxyEndpoint(host: host, port: mixedPort)
        self.init(http: endpoint, https: endpoint, socks: endpoint)
    }
}

public struct SystemProxyNetworkService: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Captures both protocol existence and its full dictionary so restoration is lossless.
public struct SystemProxyServiceState: Codable, Equatable, Sendable {
    public let service: SystemProxyNetworkService
    public let protocolExists: Bool
    public let configuration: SystemProxyDictionary?

    public init(
        service: SystemProxyNetworkService,
        protocolExists: Bool,
        configuration: SystemProxyDictionary?
    ) throws {
        guard protocolExists || configuration == nil else {
            throw SystemProxyError.invalidServiceState(
                serviceID: service.id,
                reason: "A configuration cannot exist when the proxy protocol is absent."
            )
        }
        self.service = service
        self.protocolExists = protocolExists
        self.configuration = configuration
    }
}

public struct SystemProxySnapshot: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let capturedAt: Date
    public let services: [SystemProxyServiceState]

    public init(
        capturedAt: Date = Date(),
        services: [SystemProxyServiceState]
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.capturedAt = capturedAt
        self.services = services
    }
}

public enum SystemProxyError: Error, Equatable, LocalizedError, Sendable {
    case preferencesUnavailable
    case currentNetworkSetUnavailable
    case serviceNotFound(String)
    case proxyProtocolUnavailable(String)
    case invalidPropertyListValue(path: String, type: String)
    case invalidEndpoint(reason: String)
    case invalidServiceState(serviceID: String, reason: String)
    case duplicateService(String)
    case lockFailed
    case commitFailed
    case applyFailed
    case unsupportedSnapshotVersion(Int)
    case persistenceFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .preferencesUnavailable:
            return "Unable to open macOS network preferences."
        case .currentNetworkSetUnavailable:
            return "Unable to read the current macOS network set."
        case let .serviceNotFound(id):
            return "Network service '\(id)' no longer exists."
        case let .proxyProtocolUnavailable(id):
            return "Unable to create or access the proxy protocol for network service '\(id)'."
        case let .invalidPropertyListValue(path, type):
            return "Unsupported proxy value of type '\(type)' at '\(path)'."
        case let .invalidEndpoint(reason):
            return "Invalid local proxy endpoint: \(reason)"
        case let .invalidServiceState(serviceID, reason):
            return "Invalid proxy state for service '\(serviceID)': \(reason)"
        case let .duplicateService(id):
            return "Proxy operation contains duplicate network service '\(id)'."
        case .lockFailed:
            return "Unable to lock macOS network preferences for an atomic proxy update."
        case .commitFailed:
            return "macOS rejected the proxy preference changes while committing them."
        case .applyFailed:
            return "macOS could not apply the committed proxy preference changes."
        case let .unsupportedSnapshotVersion(version):
            return "Unsupported system proxy snapshot version \(version)."
        case let .persistenceFailed(path, reason):
            return "Unable to persist system proxy state at '\(path)': \(reason)"
        }
    }
}
