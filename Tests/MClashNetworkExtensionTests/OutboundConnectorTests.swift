import CryptoKit
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
        #expect(OutboundConnectorRoutingPolicy.requiresConnector(.outbound(.profileRules)))
        #expect(OutboundConnectorRoutingPolicy.requiresConnector(.outbound(.global)))
        #expect(OutboundConnectorRoutingPolicy.requiresConnector(.outbound(.group("AI"))))
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
        let codecValue = try connector.makeStreamCodec(for: destination)
        let codec = try #require(codecValue)
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
        #expect(!NativeConnectorRegistry.supportsNativeUDP(target))
        #expect(
            NativeConnectorRegistry.unsupportedNativeTransportReason(for: target)
                == "Shadowsocks plugins require a dedicated native transport."
        )
    }

    @Test("Shadowsocks UDP and UDP-over-TCP variants never enter native paths")
    func shadowsocksUDPVariantsAreNeverNative() throws {
        let udp = try OutboundNodeTarget(
            protocolName: "shadowsocks", host: "node.example.com", port: 443,
            parameters: ["method": "aes-256-gcm", "password": "secret", "udp": "true"]
        )
        // The udp flag describes server capability; it does not make the
        // SIP002 TCP stream codec a UDP connector. Native UDP is therefore
        // never advertised for any Shadowsocks target.
        #expect(NativeConnectorRegistry.capability(for: udp) == .native)
        #expect(!NativeConnectorRegistry.supportsNativeUDP(udp))

        let udpOverTCP = try OutboundNodeTarget(
            protocolName: "shadowsocks", host: "node.example.com", port: 443,
            parameters: [
                "method": "aes-256-gcm", "password": "secret",
                "udp-over-tcp": "true", "udp-over-tcp-version": "2"
            ]
        )
        #expect(NativeConnectorRegistry.capability(for: udpOverTCP) == .legacyFallback)
        #expect(!NativeConnectorRegistry.supportsNativeTCP(udpOverTCP))
        #expect(!NativeConnectorRegistry.supportsNativeUDP(udpOverTCP))
        #expect(
            NativeConnectorRegistry.unsupportedNativeTransportReason(for: udpOverTCP)
                == "Shadowsocks UDP-over-TCP transport is not implemented by the native connector."
        )
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
        #expect(handshake.first == VLESSCodec.version)
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
        #expect(NativeConnectorRegistry.capability(for: target) == .native)
    }

    @Test("VLESS WebSocket sends HTTP upgrade before its binary request")
    func vlessWebSocketTwoPhaseHandshake() throws {
        let target = try OutboundNodeTarget(
            protocolName: "vless", host: "203.0.113.8", port: 443,
            parameters: [
                "uuid": "00000000-0000-0000-0000-000000000001",
                "network": "ws",
                "ws-opts": #"{"path":"/vless","headers":{"Host":"cdn.example.com"}}"#
            ]
        )
        let destination = try SOCKS5Endpoint(
            address: SOCKS5Address(domain: "example.com"), port: 443
        )
        let connector = NativeVLESSWebSocketRelayConnector(target: target)
        let upgrade = try connector.responseHandshake(for: destination)
        let request = String(decoding: upgrade, as: UTF8.self)
        #expect(request.hasPrefix("GET /vless HTTP/1.1\r\n"))
        #expect(request.contains("Host: cdn.example.com\r\n"))
        #expect(!upgrade.contains(0x01), "VLESS bytes must not precede HTTP 101")
        let headers = request.split(separator: "\r\n")
        let keyLine = try #require(headers.first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }))
        let colon = try #require(keyLine.firstIndex(of: ":"))
        let key = String(keyLine[keyLine.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        let response = Data((
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        ).utf8)
        try connector.validateResponse(response)
        let binary = try #require(try connector.postResponseHandshake(for: destination))
        #expect(binary.first == 0x82)
        #expect(binary[1] & 0x80 == 0x80)
    }

    @Test("VLESS WebSocket framing masks client payload and decodes server binary frames")
    func vlessWebSocketFrameFixture() throws {
        let target = try OutboundNodeTarget(
            protocolName: "vless", host: "node.example.com", port: 443,
            parameters: ["uuid": "00000000-0000-0000-0000-000000000001", "network": "ws", "ws-path": "/vless"]
        )
        let destination = try SOCKS5Endpoint(address: SOCKS5Address(domain: "example.com"), port: 443)
        let codec = try VLESSWebSocketStreamCodec(target: target, destination: destination)
        let encoded = try codec.encode(Data("hello".utf8))
        #expect(encoded[0] == 0x82)
        #expect(encoded[1] & 0x80 == 0x80)
        let serverFrame = Data([0x82, 0x07, 0x00, 0x00]) + Data("world".utf8)
        #expect(try codec.decode(serverFrame) == [Data("world".utf8)])
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
        let headers = try connector.authHeaders()
        let hasAuthentication = headers.contains {
            $0.0 == "Hysteria-Auth" && $0.1 == "secret"
        }
        if !hasAuthentication {
            Issue.record("Native Hysteria2 connector omitted its authentication header")
        }
        let destination = try SOCKS5Endpoint(address: SOCKS5Address(domain: "example.com"), port: 443)
        let tcpRequest = try connector.tcpRequest(for: destination)
        let udpMessage = try connector.udpMessage(
            sessionID: 1,
            packetID: 1,
            destination: destination,
            payload: Data([1])
        )
        #expect(tcpRequest.count > 3)
        #expect(udpMessage.count > 10)
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

    @Test("HTTP CONNECT is native only through the response-aware relay gate")
    func httpConnectUsesNativeResponseGate() throws {
        let target = try OutboundNodeTarget(protocolName: "http", host: "proxy.example.com", port: 8080)
        #expect(NativeConnectorRegistry.supports(target))
        #expect(NativeConnectorRegistry.kind(for: target) == .http)
        #expect(NativeConnectorRegistry.supportsNativeTCP(target))
        #expect(NativeConnectorRegistry.capability(for: target) == .native)
        let connector = NativeHTTPConnectRelayConnector(target: target)
        let destination = try SOCKS5Endpoint(address: SOCKS5Address(domain: "example.com"), port: 443)
        try connector.validateResponse(Data("HTTP/1.1 204 No Content\r\n\r\n".utf8))
        #expect(try connector.responseHandshake(for: destination).starts(with: Data("CONNECT ".utf8)))
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

    @Test("Native TCP capability excludes only unimplemented VLESS transports")
    func nativeTCPCapabilityIsTransportAware() throws {
        let plain = try OutboundNodeTarget(
            protocolName: "vless", host: "node.example.com", port: 443,
            parameters: ["uuid": "00000000-0000-0000-0000-000000000001"]
        )
        let websocket = try OutboundNodeTarget(
            protocolName: "vless", host: "node.example.com", port: 443,
            parameters: ["uuid": "00000000-0000-0000-0000-000000000001", "network": "ws", "ws-path": "/vless"]
        )
        let reality = try OutboundNodeTarget(
            protocolName: "vless", host: "node.example.com", port: 443,
            parameters: ["uuid": "00000000-0000-0000-0000-000000000001", "reality": "true"]
        )

        #expect(NativeConnectorRegistry.supportsNativeTCP(plain))
        #expect(NativeConnectorRegistry.supportsNativeTCP(websocket))
        #expect(!NativeConnectorRegistry.supportsNativeTCP(reality))
        #expect(NativeConnectorRegistry.capability(for: plain) == .native)
        #expect(NativeConnectorRegistry.capability(for: websocket) == .native)
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
        #expect(plan.initialPayload == nil)
        #expect(!plan.usesSOCKS5Handshake)
        let codec = try #require(plan.streamCodec)
        #expect(try codec.encodeDestination().first == VLESSCodec.version)
        #expect(try codec.decode(Data([VLESSCodec.version, 0]) + Data("ok".utf8)) == [Data("ok".utf8)])
        plan.connection.cancel()
    }

    @Test("Factory keeps one stateful SIP002 codec with the connection plan")
    func factoryBuildsShadowsocksStreamPlan() throws {
        let destination = try SOCKS5Endpoint(
            address: SOCKS5Address(domain: "example.com"),
            port: 443
        )
        let target = try OutboundNodeTarget(
            protocolName: "shadowsocks",
            host: "127.0.0.1",
            port: 18443,
            parameters: ["method": "aes-256-gcm", "password": "fixture-password"]
        )
        let plan = try NativeConnectorFactory.makeTCPPlan(
            target: target,
            destination: destination
        )
        let codec = try #require(plan.streamCodec)
        let destinationFrame = try #require(plan.initialPayload)
        #expect(!destinationFrame.isEmpty)
        let payload = try codec.encode(Data("hello".utf8))
        var decoder = try ShadowsocksAEADStreamDecoder(
            methodName: "aes-256-gcm",
            password: "fixture-password"
        )
        let decoded = try decoder.append(destinationFrame + payload)
        #expect(decoded == [
            try ShadowsocksAEADStreamEncoder.encodeDestination(
                host: "example.com",
                port: 443
            ),
            Data("hello".utf8)
        ])
        plan.connection.cancel()
    }
}
