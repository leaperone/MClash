import Foundation
import MClashNetworkShared
import Testing
@testable import MClashNetworkExtension

@Suite("Outbound connector boundary")
struct OutboundConnectorTests {
    @Test("Direct and Reject are terminal MClash decisions")
    func terminalDecisionsNeverUseConnector() {
        #expect(!OutboundConnectorRoutingPolicy.requiresConnector(.direct))
        #expect(!OutboundConnectorRoutingPolicy.requiresConnector(.reject))
        #expect(!OutboundConnectorRoutingPolicy.requiresConnector(.failOpen))
    }

    @Test("A proxy decision is the only decision that uses a connector")
    func proxyDecisionUsesConnector() {
        #expect(OutboundConnectorRoutingPolicy.requiresConnector(.mihomo(.profileRules)))
        #expect(OutboundConnectorRoutingPolicy.requiresConnector(.mihomo(.global)))
        #expect(OutboundConnectorRoutingPolicy.requiresConnector(.mihomo(.group("AI"))))
    }

    @Test("Native SOCKS5 connector targets the node endpoint directly")
    func nativeSOCKS5ConnectorKeepsNodeEndpoint() throws {
        let target = try OutboundNodeTarget(
            protocolName: "socks5",
            host: "127.0.0.1",
            port: 19080
        )
        let connector = NativeSOCKS5OutboundConnector(target: target)
        let connection = connector.makeConnection()
        connection.cancel()
        #expect(target.protocolName == "socks5")
        #expect(target.port == 19080)
    }

    @Test("Shadowsocks AEAD TCP connector frames target and application bytes")
    func nativeShadowsocksConnectorFramesStream() throws {
        let target = try OutboundNodeTarget(
            protocolName: "shadowsocks", host: "node.example.com", port: 443,
            parameters: ["method": "aes-256-gcm", "password": "secret"]
        )
        let destination = try SOCKS5Endpoint(address: SOCKS5Address(domain: "example.com"), port: 443)
        let connector = NativeShadowsocksRelayConnector(target: target, destination: destination)
        let codec = try #require(connector.makeStreamCodec(for: destination))
        let targetFrame = try codec.encodeDestination()
        let appFrame = try codec.encode(Data("hello".utf8))
        var decoder = try ShadowsocksAEADStreamDecoder(methodName: "aes-256-gcm", password: "secret")
        let decoded = try decoder.append(targetFrame + appFrame)
        #expect(decoded.count == 2)
        #expect(decoded[1] == Data("hello".utf8))
        connector.makeConnection(to: nil).cancel()
    }

    @Test("Shadowsocks plugins stay on legacy fallback")
    func shadowsocksPluginIsNotNative() throws {
        let target = try OutboundNodeTarget(
            protocolName: "shadowsocks", host: "node.example.com", port: 443,
            parameters: ["method": "aes-256-gcm", "password": "secret", "plugin": "v2ray-plugin"]
        )
        #expect(NativeConnectorRegistry.capability(for: target) == .legacyFallback)
    }

    @Test("Native VLESS connector emits a destination handshake")
    func nativeVLESSConnectorHandshake() throws {
        let target = try OutboundNodeTarget(
            protocolName: "vless",
            host: "node.example.com",
            port: 443,
            parameters: [
                "uuid": "00000000-0000-0000-0000-000000000001",
                "tls": "true",
            ]
        )
        let connector = NativeVLESSOutboundConnector(target: target)
        let destination = try SOCKS5Endpoint(
            address: SOCKS5Address(domain: "example.com"),
            port: 443
        )
        let handshake = try connector.handshake(for: destination)
        #expect(handshake.first == 0x01)
        #expect(handshake.contains(0x02))
    }

    @Test("Native VLESS connector accepts WebSocket transport parameters")
    func nativeVLESSWebSocketConnectorBuilds() throws {
        let target = try OutboundNodeTarget(
            protocolName: "vless",
            host: "node.example.com",
            port: 443,
            parameters: [
                "uuid": "00000000-0000-0000-0000-000000000001",
                "tls": "true",
                "network": "ws",
                "ws-host": "cdn.example.com",
            ]
        )
        let connection = NativeVLESSOutboundConnector(target: target).makeConnection()
        connection.cancel()
        #expect(target.parameters["network"] == "ws")
    }

