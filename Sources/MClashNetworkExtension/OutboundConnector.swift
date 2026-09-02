import Foundation
@preconcurrency import Network
import MClashNetworkShared

/// The only boundary a route relay needs to know about an outbound connector.
///
/// MClash owns the flow decision.  A connector is used only after that
/// decision has selected a proxy route; it must never be involved in Direct
/// or Reject handling.  Keeping this protocol small lets us replace Mihomo
/// with a native connector later without changing the routing layer.
protocol OutboundConnector: Sendable {
    func makeConnection(
        to proxy: ProviderSOCKSConfiguration?
    ) -> NWConnection

    func makeStreamCodec(for destination: SOCKS5Endpoint) throws -> (any NativeStreamCodec)?
}

/// A connector whose initial request is not self-authenticating from the
/// client's point of view.  The relay must validate the peer's response
/// before opening the intercepted application flow.  Keeping this separate
/// from `OutboundConnector` makes the response gate explicit and prevents a
/// future connector from accidentally opening on `send` completion alone.
protocol OutboundResponseHandshake: Sendable {
    func responseHandshake(for destination: SOCKS5Endpoint) throws -> Data
    func validateResponse(_ response: Data) throws
}

extension OutboundConnector {
    func makeStreamCodec(for _: SOCKS5Endpoint) throws -> (any NativeStreamCodec)? { nil }
}

protocol NativeStreamCodec: AnyObject, Sendable {
    func encodeDestination() throws -> Data
    func encode(_ payload: Data) throws -> Data
    func decode(_ input: Data) throws -> [Data]
}

/// Compatibility connector backed by the private loopback Mihomo SOCKS5
/// listener.  This is deliberately an adapter, rather than a routing API:
/// Mihomo receives an already-resolved route and destination from MClash.
struct MihomoSOCKSOutboundConnector: OutboundConnector {
    func makeConnection(to proxy: ProviderSOCKSConfiguration?) -> NWConnection {
        precondition(proxy != nil, "Mihomo connector requires a SOCKS endpoint")
        let proxy = proxy!
        return NWConnection(host: proxy.networkHost, port: proxy.networkPort, using: .tcp)
    }
}

/// Native SOCKS5 node connector. A SOCKS5 subscription node is itself an
/// outbound endpoint, so the relay can reuse the same standards-compliant
/// handshake without involving Mihomo.
struct NativeSOCKS5OutboundConnector: Sendable {
    let target: OutboundNodeTarget

    init(target: OutboundNodeTarget) {
        self.target = target
    }

    func makeConnection() -> NWConnection {
        NWConnection(
            host: NWEndpoint.Host(target.host),
            port: NWEndpoint.Port(rawValue: target.port)!,
            using: .tcp
        )
    }
}

/// Adapter used by the existing TCP relay while its route plan migrates from
/// Mihomo endpoints to native node targets. The relay still performs the
/// standards-compliant SOCKS5 destination handshake after this connection is
/// ready, so no Mihomo listener is involved.
struct NativeSOCKS5RelayConnector: OutboundConnector {
    let target: OutboundNodeTarget

    func makeConnection(to _: ProviderSOCKSConfiguration?) -> NWConnection {
        NativeSOCKS5OutboundConnector(target: target).makeConnection()
    }
}

private final class ShadowsocksStreamCodecBox: NativeStreamCodec, @unchecked Sendable {
    private var encoder: ShadowsocksAEADStreamEncoder
    private var decoder: ShadowsocksAEADStreamDecoder
    private let destination: Data

    init(target: OutboundNodeTarget, destination: SOCKS5Endpoint) throws {
        let method = target.parameters["method"] ?? target.parameters["cipher"] ?? "aes-256-gcm"
        let password = target.parameters["password"] ?? target.parameters["passwd"] ?? ""
        encoder = try ShadowsocksAEADStreamEncoder(methodName: method, password: password)
        decoder = try ShadowsocksAEADStreamDecoder(methodName: method, password: password)
        let host = destination.address.domain ?? destination.address.ipAddress?.presentation ?? ""
        self.destination = try ShadowsocksAEADStreamEncoder.encodeDestination(host: host, port: destination.port)
    }

    func encodeDestination() throws -> Data { try encoder.encode(destination) }
    func encode(_ payload: Data) throws -> Data { try encoder.encode(payload) }
    func decode(_ input: Data) throws -> [Data] { try decoder.append(input) }
}

