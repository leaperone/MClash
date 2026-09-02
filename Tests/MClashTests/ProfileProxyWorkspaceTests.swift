import Foundation
import Testing
@testable import MClashApp

@Suite("Profile-scoped proxy workspaces", .serialized)
struct ProfileProxyWorkspaceTests {
    @Test
    func projectionExposesConnectorNeutralNodeHealthAndSelection() throws {
        let collection = try Self.decodeCollection(
            group: "Auto",
            nodes: ["Healthy", "Offline"],
            selected: "Healthy",
            nodeDelay: 37
        )
        let projection = ProxyWorkspaceProjection(collection: collection)

        #expect(projection.nodes["Healthy"]?.isAlive == true)
        #expect(projection.nodes["Healthy"]?.latencyMilliseconds == 37)
        #expect(projection.nodes["Healthy"]?.id == "Healthy")
        #expect(projection.group(named: "Auto")?.memberIDs == ["Healthy", "Offline"])
        #expect(projection.group(named: "Auto")?.selectedMemberID == "Healthy")
        #expect(projection.group(named: "Auto")?.strategy == .selector)
        #expect(projection.group(named: "Auto")?.isAutomaticSelection == true)
    }

    @Test
    func snapshotBuildsProfileOrderedGroupsTopologyPathsAndDelays() throws {
        let profileID = ProfileID()
        let collection = try Self.decodeCollection(
            group: "Second",
            nodes: ["Node B"],
            selected: "Node B",
            nodeDelay: 88,
            additionalGroups: [
                ("First", ["Second"], "Second"),
            ]
        )
        let snapshot = ProfileProxyWorkspaceSnapshotBuilder().build(
            profileID: profileID,
            runtimeConfig: try Self.decodeConfig(mode: "rule", mixedPort: 17_891),
            collection: collection,
            profileStructure: ProfileStructure(
                groupOrder: ["First", "Second"],
                membersByGroup: [
                    "First": ["Second"],
                    "Second": ["Node B"],
                ]
            )
        )

        #expect(snapshot.profileID == profileID)
        #expect(snapshot.proxyGroups.map(\.name) == ["First", "Second"])
        #expect(snapshot.topology.groupOrder == ["First", "Second"])
        #expect(
            snapshot.selectionPaths["First"]?.route
                == ["First", "Second", "Node B"]
        )
        #expect(snapshot.selectionPaths["First"]?.terminal == "Node B")
        #expect(snapshot.delays["Node B"] == 88)
        #expect(snapshot.proxyGroups(forRoutingMode: "direct").isEmpty)
    }

    @MainActor
    @Test
    func closedAuxiliaryProfileIsUnavailableWithoutStartingAController() async {
        let profile = ProfileMetadata(name: "Closed", origin: .local)
        let model = makeTestAppModel()
        model.profiles = [profile]

        #expect(
            model.profileProxyWorkspaceState(for: profile.id)
                == .unavailable(.dedicatedPortDisabled(port: nil))
        )
        let refreshed = await model.refreshProxyWorkspace(for: profile.id)
        #expect(
            refreshed == .unavailable(.dedicatedPortDisabled(port: nil))
        )
    }

    @MainActor
    @Test
    func activeControllerCollectionRefreshesScopedSnapshot() throws {
        let profile = ProfileMetadata(name: "Default Source", origin: .local)
        let model = makeTestAppModel()
        model.profiles = [profile]
        model.activeProfileID = profile.id
        model.runtimeConfig = try Self.decodeConfig(
            mode: "rule",
            mixedPort: 17_890
        )

        model.applyProxyCollection(try Self.decodeCollection(
            group: "Auto",
            nodes: ["Healthy"],
            selected: "Healthy",
            nodeDelay: 41
        ))

        let snapshot = model.profileProxyWorkspaceState(
            for: profile.id
        ).snapshot
        #expect(snapshot?.proxiesByName["Auto"]?.now == "Healthy")
        #expect(snapshot?.delays["Healthy"] == 41)
    }

    @MainActor
    @Test
    func refreshAndSelectionRemainIsolatedForSameNamedGroups() async throws {
        ProfileWorkspaceURLProtocol.reset()
        defer { ProfileWorkspaceURLProtocol.reset() }

        let first = ProfileMetadata(name: "First", origin: .local)
        let second = ProfileMetadata(name: "Second", origin: .local)
        let fixture = ProfileWorkspaceControllerFixture(
            controllers: [
                19_101: .init(
                    nodes: ["First A", "First B"],
                    selected: "First A"
                ),
                19_102: .init(
                    nodes: ["Second A", "Second B"],
                    selected: "Second A"
                ),
            ]
        )
        ProfileWorkspaceURLProtocol.install { request in
            try fixture.response(for: request)
        }
        let clients: [ProfileID: MihomoAPIClient] = [
            first.id: try Self.makeClient(port: 19_101),
            second.id: try Self.makeClient(port: 19_102),
        ]
        let model = makeTestAppModel(
            profileProxyControllerResolver: { profileID in
                guard let client = clients[profileID] else {
                    return .unavailable(.profileNotFound)
                }
                return .available(client)
            }
        )
        model.profiles = [first, second]

        let firstState = await model.refreshProxyWorkspace(for: first.id)
        let secondState = await model.refreshProxyWorkspace(for: second.id)
        #expect(firstState.snapshot?.proxiesByName["Shared"]?.now == "First A")
        #expect(secondState.snapshot?.proxiesByName["Shared"]?.now == "Second A")

        let selected = await model.selectProxy(
            profileID: first.id,
            group: "Shared",
            proxy: "First B"
        )

        #expect(selected)
        #expect(
            model.profileProxyWorkspaceState(for: first.id)
                .snapshot?.proxiesByName["Shared"]?.now == "First B"
        )
        #expect(
            model.profileProxyWorkspaceState(for: second.id)
                .snapshot?.proxiesByName["Shared"]?.now == "Second A"
        )
        #expect(
            fixture.selectedNode(port: 19_102) == "Second A"
        )
    }

    private static func makeClient(port: Int) throws -> MihomoAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfileWorkspaceURLProtocol.self]
        return try MihomoAPIClient(
            baseURL: URL(string: "http://127.0.0.1:\(port)/api/")!,
            secret: "test",
            session: URLSession(configuration: configuration)
        )
    }

    fileprivate static func decodeConfig(
        mode: String,
        mixedPort: Int
    ) throws -> MihomoConfig {
        try JSONDecoder().decode(
            MihomoConfig.self,
            from: Data(
                """
                {
                  "port": 0,
                  "socks-port": 0,
                  "redir-port": 0,
                  "tproxy-port": 0,
                  "mixed-port": \(mixedPort),
                  "tun": {
                    "enable": false,
                    "device": "",
                    "stack": "Mixed",
                    "auto-route": false,
                    "auto-detect-interface": false
                  },
                  "allow-lan": false,
                  "bind-address": "127.0.0.1",
                  "mode": "\(mode)",
                  "unified-delay": true,
                  "log-level": "info",
                  "ipv6": false,
                  "interface-name": "",
                  "routing-mark": 0,
                  "tcp-concurrent": false,
                  "find-process-mode": "off",
                  "sniffing": false
                }
                """.utf8
            )
        )
    }

    fileprivate static func decodeCollection(
        group: String,
        nodes: [String],
        selected: String,
        nodeDelay: Int? = nil,
        additionalGroups: [(String, [String], String)] = []
    ) throws -> MihomoProxyCollection {
        var proxies: [String: Any] = [:]
        for node in nodes {
            var value: [String: Any] = [
                "name": node,
                "type": "Shadowsocks",
                "alive": true,
            ]
            if let nodeDelay {
                value["history"] = [["time": "now", "delay": nodeDelay]]
            }
            proxies[node] = value
        }
        proxies[group] = [
            "name": group,
            "type": "Selector",
            "all": nodes,
            "now": selected,
            "alive": true,
        ]
        for (name, members, now) in additionalGroups {
            proxies[name] = [
                "name": name,
                "type": "Selector",
                "all": members,
                "now": now,
                "alive": true,
            ]
        }
        return try JSONDecoder().decode(
            MihomoProxyCollection.self,
            from: JSONSerialization.data(withJSONObject: ["proxies": proxies])
        )
    }
}