    @Test("Native Trojan connector emits TLS-backed authenticated handshake")
    func nativeTrojanConnectorHandshake() throws {
        let target = try OutboundNodeTarget(
            protocolName: "trojan",
            host: "node.example.com",
            port: 443,
            parameters: [
                "password": "password",
                "sni": "cdn.example.com",
            ]
        )
        let connector = NativeTrojanOutboundConnector(target: target)
        let destination = try SOCKS5Endpoint(
            address: SOCKS5Address(domain: "example.com"),
            port: 443
        )
        let handshake = try connector.handshake(for: destination)
        #expect(handshake.count > 58)
        #expect(String(decoding: handshake.prefix(58), as: UTF8.self)
            .hasSuffix("\r\n"))
        connector.makeConnection().cancel()
    }

    @Test("Native Hysteria2 connector bootstraps QUIC with HTTP/3 ALPN")
    func nativeHysteria2ConnectorBuilds() throws {
        let target = try OutboundNodeTarget(
            protocolName: "hysteria2",
            host: "node.example.com",
            port: 443,
            parameters: ["password": "secret", "sni": "node.example.com"]
        )
        let connection = NativeHysteria2OutboundConnector(target: target).makeConnection()
        connection.cancel()
        #expect(target.protocolName == "hysteria2")
    }

    @Test("Hysteria2 connector maps node auth and flow payloads")
    func nativeHysteria2ConnectorPayloads() throws {
        let target = try OutboundNodeTarget(
            protocolName: "hysteria2",
            host: "node.example.com",
            port: 443,
            parameters: ["password": "secret"]
        )
        let connector = NativeHysteria2OutboundConnector(target: target)
        #expect(try connector.authHeaders().contains { $0.0 == "Hysteria-Auth" && $0.1 == "secret" })
        let destination = try SOCKS5Endpoint(address: SOCKS5Address(domain: "example.com"), port: 443)
        #expect(try connector.tcpRequest(for: destination).count > 3)
        #expect(try connector.udpMessage(sessionID: 1, packetID: 1, destination: destination, payload: Data([1])).count > 10)
    }

    @Test("HTTP CONNECT connector emits a bounded authenticated request")
    func nativeHTTPConnectConnectorHandshake() throws {
        let target = try OutboundNodeTarget(
            protocolName: "http", host: "proxy.example.com", port: 8080,
            parameters: ["username": "alice", "password": "secret"]
        )
        let destination = try SOCKS5Endpoint(address: SOCKS5Address(domain: "example.com"), port: 443)
        let request = try NativeHTTPConnectOutboundConnector(target: target).handshake(for: destination)
        #expect(String(decoding: request, as: UTF8.self).contains("CONNECT example.com:443 HTTP/1.1"))
        #expect(String(decoding: request, as: UTF8.self).contains("Proxy-Authorization: Basic YWxpY2U6c2VjcmV0"))
        #expect(try NativeHTTPConnectOutboundConnector(target: target).validate(
            response: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
        ) == 200)
    }

    @Test("HTTP CONNECT remains compatibility fallback until response gate is wired")
    func httpConnectIsNotMisclassifiedAsNative() throws {
        let target = try OutboundNodeTarget(protocolName: "http", host: "proxy.example.com", port: 8080)
        #expect(NativeConnectorRegistry.supports(target))
        #expect(NativeConnectorRegistry.kind(for: target) == .http)
        #expect(!NativeConnectorRegistry.supportsNativeTCP(target))
        #expect(NativeConnectorRegistry.capability(for: target) == .legacyFallback)
    }

    @Test("Native connector registry rejects unknown subscription protocols")
    func registryRejectsUnknownProtocol() throws {
        let target = try OutboundNodeTarget(protocolName: "quic", host: "node.example.com", port: 443)
        #expect(!NativeConnectorRegistry.supports(target))
        #expect(throws: NativeConnectorRegistryError.unsupportedProtocol("quic")) {
            try NativeConnectorRegistry.validate(target)
        }
        #expect(NativeConnectorRegistry.capability(for: target) == .unsupported)
        #expect(NativeConnectorRegistry.kind(for: target) == nil)
    }

    @Test("Registry preserves protocol-specific connector kinds")
    func registryKinds() throws {
        for name in ["http", "socks5", "vless", "trojan", "hysteria2"] {
            let target = try OutboundNodeTarget(protocolName: name, host: "node.example.com", port: 443)
            #expect(NativeConnectorRegistry.kind(for: target)?.rawValue == name)
        }
    }

    @Test("Native TCP capability excludes unimplemented VLESS transports")
    func nativeTCPCapabilityIsTransportAware() throws {
        let plain = try OutboundNodeTarget(
            protocolName: "vless", host: "node.example.com", port: 443,
            parameters: ["uuid": "00000000-0000-0000-0000-000000000001"]
        )
        let websocket = try OutboundNodeTarget(
            protocolName: "vless", host: "node.example.com", port: 443,
            parameters: ["uuid": "00000000-0000-0000-0000-000000000001", "network": "ws"]
        )
        let reality = try OutboundNodeTarget(
            protocolName: "vless", host: "node.example.com", port: 443,
            parameters: ["uuid": "00000000-0000-0000-0000-000000000001", "reality": "true"]
        )

        #expect(NativeConnectorRegistry.supportsNativeTCP(plain))
        #expect(!NativeConnectorRegistry.supportsNativeTCP(websocket))
        #expect(!NativeConnectorRegistry.supportsNativeTCP(reality))
        #expect(NativeConnectorRegistry.capability(for: plain) == .native)
        #expect(NativeConnectorRegistry.capability(for: websocket) == .legacyFallback)
        #expect(NativeConnectorRegistry.capability(for: reality) == .legacyFallback)
    }

    @Test("Native VLESS excludes imported Reality and XTLS parameter shapes")
    func nativeVLESSRejectsImportedRealityAndXTLSShapes() throws {
        let importedReality = try OutboundNodeTarget(
            protocolName: "vless", host: "reality.example.com", port: 443,
            parameters: [
                "uuid": "00000000-0000-0000-0000-000000000001",
                "network": "tcp",
                "reality-opts": #"{"public-key":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","short-id":"01234567"}"#,
            ]
        )
        let importedVision = try OutboundNodeTarget(
            protocolName: "vless", host: "vision.example.com", port: 443,
            parameters: [
                "uuid": "00000000-0000-0000-0000-000000000001",
                "flow": "xtls-rprx-vision",
            ]
        )
        let flattenedReality = try OutboundNodeTarget(
            protocolName: "vless", host: "flattened.example.com", port: 443,
            parameters: [
                "uuid": "00000000-0000-0000-0000-000000000001",
                "security": "reality",
                "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                "short_id": "01234567",
            ]
        )

        for target in [importedReality, importedVision, flattenedReality] {
            #expect(!NativeConnectorRegistry.supportsNativeTCP(target))
            #expect(NativeConnectorRegistry.capability(for: target) == .legacyFallback)
        }
    }

    @Test("Factory descriptors preserve native protocol and target material")
    func registryDescriptor() throws {
        let target = try OutboundNodeTarget(protocolName: "vless", host: "node.example.com", port: 443)
        let descriptor = try NativeConnectorRegistry.descriptor(for: target)
        #expect(descriptor.kind == .vless)
        #expect(descriptor.target == target)
    }

    @Test("Factory emits protocol-specific TCP plans")
    func factoryPlans() throws {
        let destination = try SOCKS5Endpoint(address: SOCKS5Address(domain: "example.com"), port: 443)
        let target = try OutboundNodeTarget(
            protocolName: "vless",
            host: "node.example.com",
            port: 443,
            parameters: ["uuid": "00000000-0000-0000-0000-000000000001"]
        )
        let plan = try NativeConnectorFactory.makeTCPPlan(target: target, destination: destination)
        #expect(plan.initialPayload?.first == 0x01)
        #expect(!plan.usesSOCKS5Handshake)
        plan.connection.cancel()
    }
}
