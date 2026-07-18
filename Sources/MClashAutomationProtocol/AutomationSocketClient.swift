import Darwin
import Foundation
import Security

public struct AutomationSocketClient: Sendable {
    public let socketPath: String
    public let expectedProcessIdentifier: Int32?
    public let expectedSigningIdentifier: String?
    public let expectedTeamIdentifier: String?
    public let expectedExecutablePath: String?

    public init(
        socketPath: String,
        expectedProcessIdentifier: Int32,
        expectedSigningIdentifier: String,
        expectedTeamIdentifier: String?,
        expectedExecutablePath: String
    ) {
        self.socketPath = socketPath
        self.expectedProcessIdentifier = expectedProcessIdentifier
        self.expectedSigningIdentifier = expectedSigningIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.expectedExecutablePath = expectedExecutablePath
    }

    /// Connects without authenticating the server. This is only suitable for
    /// isolated development sockets and must never be given a production token.
    public init(unsafeDevelopmentSocketPath socketPath: String) {
        self.socketPath = socketPath
        expectedProcessIdentifier = nil
        expectedSigningIdentifier = nil
        expectedTeamIdentifier = nil
        expectedExecutablePath = nil
    }

    public func send(
        _ request: AutomationRPCRequest,
        timeout: TimeInterval = 10
    ) throws -> AutomationRPCResponse {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AutomationSocketError.systemCall("socket", errno) }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw AutomationSocketError.systemCall("fcntl", errno)
        }

        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw AutomationSocketError.systemCall("setsockopt", errno)
        }

        var timeValue = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1)) * 1_000_000)
        )
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeValue,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0,
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeValue,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw AutomationSocketError.systemCall("setsockopt", errno)
        }

        try withUnixSocketAddress(path: socketPath) { address, length in
            var address = address
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, length)
                }
            }
            guard result == 0 else {
                throw AutomationSocketError.systemCall("connect", errno)
            }
        }
        try verifyServer(descriptor: descriptor)

        let payload = try JSONEncoder.automation.encode(request)
        try writeAll(try AutomationFrameCodec.encode(payload), to: descriptor)
        let header = try readExactly(MemoryLayout<UInt32>.size, from: descriptor)
        let payloadLength = try AutomationFrameCodec.payloadLength(from: header)
        let responseData = try readExactly(payloadLength, from: descriptor)
        return try JSONDecoder.automation.decode(AutomationRPCResponse.self, from: responseData)
    }

    private func verifyServer(descriptor: Int32) throws {
        guard expectedProcessIdentifier != nil
                || expectedSigningIdentifier != nil
                || expectedTeamIdentifier != nil
                || expectedExecutablePath != nil else { return }
        var peerPID = pid_t(0)
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &length) == 0 else {
            throw AutomationSocketError.systemCall("getsockopt", errno)
        }
        if let expectedProcessIdentifier,
           peerPID != expectedProcessIdentifier {
            throw AutomationSocketError.serverIdentityMismatch
        }
        if let expectedExecutablePath {
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            let pathLength = proc_pidpath(peerPID, &pathBuffer, UInt32(pathBuffer.count))
            guard pathLength > 0 else {
                throw AutomationSocketError.serverIdentityMismatch
            }
            let pathBytes = pathBuffer.prefix(Int(pathLength)).prefix { $0 != 0 }
            let actualPath = String(
                decoding: pathBytes.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            guard URL(fileURLWithPath: actualPath).standardizedFileURL.path
                    == URL(fileURLWithPath: expectedExecutablePath).standardizedFileURL.path else {
                throw AutomationSocketError.serverIdentityMismatch
            }
        }
        let identity = AutomationCodeSignature.identity(processIdentifier: peerPID)
        if let expectedSigningIdentifier,
           identity.signingIdentifier != expectedSigningIdentifier {
            throw AutomationSocketError.serverIdentityMismatch
        }
        if let expectedTeamIdentifier,
           identity.teamIdentifier != expectedTeamIdentifier {
            throw AutomationSocketError.serverIdentityMismatch
        }
    }
}

public enum AutomationCodeSignature {
    public static func currentProcessTeamIdentifier() -> String? {
        identity(processIdentifier: getpid()).teamIdentifier
    }

    static func identity(
        processIdentifier: pid_t
    ) -> (signingIdentifier: String?, teamIdentifier: String?) {
        let attributes = [kSecGuestAttributePid as String: processIdentifier] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return (nil, nil) }
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else {
            return (nil, nil)
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return (nil, nil) }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [String: Any] else { return (nil, nil) }
        return (
            values[kSecCodeInfoIdentifier as String] as? String,
            values[kSecCodeInfoTeamIdentifier as String] as? String
        )
    }
}

