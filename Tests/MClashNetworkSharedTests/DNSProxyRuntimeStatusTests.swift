import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("DNS proxy bootstrap and runtime status")
struct DNSProxyRuntimeStatusTests {
    @Test("Versioned bootstrap survives a Foundation property-list bridge")
    func bootstrapPropertyListRoundTrip() throws {
        let activationIdentifier = UUID(
            uuidString: "11111111-2222-3333-4444-555555555555"
        )!
        let profileRulesEndpoint = try MihomoRouteProxyEndpoint(
            route: .profileRules,
            host: "127.0.0.1",
            port: 17_891,
            username: "provider",
            password: "private-secret"
        )
        let routingProfileID = RoutingProfileID(
            UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )
        let profileEndpoint = try MihomoRouteProxyEndpoint(
            route: .profile(routingProfileID, target: .rules),
            host: "127.0.0.1",
            port: 17_892,
            username: "provider",
            password: "private-secret"
        )
        let bootstrap = try DNSProxyBootstrapConfiguration(
            revision: 42,
            activationIdentifier: activationIdentifier,
            profileRulesProxy: profileRulesEndpoint,
            routeProxyEndpoints: [profileRulesEndpoint, profileEndpoint],
            encodedCaptureSnapshot: Data("snapshot".utf8)
        )
        let encoded = try bootstrap.encoded()
        let propertyList = try PropertyListSerialization.data(
            fromPropertyList: ["dnsProxyBootstrap": encoded as NSData],
            format: .binary,
            options: 0
        )
        let bridged = try #require(
            PropertyListSerialization.propertyList(
                from: propertyList,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        let bridgedData = try #require(bridged["dnsProxyBootstrap"] as? Data)

        #expect(try DNSProxyBootstrapConfiguration.decode(bridgedData) == bootstrap)
        #expect(bootstrap.routeProxyEndpoints?.last?.route == profileEndpoint.route)
        #expect(bootstrap.encodedCaptureSnapshot == Data("snapshot".utf8))
    }

    @Test("Bootstrap rejects invalid identity, route, schema, and size")
    func bootstrapValidation() throws {
        let profileEndpoint = try MihomoRouteProxyEndpoint(
            route: .profileRules,
            host: "127.0.0.1",
            port: 53
        )
        #expect(
            throws: DNSProxyBootstrapConfigurationError.invalidRevision(0)
        ) {
            _ = try DNSProxyBootstrapConfiguration(
                revision: 0,
                activationIdentifier: UUID(),
                profileRulesProxy: profileEndpoint
            )
        }

        let globalEndpoint = try MihomoRouteProxyEndpoint(
            route: .global,
            host: "127.0.0.1",
            port: 53
        )
        #expect(
            throws: DNSProxyBootstrapConfigurationError.invalidProfileRulesRoute
        ) {
            _ = try DNSProxyBootstrapConfiguration(
                revision: 1,
                activationIdentifier: UUID(),
                profileRulesProxy: globalEndpoint
            )
        }

