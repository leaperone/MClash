import Foundation
import MClashNetworkShared
@preconcurrency import Network
@preconcurrency import NetworkExtension

enum DNSProxyBootstrapError: LocalizedError {
    case dataPlaneUnavailable
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .dataPlaneUnavailable:
            return "The private Mihomo SOCKS5 DNS relay is unavailable"
        case .invalidConfiguration:
            return "The DNS proxy revision, activation identifier, or private Mihomo SOCKS5 configuration is invalid"
        }
    }
}

/// DNS proxy entry point. Every accepted TCP/UDP DNS flow is relayed through
/// the same private authenticated Mihomo SOCKS5 listener used by App Routing.
/// Unlike a transparent provider, DNS has no safe per-flow pass-through path:
/// a relay failure is reported to the host heartbeat so the host can disable
/// the DNS manager and restore the system resolver.
final class DNSProxyProvider: NEDNSProxyProvider, @unchecked Sendable {
    private let runtime = ProviderRuntimeState(providerName: "dns-proxy")
    private let tcpRelays = TCPFlowRelayRegistry()
    private let udpSessions = UDPFlowSessionRegistry()
    private var reporter: DNSProxyRuntimeReporter?
    private var proxy: ProviderSOCKSConfiguration?
    private let backendProbeQueue = DispatchQueue(
        label: "one.leaper.mclash.dns-backend-probe"
    )
    private let backendProbeLock = NSLock()
    private var backendProbeTimer: DispatchSourceTimer?
    private var activeBackendProbe: MihomoUDPAssociationProbe?
    private var backendProbeGeneration: UInt64 = 0
    private var consecutiveBackendProbeFailures = 0
    private var backendProbingSuspended = false

    private static let backendProbeFailureThreshold = 3

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Apple passes NEDNSProxyProviderProtocol.providerConfiguration as-is
        // through this options parameter when the framework starts the proxy.
        guard let configuration = options,
              let revision = Self.uint64(configuration[ProviderConfigurationKey.revision]),
              revision > 0,
              let activationIdentifier = Self.uuid(
                  configuration[ProviderConfigurationKey.activationIdentifier]
              ),
              let proxy = ProviderSOCKSConfiguration(
                  providerConfiguration: configuration
              ) else {
            runtime.start(configuration: nil)
            runtime.stop()
            completionHandler(DNSProxyBootstrapError.invalidConfiguration)
            return
        }

