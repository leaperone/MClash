import Darwin
import Foundation
import MClashAutomationProtocol
import Security

final class AutomationSocketServer: @unchecked Sendable {
    private let socketBaseDirectory: URL?
    private let discoveryDirectory: URL?
    private let authorizationStorage: AutomationAuthorizationStore.Storage
    private let ioTimeoutNanoseconds: UInt64
    private let stateLock = NSLock()
    private let acceptQueue = DispatchQueue(
        label: "one.leaper.mclash.automation.accept",
        qos: .utility
    )
    private let clientQueue = DispatchQueue(
        label: "one.leaper.mclash.automation.clients",
        qos: .utility,
        attributes: .concurrent
    )
    private let clientLimit = DispatchSemaphore(value: 8)
    private var listeningDescriptor: Int32 = -1
    private var endpoint: AutomationEndpointDiscovery?
    private var gateway: AutomationCommandGateway?
    private var activeClientDescriptors: Set<Int32> = []

    init(
        socketBaseDirectory: URL? = nil,
        discoveryDirectory: URL? = nil,
        authorizationStorage: AutomationAuthorizationStore.Storage? = nil,
        ioTimeoutNanoseconds: UInt64 = 15 * NSEC_PER_SEC
    ) {
        self.socketBaseDirectory = socketBaseDirectory
        self.discoveryDirectory = discoveryDirectory
        self.authorizationStorage = authorizationStorage
            ?? (AutomationCodeSignature.currentProcessTeamIdentifier() == nil
                ? .ephemeral : .keychain)
        self.ioTimeoutNanoseconds = max(NSEC_PER_MSEC, ioTimeoutNanoseconds)
    }

    var currentEndpoint: AutomationEndpointDiscovery? {
        stateLock.withLock { endpoint }
    }

    var activeConnectionCount: Int {
        stateLock.withLock { activeClientDescriptors.count }
    }

    @MainActor
    func start(
        model: AppModel,
        updater: ApplicationUpdater,
        showWindow: @escaping AutomationCommandGateway.ShowWindow
    ) throws {
        stateLock.lock()
        let isRunning = listeningDescriptor >= 0
        stateLock.unlock()
        guard !isRunning else { return }

        let gateway = AutomationCommandGateway(
            model: model,
            updater: updater,
            authorizationStore: try AutomationAuthorizationStore(
                directory: discoveryDirectory ?? AutomationDiscovery.defaultDirectory(),
                storage: authorizationStorage
            ),
            showWindow: showWindow
        )
        let created = try Self.createEndpoint(baseDirectory: socketBaseDirectory)
        stateLock.lock()
        self.gateway = gateway
        listeningDescriptor = created.descriptor
        endpoint = created.discovery
        stateLock.unlock()

        do {
            try Self.publish(created.discovery, directory: discoveryDirectory)
        } catch {
            stop()
            throw error
        }
        acceptQueue.async { [weak self] in self?.acceptConnections() }
    }