public enum AutomationDiscovery {
    public static func defaultDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent(
                MClashAutomationProtocol.defaultApplicationIdentifier,
                isDirectory: true
            )
            .appendingPathComponent("Automation", isDirectory: true)
    }

    public static func defaultFileURL(
        fileManager: FileManager = .default
    ) throws -> URL {
        try defaultDirectory(fileManager: fileManager)
            .appendingPathComponent(MClashAutomationProtocol.discoveryFileName)
    }

    public static func load(
        from url: URL? = nil,
        fileManager: FileManager = .default,
        validateEndpoint: Bool = true
    ) throws -> AutomationEndpointDiscovery {
        let target = try url ?? defaultFileURL(fileManager: fileManager)
        let descriptor = open(target.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw AutomationSocketError.discoveryUnavailable(target.path)
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw AutomationSocketError.systemCall("fstat", errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              (metadata.st_mode & 0o077) == 0,
              metadata.st_size >= 0,
              metadata.st_size <= 16 * 1_024 else {
            throw AutomationSocketError.insecureDiscoveryFile(target.path)
        }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            .read(upToCount: 16 * 1_024 + 1) ?? Data()
        let discovery = try decodeDiscoveryData(data, sourcePath: target.path)
        guard discovery.apiVersion == MClashAutomationProtocol.currentVersion else {
            throw AutomationSocketError.unsupportedAPIVersion(discovery.apiVersion)
        }
        if validateEndpoint {
            guard discovery.processIdentifier > 0,
                  kill(discovery.processIdentifier, 0) == 0 else {
                throw AutomationSocketError.discoveryUnavailable(target.path)
            }
            var socketMetadata = stat()
            guard lstat(discovery.socketPath, &socketMetadata) == 0,
                  (socketMetadata.st_mode & S_IFMT) == S_IFSOCK,
                  socketMetadata.st_uid == getuid(),
                  (socketMetadata.st_mode & 0o077) == 0 else {
                throw AutomationSocketError.insecureSocket(discovery.socketPath)
            }
        }
        return discovery
    }

    static func decodeDiscoveryData(
        _ data: Data,
        sourcePath: String
    ) throws -> AutomationEndpointDiscovery {
        guard data.count <= 16 * 1_024 else {
            throw AutomationSocketError.insecureDiscoveryFile(sourcePath)
        }
        return try JSONDecoder.automation.decode(
            AutomationEndpointDiscovery.self,
            from: data
        )
    }
}

public enum AutomationSocketError: Error, LocalizedError, Sendable {
    case pathTooLong(String)
    case connectionClosed
    case systemCall(String, Int32)
    case discoveryUnavailable(String)
    case insecureDiscoveryFile(String)
    case unsupportedAPIVersion(Int)
    case insecureSocket(String)
    case serverIdentityMismatch

    public var errorDescription: String? {
        switch self {
        case let .pathTooLong(path):
            "The automation socket path is too long: \(path)"
        case .connectionClosed:
            "The automation connection closed before the response completed."
        case let .systemCall(name, code):
            "Automation \(name) failed: \(String(cString: strerror(code)))"
        case let .discoveryUnavailable(path):
            "MClash automation endpoint is unavailable at \(path)."
        case let .insecureDiscoveryFile(path):
            "MClash refused the insecure automation discovery file at \(path)."
        case let .unsupportedAPIVersion(version):
            "MClash automation API version \(version) is unsupported."
        case let .insecureSocket(path):
            "MClash refused the insecure automation socket at \(path)."
        case .serverIdentityMismatch:
            "The automation server is not the expected signed MClash process."
        }
    }
}

public extension JSONEncoder {
    static var automation: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public extension JSONDecoder {
    static var automation: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private func withUnixSocketAddress<Result>(
    path: String,
    _ body: (sockaddr_un, socklen_t) throws -> Result
) throws -> Result {
    let bytes = Array(path.utf8CString)
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count <= capacity else { throw AutomationSocketError.pathTooLong(path) }
    address.sun_family = sa_family_t(AF_UNIX)
    path.withCString { source in
        _ = strlcpy(&address.sun_path.0, source, capacity)
    }
    let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
    return try body(address, length)
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let count = Darwin.write(
                descriptor,
                baseAddress.advanced(by: offset),
                rawBuffer.count - offset
            )
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw AutomationSocketError.systemCall("write", errno)
            }
            offset += count
        }
    }
}

private func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < count {
            let received = Darwin.read(
                descriptor,
                baseAddress.advanced(by: offset),
                count - offset
            )
            if received < 0, errno == EINTR { continue }
            guard received > 0 else {
                if received == 0 { throw AutomationSocketError.connectionClosed }
                throw AutomationSocketError.systemCall("read", errno)
            }
            offset += received
        }
    }
    return data
}