        do {
            let startCompletion = DNSProxyStartCompletion(completionHandler)
            let reporter = try DNSProxyRuntimeReporter(
                revision: revision,
                activationIdentifier: activationIdentifier
            )
            self.reporter = reporter
            self.proxy = proxy
            reporter.startHeartbeat()
            runtime.start(configuration: configuration)

            let probe = MihomoUDPAssociationProbe()
            backendProbeLock.lock()
            backendProbingSuspended = false
            consecutiveBackendProbeFailures = 0
            backendProbeGeneration &+= 1
            let probeGeneration = backendProbeGeneration
            activeBackendProbe = probe
            backendProbeLock.unlock()
            probe.start(proxy: proxy) { [weak self] error in
                guard let self else { return }
                self.backendProbeLock.lock()
                let resultIsCurrent = self.activeBackendProbe === probe
                    && self.backendProbeGeneration == probeGeneration
                    && !self.backendProbingSuspended
                if resultIsCurrent {
                    self.activeBackendProbe = nil
                }
                self.backendProbeLock.unlock()
                guard resultIsCurrent else { return }
                if let error {
                    self.reporter?.markStartupFailed(.backendUnavailable)
                    self.runtime.stop()
                    startCompletion.call(error)
                    return
                }
                do {
                    try self.reporter?.markRunning()
                    self.startPeriodicBackendProbe()
                    startCompletion.call(nil)
                } catch {
                    self.reporter?.markStartupFailed(.statusPersistenceFailed)
                    self.runtime.stop()
                    startCompletion.call(error)
                }
            }
        } catch {
            runtime.stop()
            completionHandler(error)
        }
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        suspendBackendProbing()
        tcpRelays.cancelAll()
        udpSessions.cancelAll()
        reporter?.stop(category: .cancelled)
        reporter = nil
        proxy = nil
        runtime.stop()
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let tcpFlow = flow as? NEAppProxyTCPFlow else { return true }
        guard let proxy,
              let destination = DNSProxyEndpointCompatibility.tcpDestination(tcpFlow)
        else {
            reject(flow, category: .flowConversionFailed)
            return true
        }
        let identifier = UUID()
        reporter?.beginFlow(identifier, transportProtocol: .tcp)
        let reporter = reporter
        tcpRelays.startMihomo(
            flow: tcpFlow,
            proxy: proxy,
            destination: destination,
            unavailableFallback: .reject,
            activityObserver: { snapshot in
                reporter?.observe(
                    snapshot,
                    flowIdentifier: identifier,
                    transportProtocol: .tcp
                )
            }
        )
        return true
    }

    @available(macOS, introduced: 14.0, obsoleted: 15.0)
    override func __handleNewUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteEndpoint remoteEndpoint: NetworkExtension.__NWEndpoint
    ) -> Bool {
        guard let destination = DNSProxyEndpointCompatibility.legacyDestination(
            remoteEndpoint
        ) else {
            reject(flow, category: .flowConversionFailed)
            return true
        }
        return handleUDPFlow(flow, initialDestination: destination)
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        suspendBackendProbing()
        tcpRelays.cancelAll()
        udpSessions.cancelAll()
        completionHandler()
    }

    override func wake() {
        backendProbeLock.lock()
        backendProbingSuspended = false
        consecutiveBackendProbeFailures = 0
        backendProbeGeneration &+= 1
        backendProbeLock.unlock()
        runBackendProbe()
        startPeriodicBackendProbe()
    }

    private func startPeriodicBackendProbe() {
        backendProbeLock.lock()
        guard backendProbeTimer == nil, !backendProbingSuspended else {
            backendProbeLock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: backendProbeQueue)
        backendProbeTimer = timer
        backendProbeLock.unlock()
        timer.schedule(deadline: .now() + .seconds(4), repeating: .seconds(4))
        timer.setEventHandler { [weak self] in self?.runBackendProbe() }
        timer.resume()
    }

    private func suspendBackendProbing() {
        backendProbeLock.lock()
        backendProbingSuspended = true
        backendProbeGeneration &+= 1
        consecutiveBackendProbeFailures = 0
        let timer = backendProbeTimer
        backendProbeTimer = nil
        let probe = activeBackendProbe
        activeBackendProbe = nil
        backendProbeLock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
        probe?.cancel()
    }

    private func runBackendProbe() {
        backendProbeLock.lock()
        guard activeBackendProbe == nil,
              !backendProbingSuspended,
              let proxy
        else {
            backendProbeLock.unlock()
            return
        }
        let probe = MihomoUDPAssociationProbe()
        let probeGeneration = backendProbeGeneration
        activeBackendProbe = probe
        backendProbeLock.unlock()
        probe.start(proxy: proxy) { [weak self] error in
            guard let self else { return }
            self.backendProbeLock.lock()
            let resultIsCurrent = self.activeBackendProbe === probe
                && self.backendProbeGeneration == probeGeneration
                && !self.backendProbingSuspended
            guard resultIsCurrent else {
                self.backendProbeLock.unlock()
                return
            }
            self.activeBackendProbe = nil
            if error == nil {
                self.consecutiveBackendProbeFailures = 0
            } else {
                self.consecutiveBackendProbeFailures += 1
            }
            let stableFailure = self.consecutiveBackendProbeFailures
                >= Self.backendProbeFailureThreshold
            self.backendProbeLock.unlock()

            if error == nil {
                try? self.reporter?.markRunning()
            } else if stableFailure {
                self.reporter?.markBackendUnavailable(.backendUnavailable)
            }
        }
    }

    private func handleUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialDestination: SOCKS5Endpoint
    ) -> Bool {
        guard let proxy else {
            reject(flow, category: .backendUnavailable)
            return true
        }
        let parentIdentifier = UUID()
        let initialPlan = dnsPlan(
            destination: initialDestination,
            proxy: proxy,
            parentIdentifier: parentIdentifier
        )
        let reporter = reporter
        let started = udpSessions.start(
            id: parentIdentifier,
            flow: flow,
            initialPlan: initialPlan,
            planner: { [weak self] destination in
                guard let self, let proxy = self.proxy else {
                    return initialPlan
                }
                return self.dnsPlan(
                    destination: destination,
                    proxy: proxy,
                    parentIdentifier: parentIdentifier
                )
            },
            revisionProvider: { initialPlan.activity.configurationRevision },
            activitySink: { activity in
                reporter?.beginFlow(
                    activity.flowIdentifier,
                    transportProtocol: .udp
                )
            },
            observerFactory: { identifier in
                { snapshot in
                    reporter?.observe(
                        snapshot,
                        flowIdentifier: identifier,
                        transportProtocol: .udp
                    )
                }
            }
        )
        if !started {
            reject(flow, category: .udpRelayFailed)
        }
        return true
    }

    private func dnsPlan(
        destination: SOCKS5Endpoint,
        proxy: ProviderSOCKSConfiguration,
        parentIdentifier: UUID
    ) -> UDPFlowInterceptionPlan {
        let decision = FlowTrafficDecision(
            disposition: .mihomo(.profileRules),
            reason: .rule(.defaultDirect)
        )
        let host = destination.address.ipAddress?.presentation
            ?? destination.address.domain
        let activity = AppRoutingActivity(
            parentFlowIdentifier: parentIdentifier,
            configurationRevision: runtime.snapshot().revision,
            startedAt: Date(),
            source: AppRoutingActivitySource(
                processIdentifier: 0,
                userIdentifier: 0,
                signingIdentifier: "System DNS"
            ),
            destination: AppRoutingActivityDestination(
                hostname: destination.address.domain,
                ipAddress: destination.address.ipAddress?.presentation ?? host,
                port: destination.port
            ),
            transportProtocol: .udp,
            decision: decision,
            configuredAction: .mihomo(.profileRules),
            effectiveAction: .mihomo(.profileRules),
            relayState: .pending,
            payloadBytesAreMeasured: true,
            uploadDatagrams: 0,
            downloadDatagrams: 0,
            droppedDatagrams: 0
        )
        return UDPFlowInterceptionPlan(
            decision: decision,
            initialDestination: destination,
            proxy: proxy,
            unavailableFallback: .reject,
            activity: activity,
            parentFlowIdentifier: parentIdentifier
        )
    }

    private func reject(
        _ flow: NEAppProxyFlow,
        category: DNSProxyFailureCategory
    ) {
        let identifier = UUID()
        let transportProtocol: TransportProtocol = flow is NEAppProxyUDPFlow
            ? .udp
            : .tcp
        reporter?.beginFlow(identifier, transportProtocol: transportProtocol)
        reporter?.observe(
            AppRoutingRelaySnapshot(
                state: .failed,
                uploadBytes: 0,
                downloadBytes: 0,
                error: "DNS relay unavailable",
                localPort: nil
            ),
            flowIdentifier: identifier,
            transportProtocol: transportProtocol
        )
        reporter?.recordFlowFailure(category)
        let error = DNSProxyBootstrapError.dataPlaneUnavailable
        AppProxyFlowCompatibility.open(flow) { completionError in
            let terminalError = completionError ?? error
            flow.closeReadWithError(terminalError)
            flow.closeWriteWithError(terminalError)
        }
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        switch value {
        case let value as UInt64: value
        case let value as Int where value >= 0: UInt64(value)
        case let value as NSNumber where value.int64Value >= 0: value.uint64Value
        case let value as String: UInt64(value)
        default: nil
        }
    }

    private static func uuid(_ value: Any?) -> UUID? {
        switch value {
        case let value as UUID: value
        case let value as String: UUID(uuidString: value)
        default: nil
        }
    }
}

