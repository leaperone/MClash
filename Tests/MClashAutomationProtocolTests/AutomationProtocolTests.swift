import Darwin
import Foundation
@testable import MClashAutomationProtocol
import Testing

@Suite("MClash automation protocol")
struct AutomationProtocolTests {
    @Test("JSON-RPC request and response round-trip with stable API version")
    func rpcRoundTrip() throws {
        let request = AutomationRPCRequest(
            id: "request-1",
            method: "routing.mode.set",
            params: ["mode": .string("rule")],
            allowInteraction: true
        )
        let encoded = try JSONEncoder.automation.encode(request)
        let decoded = try JSONDecoder.automation.decode(
            AutomationRPCRequest.self,
            from: encoded
        )
        #expect(decoded == request)
        #expect(decoded.apiVersion == 1)

        let response = AutomationRPCResponse(
            id: request.id,
            result: .object(["accepted": .bool(true)])
        )
        #expect(try JSONDecoder.automation.decode(
            AutomationRPCResponse.self,
            from: JSONEncoder.automation.encode(response)
        ) == response)
    }

    @Test("Length-prefixed frames are deterministic and bounded")
    func frameCodec() throws {
        let payload = Data("hello".utf8)
        let frame = try AutomationFrameCodec.encode(payload)
        #expect(frame.prefix(4) == Data([0, 0, 0, 5]))
        #expect(try AutomationFrameCodec.payloadLength(from: Data(frame.prefix(4))) == 5)
        #expect(frame.dropFirst(4) == payload)

        let oversized = Data(count: MClashAutomationProtocol.maximumFrameSize + 1)
        #expect(throws: AutomationProtocolError.frameTooLarge(oversized.count)) {
            try AutomationFrameCodec.encode(oversized)
        }
        #expect(throws: AutomationProtocolError.invalidFrameHeader) {
            try AutomationFrameCodec.payloadLength(from: Data([0, 1]))
        }
    }

    @Test("JSON values preserve integers, arrays, and objects")
    func jsonValueRoundTrip() throws {
        let value = AutomationJSONValue.object([
            "negative": .integer(-12),
            "large": .unsignedInteger(UInt64.max),
            "array": .array([.bool(true), .null, .string("safe")]),
        ])
        let decoded = try JSONDecoder.automation.decode(
            AutomationJSONValue.self,
            from: JSONEncoder.automation.encode(value)
        )
        #expect(decoded == value)
    }

    @Test("Pairing trust choices have stable wire values")
    func clientTrustRoundTrip() throws {
        #expect(AutomationClientTrust.standard.rawValue == "standard")
        #expect(AutomationClientTrust.trusted.rawValue == "trusted")

        let encoded = try JSONEncoder.automation.encode(AutomationClientTrust.trusted)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"trusted\"")
        let decoded = try JSONDecoder.automation.decode(
            AutomationClientTrust.self,
            from: encoded
        )
        #expect(decoded.rawValue == AutomationClientTrust.trusted.rawValue)
    }

    @Test("Discovery rejects group-readable and symlink metadata")
    func discoveryPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mclash-automation-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpointURL = root.appendingPathComponent("endpoint.json")
        let endpoint = AutomationEndpointDiscovery(
            processIdentifier: getpid(),
            socketPath: "/tmp/mclash-test.sock",
            nonce: "test",
            appVersion: "test"
        )
        try JSONEncoder.automation.encode(endpoint).write(to: endpointURL)
        #expect(chmod(endpointURL.path, 0o600) == 0)
        let loaded = try AutomationDiscovery.load(
            from: endpointURL,
            validateEndpoint: false
        )
        #expect(loaded.apiVersion == endpoint.apiVersion)
        #expect(loaded.processIdentifier == endpoint.processIdentifier)
        #expect(loaded.socketPath == endpoint.socketPath)
        #expect(loaded.nonce == endpoint.nonce)
        #expect(loaded.appVersion == endpoint.appVersion)

        #expect(chmod(endpointURL.path, 0o644) == 0)
        #expect(throws: AutomationSocketError.self) {
            try AutomationDiscovery.load(from: endpointURL, validateEndpoint: false)
        }

        #expect(chmod(endpointURL.path, 0o600) == 0)
        let linkURL = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: endpointURL
        )
        #expect(throws: AutomationSocketError.self) {
            try AutomationDiscovery.load(from: linkURL, validateEndpoint: false)
        }

        let oversizedURL = root.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: 16 * 1_024 + 1).write(to: oversizedURL)
        #expect(chmod(oversizedURL.path, 0o600) == 0)
        #expect(throws: AutomationSocketError.self) {
            try AutomationDiscovery.load(from: oversizedURL, validateEndpoint: false)
        }
        #expect(throws: AutomationSocketError.self) {
            try AutomationDiscovery.decodeDiscoveryData(
                Data(repeating: 0x20, count: 16 * 1_024 + 1),
                sourcePath: oversizedURL.path
            )
        }
    }
}
