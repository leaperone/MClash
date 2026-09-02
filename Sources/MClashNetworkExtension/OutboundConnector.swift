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
        to proxy: ProviderSOCKSConfiguration
    ) -> NWConnection
}

/// Compatibility connector backed by the private loopback Mihomo SOCKS5
/// listener.  This is deliberately an adapter, rather than a routing API:
/// Mihomo receives an already-resolved route and destination from MClash.
struct MihomoSOCKSOutboundConnector: OutboundConnector {
    func makeConnection(to proxy: ProviderSOCKSConfiguration) -> NWConnection {
        NWConnection(host: proxy.networkHost, port: proxy.networkPort, using: .tcp)
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

    func makeConnection(to _: ProviderSOCKSConfiguration) -> NWConnection {
        NativeSOCKS5OutboundConnector(target: target).makeConnection()
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
            var headers: [(name: String, value: String)] = []
            if let rawHost = target.parameters["ws-host"] {
                headers.append((name: "Host", value: rawHost))
            }
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

/// Central protocol dispatch for the native connector rollout. Keeping this
/// table explicit prevents an unknown subscription protocol from silently
/// being treated as a Mihomo route.
enum NativeConnectorRegistry {
    static let supportedProtocols: Set<String> = ["socks5", "vless", "trojan", "hysteria2"]

    static func supports(_ target: OutboundNodeTarget) -> Bool {
        supportedProtocols.contains(target.protocolName)
    }

    static func validate(_ target: OutboundNodeTarget) throws {
        guard supports(target) else {
            throw NativeConnectorRegistryError.unsupportedProtocol(target.protocolName)
        }
    }

    static func capability(for target: OutboundNodeTarget) -> NativeConnectorCapability {
        supports(target) ? .native : .unsupported
    }
}
