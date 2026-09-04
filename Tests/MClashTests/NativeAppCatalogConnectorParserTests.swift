import Foundation
@preconcurrency import Network
import MClashNetworkShared
import Testing
@testable import MClashApp

@Suite("Native app catalog response parsers")
struct NativeAppCatalogConnectorParserTests {
    @Test("App connector accepts only supported Shadowsocks TCP material")
    func shadowsocksCapabilityGate() throws {
        let target = try OutboundNodeTarget(protocolName: "ss", host: "127.0.0.1", port: 8388, parameters: ["method": "aes-256-gcm", "password": "secret"])
        #expect(NativeAppCatalogConnector.supports(target))
        let plugin = try OutboundNodeTarget(protocolName: "ss", host: "127.0.0.1", port: 8388, parameters: ["method": "aes-256-gcm", "password": "secret", "plugin": "obfs"])
        #expect(!NativeAppCatalogConnector.supports(plugin))
    }

    @Test("Shadowsocks SIP002 stream codec survives fragmented encrypted frames")
    func shadowsocksFragmentation() throws {
        let target = try OutboundNodeTarget(protocolName: "ss", host: "127.0.0.1", port: 8388, parameters: ["method": "aes-128-gcm", "password": "secret"])
        let destination = MClashInboundDestination(host: "example.com", port: 443)
        let client = try NativeAppShadowsocksCodec(target: target, destination: destination, routeKey: "test")
        let server = try NativeAppShadowsocksCodec(target: target, destination: destination, routeKey: "test")
        let encoded = try client.encode(Data("payload".utf8))
        var decoded = [Data]()
        for byte in encoded { decoded += try server.decode(Data([byte])) }
        #expect(decoded == [Data("payload".utf8)])
    }

    @Test("Same-route Shadowsocks connections retain exact codec identity")
    func shadowsocksConnectionIdentity() throws {
        let target = try OutboundNodeTarget(protocolName: "ss", host: "127.0.0.1", port: 8388, parameters: ["method": "aes-128-gcm", "password": "secret"])
        let destination = MClashInboundDestination(host: "example.com", port: 443)
        let first = try NativeAppShadowsocksCodec(target: target, destination: destination, routeKey: "same")
        let second = try NativeAppShadowsocksCodec(target: target, destination: destination, routeKey: "same")
        let state = NativeAppShadowsocksState()
        let c1 = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        let c2 = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        state.store(first, for: c1); state.store(second, for: c2)
        #expect(state.take(for: c2) === second)
        #expect(state.take(for: c1) === first)
    }

    @Test("HTTP CONNECT accepts fragmented headers and preserves coalesced payload")
    func httpFragmentationAndTrailingBytes() throws {
        var parser = NativeHTTPConnectResponseParser()
        #expect(try parser.append(Data("HTTP/1.1 200 Connection".utf8)) == nil)
        let parsed = try parser.append(Data(" Established\r\n\r\nhello".utf8))
        let result = try #require(parsed)
        #expect(result.status == 200)
        #expect(result.trailing == Data("hello".utf8))
    }

    @Test("HTTP parser rejects an oversized header but permits bounded trailing data")
    func httpBounds() throws {
        var parser = NativeHTTPConnectResponseParser()
        let header = Data("HTTP/1.1 200 OK\r\n\r\n".utf8)
        #expect(try parser.append(header + Data(repeating: 7, count: SOCKS5Limits.maximumStreamInputBytes - header.count))?.trailing.count == SOCKS5Limits.maximumStreamInputBytes - header.count)
        var oversized = NativeHTTPConnectResponseParser()
        #expect(throws: NativeAppCatalogConnectorError.truncatedResponse) {
            _ = try oversized.append(Data(repeating: 1, count: SOCKS5Limits.maximumStreamInputBytes + 1))
        }
    }

    @Test("SOCKS5 incremental decoders retain trailing bytes")
    func socksFragmentationAndTrailingBytes() throws {
        var method = SOCKS5MethodSelectionDecoder()
        #expect(try method.append(Data([5])) == nil)
        #expect(try method.append(Data([0, 9]))?.method == .noAuthenticationRequired)
        #expect(method.remainingData == Data([9]))

        var reply = SOCKS5CommandReplyDecoder()
        let frame = Data([5, 0, 0, 1, 192, 0, 2, 1, 0, 80])
        #expect(try reply.append(frame.prefix(3)) == nil)
        #expect(try reply.append(Data(frame.dropFirst(3)) + Data("payload".utf8)) != nil)
        #expect(reply.remainingData == Data("payload".utf8))
    }
}
