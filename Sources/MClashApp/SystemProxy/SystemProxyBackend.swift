import Foundation

/// Backend boundary that keeps tests and higher-level state handling away from live network settings.
public protocol SystemProxyBackend: Sendable {
    func enabledNetworkServices() throws -> [SystemProxyNetworkService]
    func proxyStates(for services: [SystemProxyNetworkService]) throws -> [SystemProxyServiceState]
    func applyProxyStates(_ states: [SystemProxyServiceState]) throws
}
