import Darwin
import Foundation
import MClashAutomationProtocol
@testable import MClashApp
import Testing

@Suite("Automation socket server")
@MainActor
struct AutomationSocketServerTests {
    @Test("Private socket serves capabilities without activating telemetry")
    func capabilityRoundTrip() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "mcas-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let socketDirectory = root.appendingPathComponent("socket", isDirectory: true)
        let discoveryDirectory = root.appendingPathComponent("discovery", isDirectory: true)
        let layout = ProfileDirectoryLayout(
            rootDirectory: root.appendingPathComponent("application", isDirectory: true)
        )
        let model = makeTestAppModel(profileDirectoryLayout: layout)
        let updater = ApplicationUpdater(startingUpdater: false)
        let server = AutomationSocketServer(
            socketBaseDirectory: socketDirectory,
            discoveryDirectory: discoveryDirectory,
            authorizationStorage: .ephemeral
        )
        try server.start(model: model, updater: updater) { _ in }
        defer { server.stop() }

        let endpoint = try #require(server.currentEndpoint)
        let response = try await Task.detached {
            try AutomationSocketClient(
                unsafeDevelopmentSocketPath: endpoint.socketPath
            ).send(
                AutomationRPCRequest(method: "system.capabilities")
            )
        }.value
        #expect(response.error == nil)
        guard case let .array(capabilities) = response.result else {
            Issue.record("Expected an array of capabilities")
            return
        }
        #expect(capabilities.count >= 60)
        #expect(model.presentationTelemetryPolicy == .init())

        let discoveryURL = discoveryDirectory.appendingPathComponent(
            MClashAutomationProtocol.discoveryFileName
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: discoveryURL.path
        )
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o077 == 0)
    }

    @Test("Unpaired clients cannot dispatch destructive commands")
    func destructiveCommandRequiresAuthentication() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "mcac-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let server = AutomationSocketServer(
            socketBaseDirectory: root.appendingPathComponent("socket"),
            discoveryDirectory: root.appendingPathComponent("discovery"),
            authorizationStorage: .ephemeral
        )
        let model = makeTestAppModel(
            profileDirectoryLayout: ProfileDirectoryLayout(
                rootDirectory: root.appendingPathComponent("application")
            )
        )
        try server.start(
            model: model,
            updater: ApplicationUpdater(startingUpdater: false)
        ) { _ in }
        defer { server.stop() }
        let endpoint = try #require(server.currentEndpoint)

        let response = try await Task.detached {
            try AutomationSocketClient(
                unsafeDevelopmentSocketPath: endpoint.socketPath
            ).send(
                AutomationRPCRequest(method: "traffic.history.clear")
            )
        }.value
        #expect(response.error?.type == "authentication_required")
    }

    @Test("Tokens are scoped, identity-bound, expiring, and revocable")
    func authorizationStoreLifecycle() throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "mcaa-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AutomationAuthorizationStore(
            directory: root,
            storage: .ephemeral
        )
        let peer = AutomationPeerIdentity(
            processIdentifier: 123,
            userIdentifier: getuid(),
            executablePath: "/usr/local/bin/example-client",
            signingIdentifier: nil,
            teamIdentifier: nil,
            codeHash: "test-client-hash"
        )
        let issued = try store.issue(
            name: "Test Client",
            scopes: [.readBasic],
            peer: peer
        )
        #expect(try store.authorize(
            token: issued.token,
            requiredScope: .readBasic,
            peer: peer
        ).id == issued.client.id)
        #expect(throws: AuthorizationError.self) {
            try store.authorize(
                token: issued.token,
                requiredScope: .control,
                peer: peer
            )
        }
        let changedPeer = AutomationPeerIdentity(
            processIdentifier: 124,
            userIdentifier: getuid(),
            executablePath: "/tmp/replaced-client",
            signingIdentifier: nil,
            teamIdentifier: nil,
            codeHash: "test-client-hash"
        )
        #expect(throws: AuthorizationError.self) {
            try store.authorize(
                token: issued.token,
                requiredScope: .readBasic,
                peer: changedPeer
            )
        }
        try store.revoke(id: issued.client.id)
        #expect(throws: AuthorizationError.self) {
            try store.authorize(
                token: issued.token,
                requiredScope: .readBasic,
                peer: peer
            )
        }
    }

    @Test("Slow frames time out and stop closes active clients")
    func slowFrameDeadlineAndStop() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "mcat-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let server = AutomationSocketServer(
            socketBaseDirectory: root.appendingPathComponent("socket"),
            discoveryDirectory: root.appendingPathComponent("discovery"),
            authorizationStorage: .ephemeral,
            ioTimeoutNanoseconds: 100 * NSEC_PER_MSEC
        )
        let model = makeTestAppModel(
            profileDirectoryLayout: ProfileDirectoryLayout(
                rootDirectory: root.appendingPathComponent("application")
            )
        )
        try server.start(
            model: model,
            updater: ApplicationUpdater(startingUpdater: false)
        ) { _ in }
        let endpoint = try #require(server.currentEndpoint)

        let slowClient = try connectUnixSocket(path: endpoint.socketPath)
        var singleByte: UInt8 = 0
        #expect(Darwin.write(slowClient, &singleByte, 1) == 1)
        try drainUntilClosed(slowClient)
        Darwin.close(slowClient)
        try await waitUntil { server.activeConnectionCount == 0 }
        server.stop()

        let stopServer = AutomationSocketServer(
            socketBaseDirectory: root.appendingPathComponent("stop-socket"),
            discoveryDirectory: root.appendingPathComponent("stop-discovery"),
            authorizationStorage: .ephemeral,
            ioTimeoutNanoseconds: 5 * NSEC_PER_SEC
        )
        try stopServer.start(
            model: model,
            updater: ApplicationUpdater(startingUpdater: false)
        ) { _ in }
        let stopEndpoint = try #require(stopServer.currentEndpoint)
        let stoppedClient = try connectUnixSocket(path: stopEndpoint.socketPath)
        try await waitUntil { stopServer.activeConnectionCount == 1 }
        stopServer.stop()
        try await waitUntil { stopServer.activeConnectionCount == 0 }
        try drainUntilClosed(stoppedClient)
        Darwin.close(stoppedClient)
    }
}

private enum SocketTestError: Error {
    case systemCall(String, Int32)
    case timedOut
    case unexpectedPayload
}

private func connectUnixSocket(path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw SocketTestError.systemCall("socket", errno) }
    do {
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw SocketTestError.systemCall("path", ENAMETOOLONG)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { source in
            _ = strlcpy(
                &address.sun_path.0,
                source,
                MemoryLayout.size(ofValue: address.sun_path)
            )
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard result == 0 else {
            throw SocketTestError.systemCall("connect", errno)
        }
        return descriptor
    } catch {
        Darwin.close(descriptor)
        throw error
    }
}

private func drainUntilClosed(_ descriptor: Int32) throws {
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
        throw SocketTestError.systemCall("fcntl", errno)
    }
    var buffer = [UInt8](repeating: 0, count: 4_096)
    for _ in 0..<200 {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { return }
        if count < 0, errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
            throw SocketTestError.systemCall("read", errno)
        }
        usleep(5_000)
    }
    throw SocketTestError.unexpectedPayload
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else { throw SocketTestError.timedOut }
        try await clock.sleep(for: .milliseconds(10))
    }
}