    func stop() {
        stateLock.lock()
        let descriptor = listeningDescriptor
        listeningDescriptor = -1
        let previousEndpoint = endpoint
        let activeClients = Array(activeClientDescriptors)
        endpoint = nil
        gateway = nil
        stateLock.unlock()

        if descriptor >= 0 {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
        activeClients.forEach { Darwin.shutdown($0, SHUT_RDWR) }
        guard let previousEndpoint else { return }
        Self.removeDiscoveryIfOwned(previousEndpoint, directory: discoveryDirectory)
        Self.removeSocketIfOwned(previousEndpoint.socketPath)
    }

    deinit {
        stop()
    }

    private func acceptConnections() {
        while true {
            stateLock.lock()
            let descriptor = listeningDescriptor
            stateLock.unlock()
            guard descriptor >= 0 else { return }

            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                stateLock.lock()
                let stillRunning = listeningDescriptor >= 0
                stateLock.unlock()
                if stillRunning { continue }
                return
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            guard clientLimit.wait(timeout: .now()) == .success else {
                Darwin.close(client)
                continue
            }
            clientQueue.async { [weak self] in
                guard let self else {
                    Darwin.close(client)
                    return
                }
                let shouldServe = self.stateLock.withLock { () -> Bool in
                    guard self.listeningDescriptor >= 0 else { return false }
                    self.activeClientDescriptors.insert(client)
                    return true
                }
                defer {
                    _ = self.stateLock.withLock {
                        self.activeClientDescriptors.remove(client)
                    }
                    Darwin.close(client)
                    self.clientLimit.signal()
                }
                guard shouldServe else { return }
                self.serve(client)
            }
        }
    }

    private func serve(_ descriptor: Int32) {
        var peerUID = uid_t.max
        var peerGID = gid_t.max
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0,
              peerUID == getuid(),
              let peer = Self.peerIdentity(descriptor: descriptor, userIdentifier: peerUID)
        else { return }

        var timeout = timeval(
            tv_sec: Int(ioTimeoutNanoseconds / NSEC_PER_SEC),
            tv_usec: Int32((ioTimeoutNanoseconds % NSEC_PER_SEC) / NSEC_PER_USEC)
        )
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0,
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else { return }
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { return }

        do {
            let deadline = DispatchTime.now().uptimeNanoseconds
                + ioTimeoutNanoseconds
            let header = try Self.readExactly(
                4,
                from: descriptor,
                deadline: deadline
            )
            let size = try AutomationFrameCodec.payloadLength(from: header)
            let payload = try Self.readExactly(
                size,
                from: descriptor,
                deadline: deadline
            )
            let request = try JSONDecoder.automation.decode(
                AutomationRPCRequest.self,
                from: payload
            )
            let response = waitForResponse(to: request, peer: peer)
            var responsePayload = try JSONEncoder.automation.encode(response)
            if responsePayload.count > MClashAutomationProtocol.maximumFrameSize {
                responsePayload = try JSONEncoder.automation.encode(
                    AutomationRPCResponse(
                        id: request.id,
                        error: AutomationRPCError(
                            code: -32050,
                            type: "response_too_large",
                            message: "The response exceeds the 1 MiB protocol limit; request a smaller page"
                        )
                    )
                )
            }
            try Self.writeAll(
                try AutomationFrameCodec.encode(responsePayload),
                to: descriptor,
                deadline: DispatchTime.now().uptimeNanoseconds
                    + ioTimeoutNanoseconds
            )
        } catch {
            let fallback = AutomationRPCResponse(
                id: "invalid-request",
                error: AutomationRPCError(
                    code: -32700,
                    type: "parse_error",
                    message: error.localizedDescription
                )
            )
            if let payload = try? JSONEncoder.automation.encode(fallback),
               let frame = try? AutomationFrameCodec.encode(payload) {
                try? Self.writeAll(
                    frame,
                    to: descriptor,
                    deadline: DispatchTime.now().uptimeNanoseconds
                        + ioTimeoutNanoseconds
                )
            }
        }
    }

    private func waitForResponse(
        to request: AutomationRPCRequest,
        peer: AutomationPeerIdentity
    ) -> AutomationRPCResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        Task { @MainActor [weak self] in
            let gateway = self?.stateLock.withLock { self?.gateway }
            if let gateway {
                box.response = await gateway.execute(request, peer: peer)
            } else {
                box.response = AutomationRPCResponse(
                    id: request.id,
                    error: AutomationRPCError(
                        code: -32000,
                        type: "server_stopping",
                        message: "MClash is stopping",
                        retryable: true
                    )
                )
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 300) == .success,
              let response = box.response else {
            return AutomationRPCResponse(
                id: request.id,
                    error: AutomationRPCError(
                        code: -32001,
                        type: "operation_timeout",
                        message: "The MClash operation is still running or its outcome is indeterminate; query the same execution with the same request id",
                        retryable: true,
                        data: .object([
                            "outcomeIndeterminate": .bool(true),
                            "retryWithSameRequestID": .bool(true),
                        ])
                    )
                )
        }
        return response
    }

    private static func createEndpoint(baseDirectory explicitDirectory: URL?) throws -> (
        descriptor: Int32,
        discovery: AutomationEndpointDiscovery
    ) {
        let nonce = UUID().uuidString.lowercased()
        let baseDirectory = explicitDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("mclash-\(getuid())", isDirectory: true)
        try createPrivateDirectory(baseDirectory)
        let socketURL = baseDirectory.appendingPathComponent(
            "control-\(nonce.prefix(12)).sock",
            isDirectory: false
        )
        guard socketURL.path.utf8CString.count <= MemoryLayout<sockaddr_un>.size - 2 else {
            throw ServerError.socketPathTooLong(socketURL.path)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServerError.systemCall("socket", errno) }
        do {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw ServerError.systemCall("fcntl", errno)
            }
            var noSignal: Int32 = 1
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw ServerError.systemCall("setsockopt", errno)
            }
            try withSocketAddress(socketURL.path) { address, length in
                var address = address
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(descriptor, $0, length)
                    }
                }
                guard result == 0 else { throw ServerError.systemCall("bind", errno) }
            }
            guard chmod(socketURL.path, 0o600) == 0 else {
                throw ServerError.systemCall("chmod", errno)
            }
            guard Darwin.listen(descriptor, 16) == 0 else {
                throw ServerError.systemCall("listen", errno)
            }
            let version = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "development"
            return (
                descriptor,
                AutomationEndpointDiscovery(
                    processIdentifier: getpid(),
                    socketPath: socketURL.path,
                    nonce: nonce,
                    appVersion: version
                )
            )
        } catch {
            Darwin.close(descriptor)
            removeSocketIfOwned(socketURL.path)
            throw error
        }
    }

    private static func publish(
        _ discovery: AutomationEndpointDiscovery,
        directory explicitDirectory: URL?
    ) throws {
        let directory = try explicitDirectory ?? AutomationDiscovery.defaultDirectory()
        try createPrivateDirectory(directory)
        let destination = directory.appendingPathComponent(
            MClashAutomationProtocol.discoveryFileName
        )
        var existingMetadata = stat()
        if lstat(destination.path, &existingMetadata) == 0 {
            guard (existingMetadata.st_mode & S_IFMT) == S_IFREG,
                  existingMetadata.st_uid == getuid() else {
                throw ServerError.insecurePath(destination.path)
            }
            if let existing = try? AutomationDiscovery.load(from: destination),
               existing.processIdentifier != getpid(),
               kill(existing.processIdentifier, 0) == 0 {
                throw ServerError.serverAlreadyRunning(existing.processIdentifier)
            }
        } else if errno != ENOENT {
            throw ServerError.systemCall("lstat", errno)
        }
        let temporary = directory.appendingPathComponent(
            ".endpoint-\(discovery.nonce).tmp"
        )
        let data = try JSONEncoder.automation.encode(discovery)
        try data.write(to: temporary, options: .withoutOverwriting)
        guard chmod(temporary.path, 0o600) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw ServerError.systemCall("chmod", errno)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: temporary,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        guard chmod(destination.path, 0o600) == 0 else {
            throw ServerError.systemCall("chmod", errno)
        }
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 {
            guard (metadata.st_mode & S_IFMT) == S_IFDIR,
                  metadata.st_uid == getuid() else {
                throw ServerError.insecurePath(url.path)
            }
        } else if errno == ENOENT {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } else {
            throw ServerError.systemCall("lstat", errno)
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw ServerError.systemCall("chmod", errno)
        }
    }

    private static func removeDiscoveryIfOwned(
        _ expected: AutomationEndpointDiscovery,
        directory explicitDirectory: URL?
    ) {
        let url: URL?
        if let explicitDirectory {
            url = explicitDirectory.appendingPathComponent(
                MClashAutomationProtocol.discoveryFileName
            )
        } else {
            url = try? AutomationDiscovery.defaultFileURL()
        }
        guard let url,
              let current = try? AutomationDiscovery.load(from: url),
              current.nonce == expected.nonce else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func removeSocketIfOwned(_ path: String) {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFSOCK,
              metadata.st_uid == getuid() else { return }
        _ = unlink(path)
    }

    private static func withSocketAddress<Result>(
        _ path: String,
        _ body: (sockaddr_un, socklen_t) throws -> Result
    ) throws -> Result {
        let bytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw ServerError.socketPathTooLong(path)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { source in
            _ = strlcpy(&address.sun_path.0, source, MemoryLayout.size(ofValue: address.sun_path))
        }
        return try body(
            address,
            socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        )
    }

    private static func writeAll(
        _ data: Data,
        to descriptor: Int32,
        deadline: UInt64
    ) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw ServerError.deadlineExceeded }
                let remainingMilliseconds = max(
                    1,
                    min(
                        UInt64(Int32.max),
                        (deadline - now + NSEC_PER_MSEC - 1) / NSEC_PER_MSEC
                    )
                )
                var pollDescriptor = pollfd(
                    fd: descriptor,
                    events: Int16(POLLOUT),
                    revents: 0
                )
                let pollResult = poll(
                    &pollDescriptor,
                    1,
                    Int32(remainingMilliseconds)
                )
                if pollResult < 0, errno == EINTR { continue }
                guard pollResult > 0 else {
                    if pollResult == 0 { throw ServerError.deadlineExceeded }
                    throw ServerError.systemCall("poll", errno)
                }
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ServerError.systemCall("write", errno) }
                offset += count
            }
        }
    }

    private static func readExactly(
        _ count: Int,
        from descriptor: Int32,
        deadline: UInt64
    ) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < count {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { throw ServerError.deadlineExceeded }
                let remainingMilliseconds = max(
                    1,
                    min(
                        UInt64(Int32.max),
                        (deadline - now + NSEC_PER_MSEC - 1) / NSEC_PER_MSEC
                    )
                )
                var pollDescriptor = pollfd(
                    fd: descriptor,
                    events: Int16(POLLIN),
                    revents: 0
                )
                let pollResult = poll(
                    &pollDescriptor,
                    1,
                    Int32(remainingMilliseconds)
                )
                if pollResult < 0, errno == EINTR { continue }
                guard pollResult > 0 else {
                    if pollResult == 0 { throw ServerError.deadlineExceeded }
                    throw ServerError.systemCall("poll", errno)
                }
                let received = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    count - offset
                )
                if received < 0, errno == EINTR { continue }
                guard received > 0 else {
                    if received == 0 { throw ServerError.connectionClosed }
                    throw ServerError.systemCall("read", errno)
                }
                offset += received
            }
        }
        return data
    }

    private static func peerIdentity(
        descriptor: Int32,
        userIdentifier: uid_t
    ) -> AutomationPeerIdentity? {
        var processIdentifier = pid_t(0)
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &processIdentifier,
            &length
        ) == 0, processIdentifier > 0 else { return nil }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = proc_pidpath(
            processIdentifier,
            &pathBuffer,
            UInt32(pathBuffer.count)
        )
        guard pathLength > 0 else { return nil }
        let pathBytes = pathBuffer.prefix(Int(pathLength)).prefix { $0 != 0 }
        let executablePath = String(
            decoding: pathBytes.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let signature = codeIdentity(processIdentifier: processIdentifier)
        return AutomationPeerIdentity(
            processIdentifier: processIdentifier,
            userIdentifier: userIdentifier,
            executablePath: executablePath,
            signingIdentifier: signature.identifier,
            teamIdentifier: signature.teamIdentifier,
            codeHash: signature.codeHash
        )
    }

    private static func codeIdentity(
        processIdentifier: pid_t
    ) -> (identifier: String?, teamIdentifier: String?, codeHash: String?) {
        let attributes = [kSecGuestAttributePid as String: processIdentifier] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return (nil, nil, nil) }
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else {
            return (nil, nil, nil)
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return (nil, nil, nil) }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [String: Any] else { return (nil, nil, nil) }
        let codeHash = (values[kSecCodeInfoUnique as String] as? Data)?
            .map { String(format: "%02x", $0) }
            .joined()
        return (
            values[kSecCodeInfoIdentifier as String] as? String,
            values[kSecCodeInfoTeamIdentifier as String] as? String,
            codeHash
        )
    }
}

private final class ResponseBox: @unchecked Sendable {
    var response: AutomationRPCResponse?
}

private enum ServerError: Error, LocalizedError {
    case socketPathTooLong(String)
    case insecurePath(String)
    case connectionClosed
    case deadlineExceeded
    case serverAlreadyRunning(Int32)
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .socketPathTooLong(path): "Automation socket path is too long: \(path)"
        case let .insecurePath(path): "Automation refused an insecure path: \(path)"
        case .connectionClosed: "Automation client closed the connection"
        case .deadlineExceeded: "Automation request deadline exceeded"
        case let .serverAlreadyRunning(processIdentifier):
            "Another MClash automation server is already running (PID \(processIdentifier))"
        case let .systemCall(name, code):
            "Automation \(name) failed: \(String(cString: strerror(code)))"
        }
    }
}