        let valid = try DNSProxyBootstrapConfiguration(
            revision: 1,
            activationIdentifier: UUID(),
            profileRulesProxy: profileEndpoint
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: valid.encoded()) as? [String: Any]
        )
        object["schemaVersion"] = 99
        let unsupported = try JSONSerialization.data(withJSONObject: object)
        #expect(
            throws: DNSProxyBootstrapConfigurationError.unsupportedSchemaVersion(99)
        ) {
            _ = try DNSProxyBootstrapConfiguration.decode(unsupported)
        }

        let oversized = Data(
            repeating: 0,
            count: DNSProxyBootstrapConfiguration.maximumEncodedSize + 1
        )
        #expect(
            throws: DNSProxyBootstrapConfigurationError.encodedPayloadTooLarge(
                actual: oversized.count,
                maximum: DNSProxyBootstrapConfiguration.maximumEncodedSize
            )
        ) {
            _ = try DNSProxyBootstrapConfiguration.decode(oversized)
        }
    }

    @Test("Bootstrap capacity includes a full capture snapshot after base64 expansion")
    func bootstrapCarriesLargeCaptureSnapshot() throws {
        let profileEndpoint = try MihomoRouteProxyEndpoint(
            route: .profileRules,
            host: "127.0.0.1",
            port: 17_891
        )
        let snapshot = Data(repeating: 0x5a, count: 512 * 1_024)
        let bootstrap = try DNSProxyBootstrapConfiguration(
            revision: 1,
            activationIdentifier: UUID(),
            profileRulesProxy: profileEndpoint,
            encodedCaptureSnapshot: snapshot
        )

        let encoded = try bootstrap.encoded()
        #expect(encoded.count > 512 * 1_024)
        #expect(
            try DNSProxyBootstrapConfiguration.decode(encoded)
                .encodedCaptureSnapshot == snapshot
        )
    }

    @Test("Host-staged bootstrap is authoritative across every delivery combination")
    func bootstrapResolutionMatrix() throws {
        let prepared = try DNSProxyBootstrapConfiguration(
            revision: 7,
            activationIdentifier: UUID(),
            profileRulesProxy: MihomoRouteProxyEndpoint(
                route: .profileRules,
                host: "127.0.0.1",
                port: 17_891
            )
        )
        let delivered = try DNSProxyBootstrapConfiguration(
            revision: 8,
            activationIdentifier: UUID(),
            profileRulesProxy: MihomoRouteProxyEndpoint(
                route: .profileRules,
                host: "127.0.0.1",
                port: 17_892
            )
        )

        #expect(
            try DNSProxyBootstrapConfiguration.resolve(
                prepared: prepared,
                delivered: prepared
            ) == prepared
        )
        #expect(
            try DNSProxyBootstrapConfiguration.resolve(
                prepared: prepared,
                delivered: nil
            ) == prepared
        )
        #expect(
            try DNSProxyBootstrapConfiguration.resolve(
                prepared: nil,
                delivered: delivered
            ) == delivered
        )
        #expect(
            throws: DNSProxyBootstrapResolutionError.deliveredBootstrapMismatch
        ) {
            _ = try DNSProxyBootstrapConfiguration.resolve(
                prepared: prepared,
                delivered: delivered
            )
        }
        #expect(throws: DNSProxyBootstrapResolutionError.bootstrapUnavailable) {
            _ = try DNSProxyBootstrapConfiguration.resolve(
                prepared: nil,
                delivered: nil
            )
        }
    }

    @Test("Runtime report is bounded, Codable, and contains no DNS questions or credentials")
    func runtimeReportRoundTrip() throws {
        let status = makeStatus()
        let report = DNSProxyRuntimeReport(
            expectedRevision: status.revision,
            expectedActivationIdentifier: status.activationIdentifier,
            status: status
        )
        let data = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(DNSProxyRuntimeReport.self, from: data) == report)

        let encoded = try #require(String(data: data, encoding: .utf8)).lowercased()
        for forbidden in [
            "hostname", "destination", "payload", "credential",
            "username", "password", "processidentifier",
        ] {
            #expect(!encoded.contains(forbidden))
        }
    }

    @Test("Startup failures remain activation-scoped and privacy-safe")
    func startupFailureReport() throws {
        let activationIdentifier = UUID()
        let failure = DNSProxyStartupFailure(
            reason: .invalidBootstrapPayload,
            observedAt: Date(timeIntervalSince1970: 10)
        )
        let report = DNSProxyRuntimeReport(
            expectedRevision: 8,
            expectedActivationIdentifier: activationIdentifier,
            startupFailure: failure
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(DNSProxyRuntimeReport.self, from: data)
        #expect(decoded == report)
        #expect(decoded.status == nil)
        #expect(decoded.startupFailure?.reason == .invalidBootstrapPayload)
    }

    @Test("Freshness accepts the boundary and rejects an older heartbeat")
    func heartbeatFreshness() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var status = makeStatus(startedAt: start, updatedAt: start)

        #expect(status.isFresh(at: start.addingTimeInterval(6), maximumAge: 6))
        #expect(!status.isFresh(at: start.addingTimeInterval(6.001), maximumAge: 6))
        #expect(!status.isFresh(at: start, maximumAge: -.infinity))

        let heartbeat = start.addingTimeInterval(2)
        status.recordHeartbeat(at: heartbeat)
        try status.validate(
            expectedRevision: status.revision,
            activationIdentifier: status.activationIdentifier,
            at: heartbeat.addingTimeInterval(6),
            maximumAge: 6
        )

        #expect(
            throws: DNSProxyRuntimeStatusValidationError.staleHeartbeat(
                updatedAt: heartbeat,
                evaluatedAt: heartbeat.addingTimeInterval(6.001),
                maximumAge: 6
            )
        ) {
            try status.validate(
                expectedRevision: status.revision,
                activationIdentifier: status.activationIdentifier,
                at: heartbeat.addingTimeInterval(6.001),
                maximumAge: 6
            )
        }
    }

    @Test("Revision and activation UUID must both match")
    func activationIdentityValidation() throws {
        let status = makeStatus()
        let otherActivation = UUID()

        #expect(
            throws: DNSProxyRuntimeStatusValidationError.revisionMismatch(
                expected: status.revision + 1,
                actual: status.revision
            )
        ) {
            try status.validate(
                expectedRevision: status.revision + 1,
                activationIdentifier: status.activationIdentifier
            )
        }
        #expect(
            throws: DNSProxyRuntimeStatusValidationError.activationMismatch(
                expected: otherActivation,
                actual: status.activationIdentifier
            )
        ) {
            try status.validate(
                expectedRevision: status.revision,
                activationIdentifier: otherActivation
            )
        }
    }

    @Test("Flow, lifecycle, and timestamp invariants reject corrupt snapshots")
    func statusInvariants() throws {
        var inconsistent = makeStatus()
        inconsistent.totalFlows = 1
        #expect(throws: DNSProxyRuntimeStatusValidationError.flowCountInvariantViolation) {
            try inconsistent.validate()
        }

        var missingFailure = makeStatus()
        missingFailure.backendReady = false
        missingFailure.lastFailureAt = nil
        missingFailure.failureCategory = nil
        #expect(throws: DNSProxyRuntimeStatusValidationError.missingFailureCategory) {
            try missingFailure.validate()
        }

        var terminalBackend = makeStatus()
        terminalBackend.phase = .stopped
        #expect(throws: DNSProxyRuntimeStatusValidationError.terminalPhaseBackendReady) {
            try terminalBackend.validate()
        }

        var badTimestamp = makeStatus()
        badTimestamp.updatedAt = badTimestamp.startedAt.addingTimeInterval(-1)
        #expect(throws: DNSProxyRuntimeStatusValidationError.updatedBeforeStart) {
            try badTimestamp.validate()
        }
    }

    private func makeStatus(
        startedAt: Date = Date(timeIntervalSince1970: 1_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_004)
    ) -> DNSProxyRuntimeStatus {
        let lastBackendAssociationAt = max(
            startedAt,
            updatedAt.addingTimeInterval(-1)
        )
        let lastFailureAt = max(
            startedAt,
            updatedAt.addingTimeInterval(-2)
        )
        return DNSProxyRuntimeStatus(
            revision: 42,
            activationIdentifier: UUID(
                uuidString: "11111111-2222-3333-4444-555555555555"
            )!,
            providerInstanceIdentifier: UUID(
                uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
            )!,
            phase: .running,
            backendReady: true,
            activeTCPFlows: 2,
            activeUDPFlows: 1,
            totalFlows: 8,
            completedFlows: 4,
            failedFlows: 1,
            uploadBytes: 1_024,
            downloadBytes: 2_048,
            startedAt: startedAt,
            updatedAt: updatedAt,
            lastBackendAssociationAt: lastBackendAssociationAt,
            lastQueryForwardedAt: lastBackendAssociationAt,
            lastResponseDeliveredAt: lastBackendAssociationAt,
            lastFailureAt: lastFailureAt,
            failureCategory: .tcpRelayFailed
        )
    }
}