struct NativeShadowsocksRelayConnector: OutboundConnector {
    let target: OutboundNodeTarget
    let destination: SOCKS5Endpoint

    func makeConnection(to _: ProviderSOCKSConfiguration?) -> NWConnection {
        NWConnection(host: NWEndpoint.Host(target.host),
                     port: NWEndpoint.Port(rawValue: target.port)!, using: .tcp)
    }

    func makeStreamCodec(for _: SOCKS5Endpoint) throws -> (any NativeStreamCodec)? {
        try ShadowsocksStreamCodecBox(target: target, destination: destination)
    }
}

/// Native VLESS TCP connector. The relay writes `handshake()` immediately
/// after the transport reaches ready, then forwards payload bytes unchanged.
/// TLS/WS transport options are represented in the target parameters; the
/// initial implementation uses Network.framework TLS for `tls=true` and keeps
/// the wire framing in the shared VLESS codec.
struct NativeVLESSOutboundConnector: Sendable {
    let target: OutboundNodeTarget

    func makeConnection() -> NWConnection {
        let parameters: NWParameters
        if target.parameters["tls"]?.lowercased() == "true" {
            let tls = NWProtocolTLS.Options()
            let serverName = target.parameters["sni"]
                ?? target.parameters["servername"]
                ?? target.host
            serverName.withCString {
                sec_protocol_options_set_tls_server_name(
                    tls.securityProtocolOptions,
                    $0
                )
            }
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        if target.parameters["network"]?.lowercased() == "ws" {
            let websocket = NWProtocolWebSocket.Options()
            websocket.autoReplyPing = true
            // NWProtocolWebSocket exposes additional handshake headers, but
            // does not expose the HTTP upgrade path.  Keep this constructor
            // useful for diagnostics/tests while the registry continues to
            // report WS as legacyFallback; otherwise a /path node could be
            // silently connected to the wrong endpoint (usually "/").
            let options = target.vlessWebSocketOptions
            let headers = options?.headers.map { (name: $0.key, value: $0.value) }
                ?? (target.parameters["ws-host"].map { [(name: "Host", value: $0)] } ?? [])
            if !headers.isEmpty { websocket.setAdditionalHeaders(headers) }
            parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        }
        return NWConnection(
            host: NWEndpoint.Host(target.host),
            port: NWEndpoint.Port(rawValue: target.port)!,
            using: parameters
        )
    }

    func handshake(for destination: SOCKS5Endpoint) throws -> Data {
        guard let uuid = target.parameters["uuid"] else {
            throw VLESSCodecError.invalidUUID
        }
        let host = destination.address.domain
            ?? destination.address.ipAddress?.presentation
            ?? ""
        return try VLESSCodec.encodeTCPRequest(
            uuid: uuid,
            host: host,
            port: destination.port
        )
    }
}

/// Native Trojan TCP connector. Trojan authenticates with a SHA-224 password
/// prefix over a TLS stream and then reuses the SOCKS5 CONNECT framing.
struct NativeTrojanOutboundConnector: Sendable {
    let target: OutboundNodeTarget

    func makeConnection() -> NWConnection {
        let tls = NWProtocolTLS.Options()
        let serverName = target.parameters["sni"]
            ?? target.parameters["servername"]
            ?? target.host
        serverName.withCString {
            sec_protocol_options_set_tls_server_name(
                tls.securityProtocolOptions,
                $0
            )
        }
        return NWConnection(
            host: NWEndpoint.Host(target.host),
            port: NWEndpoint.Port(rawValue: target.port)!,
            using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        )
    }

