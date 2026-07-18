import Foundation

public enum MClashAutomationProtocol {
    public static let currentVersion = 1
    public static let maximumFrameSize = 1_048_576
    public static let maximumInlineProfileSize = 700 * 1_024
    public static let discoveryFileName = "endpoint.json"
    public static let defaultApplicationIdentifier = "MClash"
}

public enum AutomationJSONValue: Codable, Equatable, Sendable {
    case object([String: AutomationJSONValue])
    case array([AutomationJSONValue])
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AutomationJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: AutomationJSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .unsignedInteger(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var objectValue: [String: AutomationJSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    public var arrayValue: [AutomationJSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        switch self {
        case let .integer(value): Int(exactly: value)
        case let .unsignedInteger(value): Int(exactly: value)
        default: nil
        }
    }
}

public struct AutomationRPCRequest: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let apiVersion: Int
    public let id: String
    public let method: String
    public let params: [String: AutomationJSONValue]
    public let allowInteraction: Bool
    public let authorization: String?

    public init(
        id: String = UUID().uuidString,
        method: String,
        params: [String: AutomationJSONValue] = [:],
        allowInteraction: Bool = false,
        authorization: String? = nil,
        apiVersion: Int = MClashAutomationProtocol.currentVersion
    ) {
        jsonrpc = "2.0"
        self.apiVersion = apiVersion
        self.id = id
        self.method = method
        self.params = params
        self.allowInteraction = allowInteraction
        self.authorization = authorization
    }
}

public enum AutomationClientScope: String, Codable, CaseIterable, Sendable {
    case readBasic = "read.basic"
    case readSensitive = "read.sensitive"
    case control
    case destructive
}

public struct AutomationRPCError: Codable, Equatable, Sendable {
    public let code: Int
    public let type: String
    public let message: String
    public let retryable: Bool
    public let data: AutomationJSONValue?

    public init(
        code: Int,
        type: String,
        message: String,
        retryable: Bool = false,
        data: AutomationJSONValue? = nil
    ) {
        self.code = code
        self.type = type
        self.message = message
        self.retryable = retryable
        self.data = data
    }
}

public struct AutomationRPCResponse: Codable, Equatable, Sendable {
    public let jsonrpc: String
    public let apiVersion: Int
    public let id: String
    public let result: AutomationJSONValue?
    public let error: AutomationRPCError?

    public init(id: String, result: AutomationJSONValue) {
        jsonrpc = "2.0"
        apiVersion = MClashAutomationProtocol.currentVersion
        self.id = id
        self.result = result
        error = nil
    }

    public init(id: String, error: AutomationRPCError) {
        jsonrpc = "2.0"
        apiVersion = MClashAutomationProtocol.currentVersion
        self.id = id
        result = nil
        self.error = error
    }
}

public enum AutomationCommandRisk: String, Codable, Equatable, Sendable {
    case read
    case write
    case destructive
}

public struct AutomationCapability: Codable, Equatable, Sendable {
    public let method: String
    public let summary: String
    public let risk: AutomationCommandRisk
    public let parameters: [String: String]
    public let requiredScope: AutomationClientScope?
    public let requiresInteraction: Bool

    public init(
        method: String,
        summary: String,
        risk: AutomationCommandRisk,
        parameters: [String: String] = [:],
        requiredScope: AutomationClientScope? = nil,
        requiresInteraction: Bool = false
    ) {
        self.method = method
        self.summary = summary
        self.risk = risk
        self.parameters = parameters
        self.requiredScope = requiredScope
        self.requiresInteraction = requiresInteraction
    }
}

public struct AutomationEndpointDiscovery: Codable, Equatable, Sendable {
    public let apiVersion: Int
    public let processIdentifier: Int32
    public let socketPath: String
    public let nonce: String
    public let appVersion: String
    public let signingIdentifier: String
    public let startedAt: Date

    public init(
        processIdentifier: Int32,
        socketPath: String,
        nonce: String,
        appVersion: String,
        signingIdentifier: String = "one.leaper.mclash",
        startedAt: Date = Date()
    ) {
        apiVersion = MClashAutomationProtocol.currentVersion
        self.processIdentifier = processIdentifier
        self.socketPath = socketPath
        self.nonce = nonce
        self.appVersion = appVersion
        self.signingIdentifier = signingIdentifier
        self.startedAt = startedAt
    }
}

public enum AutomationFrameCodec {
    public static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= MClashAutomationProtocol.maximumFrameSize else {
            throw AutomationProtocolError.frameTooLarge(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        framed.append(payload)
        return framed
    }

    public static func payloadLength(from header: Data) throws -> Int {
        guard header.count == MemoryLayout<UInt32>.size else {
            throw AutomationProtocolError.invalidFrameHeader
        }
        let value = header.withUnsafeBytes { rawBuffer -> UInt32 in
            var value: UInt32 = 0
            withUnsafeMutableBytes(of: &value) { destination in
                destination.copyBytes(from: rawBuffer)
            }
            return UInt32(bigEndian: value)
        }
        guard value <= MClashAutomationProtocol.maximumFrameSize else {
            throw AutomationProtocolError.frameTooLarge(Int(value))
        }
        return Int(value)
    }
}

public enum AutomationProtocolError: Error, Equatable, LocalizedError, Sendable {
    case invalidFrameHeader
    case frameTooLarge(Int)
    case invalidParameters(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFrameHeader:
            "The automation frame header is invalid."
        case let .frameTooLarge(size):
            "The automation frame is too large (\(size) bytes)."
        case let .invalidParameters(message):
            message
        }
    }
}