private final class DNSProxyStartCompletion: @unchecked Sendable {
    private let completion: (Error?) -> Void

    init(_ completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    func call(_ error: Error?) {
        completion(error)
    }
}

private enum DNSProxyEndpointCompatibility {
    static func tcpDestination(_ flow: NEAppProxyTCPFlow) -> SOCKS5Endpoint? {
        if #available(macOS 15.0, *) {
            return destination(flow.remoteFlowEndpoint)
        }
        return legacyDestination(flow.__remoteEndpoint)
    }

    @available(macOS 15.0, *)
    static func destination(_ endpoint: Network.NWEndpoint) -> SOCKS5Endpoint? {
        guard case let .hostPort(host, port) = endpoint else { return nil }
        return try? ProviderSOCKSConfiguration.destination(
            for: FlowRemoteEndpoint(host: host.debugDescription, port: port.rawValue)
        )
    }

    @available(macOS, introduced: 14.0, obsoleted: 15.0)
    static func legacyDestination(
        _ endpoint: NetworkExtension.__NWEndpoint
    ) -> SOCKS5Endpoint? {
        let object = endpoint as NSObject
        guard object.isKind(of: NetworkExtension.__NWHostEndpoint.self),
              let host = object.value(forKey: "hostname") as? String,
              let port = object.value(forKey: "port") as? String else { return nil }
        return try? ProviderSOCKSConfiguration.destination(
            for: FlowRemoteEndpoint(host: host, port: port)
        )
    }
}

@available(macOS 15.0, *)
extension DNSProxyProvider: NEAppProxyUDPFlowHandling {
    func handleNewUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint
    ) -> Bool {
        guard let destination = DNSProxyEndpointCompatibility.destination(remoteEndpoint) else {
            reject(flow, category: .flowConversionFailed)
            return true
        }
        return handleUDPFlow(flow, initialDestination: destination)
    }
}