    func handshake(for destination: SOCKS5Endpoint) throws -> Data {
        guard let password = target.parameters["password"]
            ?? target.parameters["passwd"] else {
            throw TrojanCodecError.invalidPassword
        }
        let host = destination.address.domain
            ?? destination.address.ipAddress?.presentation
            ?? ""
        return try TrojanCodec.encodeTCPRequest(
            password: password,
            host: host,
            port: destination.port
        )
    }
}

struct NativeVLESSRelayConnector: OutboundConnector {
    let target: OutboundNodeTarget
    func makeConnection(to _: ProviderSOCKSConfiguration?) -> NWConnection {
        NativeVLESSOutboundConnector(target: target).makeConnection()
    }
}

struct NativeTrojanRelayConnector: OutboundConnector {
    let target: OutboundNodeTarget
    func makeConnection(to _: ProviderSOCKSConfiguration?) -> NWConnection {
        NativeTrojanOutboundConnector(target: target).makeConnection()
    }
}

/// HTTP CONNECT node connector foundation.  The HTTP proxy handshake is
/// intentionally represented separately from SOCKS5: callers must consume
/// and validate the 2xx response before opening a flow.  Until that response
/// gate is wired into TCPFlowRelay, the registry reports this protocol as a
/// legacy fallback so an HTTP node can never be misclassified as native.
struct NativeHTTPConnectOutboundConnector: Sendable {
    let target: OutboundNodeTarget

    func makeConnection() -> NWConnection {
        let useTLS = ["true", "1", "yes"].contains(
            target.parameters["tls"]?.lowercased() ?? "false"
        )
        let parameters: NWParameters
        if useTLS {
            let tls = NWProtocolTLS.Options()
            let serverName = target.parameters["sni"]
                ?? target.parameters["servername"]
                ?? target.host
            serverName.withCString {
                sec_protocol_options_set_tls_server_name(
                    tls.securityProtocolOptions,
                    $0
                )
            }
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        return NWConnection(
            host: NWEndpoint.Host(target.host),
            port: NWEndpoint.Port(rawValue: target.port)!,
            using: parameters
        )
    }

    func handshake(for destination: SOCKS5Endpoint) throws -> Data {
        let host = destination.address.domain
            ?? destination.address.ipAddress?.presentation
            ?? ""
        return try HTTPProxyCodec.encodeConnectRequest(
            host: host,
            port: destination.port,
            username: target.parameters["username"]
                ?? target.parameters["user"],
            password: target.parameters["password"]
                ?? target.parameters["pass"]
        )
    }

    func validate(response: Data) throws -> Int {
        try HTTPProxyCodec.decodeConnectResponse(response)
    }
}

struct NativeHTTPConnectRelayConnector: OutboundConnector, OutboundResponseHandshake {
    let target: OutboundNodeTarget

    func makeConnection(to _: ProviderSOCKSConfiguration?) -> NWConnection {
        NativeHTTPConnectOutboundConnector(target: target).makeConnection()
    }

    func responseHandshake(for destination: SOCKS5Endpoint) throws -> Data {
        try NativeHTTPConnectOutboundConnector(target: target).handshake(for: destination)
    }

    func validateResponse(_ response: Data) throws {
        _ = try NativeHTTPConnectOutboundConnector(target: target).validate(response: response)
    }
}

/// Native Hysteria2 transport bootstrap. This establishes the QUIC/TLS layer;
/// HTTP/3 CONNECT-UDP stream framing is intentionally handled by the future
/// session implementation rather than being confused with SOCKS5 relay bytes.
struct NativeHysteria2OutboundConnector: Sendable {
    let target: OutboundNodeTarget

    func makeConnection() -> NWConnection {
        let quic = NWProtocolQUIC.Options(alpn: ["h3"])
        quic.direction = .bidirectional
        quic.isDatagram = true
        quic.maxDatagramFrameSize = 1350
        let serverName = target.parameters["sni"]
            ?? target.parameters["servername"]
            ?? target.host
        serverName.withCString {
            sec_protocol_options_set_tls_server_name(
                quic.securityProtocolOptions,
                $0
            )
        }
        return NWConnection(
            host: NWEndpoint.Host(target.host),
            port: NWEndpoint.Port(rawValue: target.port)!,
            using: NWParameters(quic: quic)
        )
    }

    func authHeaders(receiveRate: UInt64 = 0, padding: String = "") throws -> [(String, String)] {
        guard let password = target.parameters["password"]
            ?? target.parameters["auth"] else {
            throw Hysteria2CodecError.invalidAuth
        }
        return try Hysteria2Codec.authHeaders(
            password: password,
            receiveRate: receiveRate,
            padding: padding
        )
    }

    func tcpRequest(for destination: SOCKS5Endpoint, padding: Data = Data()) throws -> Data {
        let host = destination.address.domain
            ?? destination.address.ipAddress?.presentation
            ?? ""
        return try Hysteria2Codec.encodeTCPRequest(
            host: host,
            port: destination.port,
            padding: padding
        )
    }