private final class ProfileWorkspaceControllerFixture: @unchecked Sendable {
    struct Controller {
        let nodes: [String]
        var selected: String
    }

    private let lock = NSLock()
    private var controllers: [Int: Controller]

    init(controllers: [Int: Controller]) {
        self.controllers = controllers
    }

    func selectedNode(port: Int) -> String? {
        lock.withLock { controllers[port]?.selected }
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url,
              let port = url.port,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: request.httpMethod == "GET" ? 200 : 204,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            throw MihomoAPIError.invalidResponse
        }
        switch (request.httpMethod, url.path) {
        case ("GET"?, "/api/configs"):
            let config = try ProfileProxyWorkspaceTests.decodeConfig(
                mode: "rule",
                mixedPort: port
            )
            return (response, try JSONEncoder().encode(config))
        case ("GET"?, "/api/proxies"):
            let controller = try lock.withLock {
                guard let controller = controllers[port] else {
                    throw MihomoAPIError.invalidResponse
                }
                return controller
            }
            let collection = try ProfileProxyWorkspaceTests.decodeCollection(
                group: "Shared",
                nodes: controller.nodes,
                selected: controller.selected
            )
            return (response, try JSONEncoder().encode(collection))
        case ("PUT"?, "/api/proxies/Shared"):
            let body = request.httpBody ?? Data()
            let object = try JSONSerialization.jsonObject(with: body)
            guard let selection = object as? [String: String],
                  let name = selection["name"] else {
                throw MihomoAPIError.invalidResponse
            }
            try lock.withLock {
                guard var controller = controllers[port],
                      controller.nodes.contains(name) else {
                    throw MihomoAPIError.invalidResponse
                }
                controller.selected = name
                controllers[port] = controller
            }
            return (response, Data())
        case ("DELETE"?, "/api/connections"):
            return (response, Data())
        default:
            throw MihomoAPIError.invalidResponse
        }
    }
}

private final class ProfileWorkspaceURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    typealias Handler =
        @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func install(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    static func reset() {
        lock.withLock { handler = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let materializedRequest = Self.materializeBody(in: request)
        guard let handler = Self.lock.withLock({ Self.handler }) else {
            client?.urlProtocol(
                self,
                didFailWithError: MihomoAPIError.invalidResponse
            )
            return
        }
        do {
            let (response, data) = try handler(materializedRequest)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func materializeBody(
        in request: URLRequest
    ) -> URLRequest {
        guard request.httpBody == nil,
              let stream = request.httpBodyStream else {
            return request
        }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        var copy = request
        copy.httpBodyStream = nil
        copy.httpBody = body
        return copy
    }
}
