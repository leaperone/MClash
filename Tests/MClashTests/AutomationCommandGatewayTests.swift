import Foundation
import MClashAutomationProtocol
@testable import MClashApp
import Testing

@Suite("Automation command gateway")
@MainActor
struct AutomationCommandGatewayTests {
    @Test("Capabilities preserve enums and reject unknown or oversized input")
    func capabilitiesAndStrictEnvelope() async throws {
        let fixture = try makeFixture(scopes: [.readBasic])
        let response = await fixture.gateway.execute(
            AutomationRPCRequest(method: "system.capabilities"),
            peer: fixture.peer
        )
        guard case let .array(capabilities)? = response.result,
              let show = capabilities.first(where: {
                  $0.objectValue?["method"]?.stringValue == "app.ui.show"
              }),
              case let .object(parameters)? = show.objectValue?["parameters"] else {
            Issue.record("Expected app.ui.show capability metadata")
            return
        }
        #expect(parameters["destination"]?.stringValue?.contains("overview|") == true)

        let unknown = await fixture.gateway.execute(
            AutomationRPCRequest(
                method: "system.capabilities",
                params: ["surprise": .bool(true)]
            ),
            peer: fixture.peer
        )
        #expect(unknown.error?.type == "invalid_parameters")

        let oversized = await fixture.gateway.execute(
            AutomationRPCRequest(
                id: String(repeating: "x", count: 129),
                method: "system.capabilities"
            ),
            peer: fixture.peer
        )
        #expect(oversized.error?.type == "invalid_request")
    }

    @Test("Pagination rejects invalid ranges")
    func strictPagination() async throws {
        let fixture = try makeFixture(scopes: [.readSensitive])
        let response = await fixture.gateway.execute(
            AutomationRPCRequest(
                method: "providers.list",
                params: ["limit": .integer(0)],
                authorization: fixture.token
            ),
            peer: fixture.peer
        )
        #expect(response.error?.type == "invalid_parameters")

        let profiles = await fixture.gateway.execute(
            AutomationRPCRequest(
                method: "profiles.list",
                params: ["limit": .integer(0)],
                authorization: fixture.token
            ),
            peer: fixture.peer
        )
        #expect(profiles.error?.type == "invalid_parameters")
    }

    @Test("Unsigned clients are rejected before any pairing UI")
    func unsignedPairingIsRejected() async throws {
        let fixture = try makeFixture(scopes: [.readBasic])
        let unsigned = AutomationPeerIdentity(
            processIdentifier: 77,
            userIdentifier: getuid(),
            executablePath: "/tmp/unsigned-agent",
            signingIdentifier: nil,
            teamIdentifier: nil,
            codeHash: nil
        )
        let response = await fixture.gateway.execute(
            AutomationRPCRequest(
                method: "auth.pair",
                params: [
                    "name": .string("Unsigned Agent"),
                    "scopes": .array([.string("read.basic")]),
                ]
            ),
            peer: unsigned
        )
        #expect(response.error?.type == "untrusted_client")
    }

    @Test("Mutation retries are idempotent and reject changed parameters")
    func mutationIdempotency() async throws {
        let defaultsName = "MClash.AutomationGatewayTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let fixture = try makeFixture(scopes: [.control], defaults: defaults)
        let request = AutomationRPCRequest(
            id: "stable-mutation-id",
            method: "settings.patch",
            params: ["autoConnectOnLaunch": .bool(false)],
            authorization: fixture.token
        )
        let first = await fixture.gateway.execute(request, peer: fixture.peer)
        #expect(first.error == nil)
        #expect(fixture.model.autoConnectOnLaunch == false)

        fixture.model.autoConnectOnLaunch = true
        let retry = await fixture.gateway.execute(request, peer: fixture.peer)
        #expect(retry == first)
        #expect(fixture.model.autoConnectOnLaunch == true)

        let changed = await fixture.gateway.execute(
            AutomationRPCRequest(
                id: request.id,
                method: request.method,
                params: ["autoConnectOnLaunch": .bool(true)],
                authorization: fixture.token
            ),
            peer: fixture.peer
        )
        #expect(changed.error?.type == "invalid_request")
    }