    func udpMessage(
        sessionID: UInt32,
        packetID: UInt16,
        destination: SOCKS5Endpoint,
        payload: Data
    ) throws -> Data {
        let host = destination.address.domain
            ?? destination.address.ipAddress?.presentation
            ?? ""
        return try Hysteria2Codec.encodeUDPMessage(
            sessionID: sessionID,
            packetID: packetID,
            host: host,
            port: destination.port,
            payload: payload
        )
    }
}

/// Pure policy used by relays and tests to enforce the ownership boundary.
/// Direct and Reject are terminal MClash decisions and therefore do not
/// require (or permit) an outbound connector invocation.
enum OutboundConnectorRoutingPolicy {
    static func requiresConnector(_ disposition: FlowTrafficDisposition) -> Bool {
        if case .mihomo = disposition { return true }
        return false
    }
}

enum NativeConnectorRegistryError: Error, Equatable, Sendable {
    case unsupportedProtocol(String)
}

enum NativeConnectorCapability: String, Equatable, Sendable {
    case native
    case legacyFallback
    case unsupported
}

enum NativeConnectorKind: String, Equatable, Sendable {
    case http
    case socks5
    case shadowsocks
    case vless
    case trojan
    case hysteria2
}

/// Central protocol dispatch for the native connector rollout. Keeping this
/// table explicit prevents an unknown subscription protocol from silently
/// being treated as a Mihomo route.
enum NativeConnectorRegistry {
    static let supportedProtocols: Set<String> = ["http", "socks5", "shadowsocks", "vless", "trojan", "hysteria2"]

    static func supports(_ target: OutboundNodeTarget) -> Bool {
        supportedProtocols.contains(target.protocolName)
    }

    /// Native TCP support is deliberately narrower than protocol recognition.
    /// Transport variants whose framing/options are not implemented must stay
    /// on the Mihomo compatibility path instead of being labelled native.
    static func supportsNativeTCP(_ target: OutboundNodeTarget) -> Bool {
        guard supports(target) else { return false }
        switch target.protocolName {
        case "http":
            // CONNECT is native only when TCPFlowRelay consumes and validates
            // the complete 2xx response before opening the app flow.
            return true
        case "socks5":
            return true
        case "shadowsocks":
            // SIP002 TCP AEAD only. SIP003 plugins and UDP require a separate
            // transport and therefore remain on the legacy compatibility path.
            let plugin = target.parameters["plugin"] ?? target.parameters["plugin-opts"]
            guard plugin?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return false }
            let method = target.parameters["method"] ?? target.parameters["cipher"] ?? "aes-256-gcm"
            let password = target.parameters["password"] ?? target.parameters["passwd"] ?? ""
            return !password.isEmpty && ShadowsocksAEADMethod(rawValue: method.lowercased()) != nil
        case "vless":
            let network = target.parameters["network"]?.lowercased() ?? "tcp"
            return network == "tcp" && !hasUnsupportedRealityOrXTLSParameters(target.parameters)
        case "trojan":
            let network = target.parameters["network"]?.lowercased() ?? "tcp"
            return network == "tcp"
        default:
            return false
        }
    }

    /// Native VLESS currently implements plain TCP only. Reality and XTLS
    /// material is commonly flattened into the imported node's string
    /// parameters (rather than represented by a single `reality: true`
    /// switch), so checking only that switch can incorrectly route these
    /// nodes through the incomplete native connector. Keep every such node
    /// on the compatibility path until the corresponding handshake is
    /// implemented and verified.
    private static func hasUnsupportedRealityOrXTLSParameters(
        _ parameters: [String: String]
    ) -> Bool {
        let normalized = Dictionary(
            parameters.map { key, value in
                (key.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .replacingOccurrences(of: "_", with: "-"), value)
            }, uniquingKeysWith: { first, _ in first }
        )

        // The importer preserves reality-opts as a JSON string. Presence of
        // the field is enough—even `{}` is an explicit transport selection.
        if normalized.keys.contains(where: { $0 == "reality-opts" || $0 == "reality-options" }) {
            return true
        }

        if let reality = normalized["reality"],
           ["true", "yes", "1", "on"].contains(reality.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return true
        }

        if let xtls = normalized["xtls"],
           ["true", "yes", "1", "on"].contains(xtls.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return true
        }

        // XTLS flow values are not supported by the native TCP connector.
        // Treat any non-empty flow as unsupported: this is safer for future
        // XTLS variants than allow-listing one spelling.
        if let flow = normalized["flow"], !flow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        // Some importers expose Reality's fields individually. Requiring the
        // characteristic pair avoids classifying an unrelated public-key
        // parameter as Reality while still covering flattened subscriptions.
        let security = normalized["security"]?.lowercased()
        let hasRealityKeyMaterial = normalized["public-key"] != nil
            || normalized["short-id"] != nil
            || normalized["server-name"] != nil && security == "reality"
        return security == "reality" || hasRealityKeyMaterial
    }

