import Foundation
import MClashNetworkShared
@testable import MClashApp
import Testing

@Suite("Transparent proxy provider messages")
struct TransparentProxyProviderMessageClientTests {
    @Test("Runtime update quiesces before atomically applying snapshot and endpoint")
    func safeUpdateOrderAndPayload() async throws {
        let configuration = try runtimeConfiguration(revision: 8)
        let session = ScriptedProviderMessageSession(responses: [
            response(revision: 7, captureEnabled: true, failOpen: false),
            response(revision: 8, captureEnabled: false, failOpen: true),
            response(revision: 8, captureEnabled: true, failOpen: false),
            response(revision: 8, captureEnabled: true, failOpen: false),
        ])
        let status = try await TransparentProxyProviderMessageClient(
            session: session,
            timeout: .seconds(1)
        ).updateConfiguration(configuration)

        #expect(status.revision == 8)
        #expect(status.captureEnabled)
        #expect(!status.failOpen)
        let requests = try session.decodedRequests()
        #expect(requests.map(\.command) == [
            .status,
            .quiesce,
            .applyConfiguration,
            .status,
        ])
        #expect(requests.allSatisfy {
            $0.protocolVersion == TransparentProxyProviderControlRequest.currentProtocolVersion
        })
        #expect(requests[1].revision == 8)
        #expect(requests[1].captureEnabled == false)
        #expect(requests[1].failOpen == true)
        #expect(requests[2].captureConfigurationSnapshot == configuration.encodedCaptureSnapshot)
        #expect(requests[2].mihomoSOCKSHost == "127.0.0.1")
        #expect(requests[2].mihomoSOCKSPort == 7891)
        #expect(requests[2].mihomoSOCKSUsername == "provider")
        #expect(requests[2].mihomoSOCKSPassword == "secret")
    }

    @Test("Rejected and stale responses never count as applied")
    func validatesAcceptedAndRevision() async throws {
        let rejected = ScriptedProviderMessageSession(responses: [
            response(
                accepted: false,
                revision: 4,
                captureEnabled: false,
                failOpen: true,
                message: "stale"
            ),
        ])
        await #expect(throws: TransparentProxyProviderMessageError.rejected(
            command: .quiesce,
            message: "stale"
        )) {
            try await TransparentProxyProviderMessageClient(session: rejected)
                .quiesce(revision: 4)
        }

        let wrongRevision = ScriptedProviderMessageSession(responses: [
            response(revision: 3, captureEnabled: false, failOpen: true),
        ])
        await #expect(throws: TransparentProxyProviderMessageError.revisionMismatch(
            expected: 4,
            actual: 3
        )) {
            try await TransparentProxyProviderMessageClient(session: wrongRevision)
                .quiesce(revision: 4)
        }
    }

    @Test("Protocol version and provider identity are validated")
    func validatesProtocolAndProvider() async throws {
        let oldProtocol = ScriptedProviderMessageSession(responses: [
            response(protocolVersion: 0, revision: 1, captureEnabled: false, failOpen: true),
        ])
        await #expect(throws: TransparentProxyProviderMessageError.unsupportedProtocolVersion(
            expected: 1,
            actual: 0
        )) {
            try await TransparentProxyProviderMessageClient(session: oldProtocol).status()
        }

        let wrongProvider = ScriptedProviderMessageSession(responses: [
            response(
                provider: "dns-proxy",
                revision: 1,
                captureEnabled: false,
                failOpen: true
            ),
        ])
        await #expect(throws: TransparentProxyProviderMessageError.unexpectedProvider("dns-proxy")) {
            try await TransparentProxyProviderMessageClient(session: wrongProvider).status()
        }
    }

    @Test("A missing provider callback is bounded by the message timeout")
    func timeout() async {
        let session = NeverRespondingProviderMessageSession()
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: TransparentProxyProviderMessageError.timedOut) {
            try await TransparentProxyProviderMessageClient(
                session: session,
                timeout: .milliseconds(20)
            ).status()
        }
        #expect(started.duration(to: clock.now) < .seconds(1))
    }

    @Test("A stale host revision is rejected before quiescing")
    func hostRevisionMustAdvance() async throws {
        let session = ScriptedProviderMessageSession(responses: [
            response(revision: 8, captureEnabled: true, failOpen: false),
        ])
        await #expect(throws: TransparentProxyProviderMessageError.revisionDidNotAdvance(
            current: 8,
            proposed: 8
        )) {
            try await TransparentProxyProviderMessageClient(session: session)
                .updateConfiguration(try runtimeConfiguration(revision: 8))
        }
        #expect(try session.decodedRequests().map(\.command) == [.status])
    }

    private func runtimeConfiguration(
        revision: UInt64
    ) throws -> NetworkExtensionRuntimeConfiguration {
        let snapshot = try CaptureConfigurationSnapshot(
            revision: revision,
            rules: [try CaptureRule(
                id: "all",
                priority: 1,
                action: .mihomo(.profileRules)
            )]
        )
        let preferences = try NetworkCapturePreferences(
            enabled: true,
            dnsEnabled: false,
            failOpen: false,
            snapshot: snapshot
        )
        let authentication = try NetworkExtensionMihomoAuthentication(
            username: "provider",
            password: "secret"
        )
        return try NetworkExtensionRuntimeConfiguration(
            preferences: preferences,
            mihomoListener: NetworkExtensionMihomoListenerConfiguration(
                port: 7891,
                authentication: authentication
            )
        )
    }

    private func response(
        protocolVersion: Int = 1,
        accepted: Bool = true,
        provider: String = "transparent-proxy",
        revision: UInt64,
        captureEnabled: Bool,
        failOpen: Bool,
        message: String? = nil
    ) -> Data {
        let object: [String: Any?] = [
            "protocolVersion": protocolVersion,
            "accepted": accepted,
            "provider": provider,
            "revision": revision,
            "running": true,
            "captureEnabled": captureEnabled,
            "failOpen": failOpen,
            "message": message,
        ]
        return try! JSONSerialization.data(
            withJSONObject: object.compactMapValues { $0 }
        )
    }
}

private final class ScriptedProviderMessageSession:
    TransparentProxyProviderMessageSession,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var responses: [Data]
    private var messages: [Data] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    func sendProviderMessage(
        _ messageData: Data,
        responseHandler: @escaping @Sendable (Data?) -> Void
    ) throws {
        lock.lock()
        messages.append(messageData)
        let response = responses.isEmpty ? nil : responses.removeFirst()
        lock.unlock()
        responseHandler(response)
    }

    func decodedRequests() throws -> [TransparentProxyProviderControlRequest] {
        lock.lock()
        let messages = messages
        lock.unlock()
        return try messages.map {
            try JSONDecoder().decode(TransparentProxyProviderControlRequest.self, from: $0)
        }
    }
}

private struct NeverRespondingProviderMessageSession: TransparentProxyProviderMessageSession {
    func sendProviderMessage(
        _ messageData: Data,
        responseHandler: @escaping @Sendable (Data?) -> Void
    ) throws {}
}
