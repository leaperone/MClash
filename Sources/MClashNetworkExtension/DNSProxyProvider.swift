import Foundation
import NetworkExtension

enum DNSProxyBootstrapError: LocalizedError {
    case dataPlaneUnavailable

    var errorDescription: String? {
        switch self {
        case .dataPlaneUnavailable:
            return "The DNS relay data plane is not installed yet"
        }
    }
}

/// DNS proxy entry point and lifecycle shell.
///
/// Unlike `NETransparentProxyProvider`, `NEDNSProxyProvider` has no per-flow
/// bypass: returning `false` terminates a DNS flow. Consequently this skeleton
/// refuses to start until a real DNS relay exists. The host must treat this
/// startup error as a signal to leave `NEDNSProxyManager` disabled, preserving
/// the system resolver rather than black-holing DNS.
final class DNSProxyProvider: NEDNSProxyProvider {
    private let runtime = ProviderRuntimeState(providerName: "dns-proxy")

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        runtime.start(configuration: options)
        runtime.stop()
        completionHandler(DNSProxyBootstrapError.dataPlaneUnavailable)
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        runtime.stop()
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // Defensive only: startProxy currently fails, so no flow should arrive.
        // False is NOT fail-open for a DNS provider.
        false
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {}
}