    static func validate(_ target: OutboundNodeTarget) throws {
        guard supports(target) else {
            throw NativeConnectorRegistryError.unsupportedProtocol(target.protocolName)
        }
    }

    static func capability(for target: OutboundNodeTarget) -> NativeConnectorCapability {
        if supportsNativeTCP(target) { return .native }
        return supports(target) ? .legacyFallback : .unsupported
    }

    static func kind(for target: OutboundNodeTarget) -> NativeConnectorKind? {
        NativeConnectorKind(rawValue: target.protocolName)
    }

    static func descriptor(for target: OutboundNodeTarget) throws -> NativeConnectorDescriptor {
        guard let kind = kind(for: target) else {
            throw NativeConnectorRegistryError.unsupportedProtocol(target.protocolName)
        }
        return NativeConnectorDescriptor(kind: kind, target: target)
    }

    static func validateForProduction(_ target: OutboundNodeTarget) throws {
        guard let kind = kind(for: target) else {
            throw NativeConnectorRegistryError.unsupportedProtocol(target.protocolName)
        }
        switch kind {
        case .http:
            break
        case .socks5, .shadowsocks:
            break
        case .vless, .trojan:
            guard supportsNativeTCP(target) else {
                throw NativeConnectorRegistryError.unsupportedProtocol(
                    "\(target.protocolName) transport is not implemented"
                )
            }
        case .hysteria2:
            throw NativeConnectorRegistryError.unsupportedProtocol("hysteria2 requires QUIC session")
        }
    }
}

struct NativeConnectorDescriptor: Equatable, Sendable {
    let kind: NativeConnectorKind
    let target: OutboundNodeTarget
}

struct NativeTCPConnectionPlan: Sendable {
    let connection: NWConnection
    let initialPayload: Data?
    let usesSOCKS5Handshake: Bool
}

enum NativeConnectorFactory {
    static func makeTCPPlan(
        target: OutboundNodeTarget,
        destination: SOCKS5Endpoint
    ) throws -> NativeTCPConnectionPlan {
        try NativeConnectorRegistry.validateForProduction(target)
        switch NativeConnectorRegistry.kind(for: target) {
        case .http:
            let connector = NativeHTTPConnectOutboundConnector(target: target)
            return NativeTCPConnectionPlan(
                connection: connector.makeConnection(),
                initialPayload: try connector.handshake(for: destination),
                usesSOCKS5Handshake: false
            )
        case .socks5:
            return NativeTCPConnectionPlan(
                connection: NativeSOCKS5OutboundConnector(target: target).makeConnection(),
                initialPayload: nil,
                usesSOCKS5Handshake: true
            )
        case .shadowsocks:
            throw NativeConnectorRegistryError.unsupportedProtocol("shadowsocks stream requires relay framing")
        case .vless:
            let connector = NativeVLESSOutboundConnector(target: target)
            return NativeTCPConnectionPlan(
                connection: connector.makeConnection(),
                initialPayload: try connector.handshake(for: destination),
                usesSOCKS5Handshake: false
            )
        case .trojan:
            let connector = NativeTrojanOutboundConnector(target: target)
            return NativeTCPConnectionPlan(
                connection: connector.makeConnection(),
                initialPayload: try connector.handshake(for: destination),
                usesSOCKS5Handshake: false
            )
        case .hysteria2:
            throw NativeConnectorRegistryError.unsupportedProtocol("hysteria2 requires QUIC session")
        case nil:
            throw NativeConnectorRegistryError.unsupportedProtocol(target.protocolName)
        }
    }
}