    @Test("Proxifier preview is bounded and does not mutate rules")
    func proxifierPreview() async throws {
        let fixture = try makeFixture(scopes: [.control])
        let xml = """
        <ProxifierProfile version="101" platform="MacOSX">
          <RuleList>
            <Rule enabled="true">
              <Name>Block Ads</Name>
              <Targets>ads.*</Targets>
              <Action type="Block"/>
            </Rule>
          </RuleList>
        </ProxifierProfile>
        """
        let before = fixture.model.networkCapturePreferences.snapshot
        let response = await fixture.gateway.execute(
            AutomationRPCRequest(
                method: "appRouting.proxifier.preview",
                params: [
                    "dataBase64": .string(Data(xml.utf8).base64EncodedString()),
                    "limit": .integer(10),
                ],
                authorization: fixture.token
            ),
            peer: fixture.peer
        )
        #expect(response.error == nil)
        #expect(fixture.model.networkCapturePreferences.snapshot == before)
    }

    @Test("Scope upgrades rotate tokens and retain only unexpired grants")
    func scopeUpgradeRotatesToken() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AutomationAuthorizationStore(
            directory: root,
            storage: .ephemeral
        )
        let original = AutomationPeerIdentity(
            processIdentifier: 10,
            userIdentifier: getuid(),
            executablePath: "/Applications/Agent.app/Contents/MacOS/Agent",
            signingIdentifier: "example.agent",
            teamIdentifier: "EXAMPLETEAM"
        )
        let first = try store.issue(
            name: "Agent",
            scopes: [.readBasic],
            peer: original
        )
        let moved = AutomationPeerIdentity(
            processIdentifier: 11,
            userIdentifier: getuid(),
            executablePath: "/Users/example/Agent.app/Contents/MacOS/Agent",
            signingIdentifier: "example.agent",
            teamIdentifier: "EXAMPLETEAM"
        )
        let upgraded = try store.issue(
            name: "Agent",
            scopes: [.control],
            peer: moved
        )
        #expect(store.list().count == 1)
        #expect(upgraded.client.id == first.client.id)
        #expect(upgraded.client.scopes == [.readBasic, .control])
        #expect(throws: AuthorizationError.self) {
            try store.authorize(
                token: first.token,
                requiredScope: .readBasic,
                peer: moved
            )
        }
        #expect(try store.authorize(
            token: upgraded.token,
            requiredScope: .readBasic,
            peer: moved
        ).id == upgraded.client.id)
    }

    private func makeFixture(
        scopes: Set<AutomationClientScope>,
        defaults: UserDefaults? = nil
    ) throws -> Fixture {
        let root = temporaryRoot()
        let model = AppModel(
            profileDirectoryLayout: ProfileDirectoryLayout(
                rootDirectory: root.appendingPathComponent("application")
            ),
            preferenceDefaults: defaults ?? UserDefaults.standard
        )
        let store = try AutomationAuthorizationStore(
            directory: root.appendingPathComponent("authorization"),
            storage: .ephemeral
        )
        let peer = AutomationPeerIdentity(
            processIdentifier: 42,
            userIdentifier: getuid(),
            executablePath: "/Applications/TestAgent.app/Contents/MacOS/TestAgent",
            signingIdentifier: "example.test-agent",
            teamIdentifier: "EXAMPLETEAM"
        )
        let issued = try store.issue(name: "Test Agent", scopes: scopes, peer: peer)
        let gateway = AutomationCommandGateway(
            model: model,
            updater: ApplicationUpdater(startingUpdater: false),
            authorizationStore: store
        ) { _ in }
        return Fixture(
            root: root,
            model: model,
            gateway: gateway,
            peer: peer,
            token: issued.token
        )
    }

    private func temporaryRoot() -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "mcag-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let model: AppModel
    let gateway: AutomationCommandGateway
    let peer: AutomationPeerIdentity
    let token: String

    init(
        root: URL,
        model: AppModel,
        gateway: AutomationCommandGateway,
        peer: AutomationPeerIdentity,
        token: String
    ) {
        self.root = root
        self.model = model
        self.gateway = gateway
        self.peer = peer
        self.token = token
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
