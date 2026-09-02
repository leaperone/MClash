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

/// Pure policy used by relays and tests to enforce the ownership boundary.
/// Direct and Reject are terminal MClash decisions and therefore do not
/// require (or permit) an outbound connector invocation.
enum OutboundConnectorRoutingPolicy {
    static func requiresConnector(_ disposition: FlowTrafficDisposition) -> Bool {
        if case .mihomo = disposition { return true }
        return false
    }
}
