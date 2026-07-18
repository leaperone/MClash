import Foundation
import MClashNetworkShared
@preconcurrency import Network
@preconcurrency import NetworkExtension
import OSLog

private let dnsProxyProviderLogger = Logger(
    subsystem: "one.leaper.mclash.network-extension",
    category: "DNSProxyProvider"
)

enum DNSProxyBootstrapError: LocalizedError {
    case dataPlaneUnavailable
    case cancelledDuringStartup
    case missingProviderConfiguration
    case missingBootstrapPayload
    case invalidBootstrapPayload
    case invalidPrivateRelay

    var errorDescription: String? {
        switch self {
        case .dataPlaneUnavailable:
            return "The private Mihomo SOCKS5 DNS relay is unavailable"
        case .cancelledDuringStartup:
            return "DNS proxy startup was cancelled before the private relay became ready"
        case .missingProviderConfiguration:
            return "The DNS proxy provider configuration was not delivered by macOS"
        case .missingBootstrapPayload:
            return "The DNS proxy configuration is missing its versioned bootstrap payload"
        case .invalidBootstrapPayload:
            return "The DNS proxy bootstrap payload is invalid or unsupported"
        case .invalidPrivateRelay:
            return "The DNS proxy bootstrap contains an invalid private Mihomo SOCKS5 relay"
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
    private let identityResolver = ProcessIdentityResolver()
    private let trustedComponentPolicy = TrustedMClashComponentPolicy()
    private var reporter: DNSProxyRuntimeReporter?
    private var proxy: ProviderSOCKSConfiguration?
    private let backendProbeQueue = DispatchQueue(
        label: "one.leaper.mclash.dns-backend-probe"
    )
    private let backendProbeLock = NSLock()
    private var backendProbeTimer: DispatchSourceTimer?
    private var activeBackendProbe: MihomoUDPAssociationProbe?
    private var pendingStartCompletion: DNSProxyStartCompletion?
    private var backendProbeGeneration: UInt64 = 0
    private var consecutiveBackendProbeFailures = 0
    private var backendProbingSuspended = false

    private static let backendProbeFailureThreshold = 3

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        backendProbeLock.lock()
        backendProbeGeneration &+= 1
        let startGeneration = backendProbeGeneration
        backendProbingSuspended = true
        backendProbeLock.unlock()

        let deliveredPayload = options.flatMap {
            Self.data($0[ProviderConfigurationKey.dnsProxyBootstrap])
        }
        let deliveredBootstrap = deliveredPayload.flatMap {
            try? DNSProxyBootstrapConfiguration.decode($0)
        }
        let bootstrap: DNSProxyBootstrapConfiguration
        do {
            bootstrap = try DNSProxyRuntimeRegistry.shared.resolveBootstrap(
                delivered: deliveredBootstrap
            )
        } catch {
            let reason: DNSProxyStartupFailureReason
            let bootstrapError: DNSProxyBootstrapError
            if options == nil {
                reason = .missingProviderConfiguration
                bootstrapError = .missingProviderConfiguration
            } else if deliveredPayload == nil {
                reason = .missingBootstrapPayload
                bootstrapError = .missingBootstrapPayload
            } else {
                reason = .invalidBootstrapPayload
                bootstrapError = .invalidBootstrapPayload
            }
            rejectBootstrap(
                reason: reason,
                error: bootstrapError,
                bootstrap: nil,
                completionHandler: completionHandler
            )
            return
        }
        guard let proxy = ProviderSOCKSConfiguration(
            routeEndpoint: bootstrap.profileRulesProxy
        ) else {
            rejectBootstrap(
                reason: .invalidPrivateRelay,
                error: .invalidPrivateRelay,
                bootstrap: bootstrap,
                completionHandler: completionHandler
            )
            return
        }

        do {
            let startCompletion = DNSProxyStartCompletion(completionHandler)
            let reporter = try DNSProxyRuntimeReporter(
                revision: bootstrap.revision,
                activationIdentifier: bootstrap.activationIdentifier
            )
            let probe = MihomoUDPAssociationProbe()
            backendProbeLock.lock()
            guard backendProbeGeneration == startGeneration else {
                backendProbeLock.unlock()
                reporter.stop(category: .cancelled)
                startCompletion.call(DNSProxyBootstrapError.cancelledDuringStartup)
                return
            }
            backendProbingSuspended = false
            self.reporter = reporter
            self.proxy = proxy
            consecutiveBackendProbeFailures = 0
            activeBackendProbe = probe
            pendingStartCompletion = startCompletion
            reporter.startHeartbeat()
            runtime.start(configuration: options)
            backendProbeLock.unlock()
            dnsProxyProviderLogger.notice(
                "Accepted DNS bootstrap revision=\(bootstrap.revision, privacy: .public) schema=\(bootstrap.schemaVersion, privacy: .public) source=\(deliveredBootstrap == nil ? "provider-registry" : "provider-options", privacy: .public) payloadBytes=\(deliveredPayload?.count ?? 0, privacy: .public)"
            )
            probe.start(proxy: proxy) { [weak self] error in
                guard let self else { return }
                self.backendProbeLock.lock()
                let resultIsCurrent = self.activeBackendProbe === probe
                    && self.backendProbeGeneration == startGeneration
                    && !self.backendProbingSuspended
                guard resultIsCurrent,
                      self.pendingStartCompletion === startCompletion,
                      let currentReporter = self.reporter else {
                    self.backendProbeLock.unlock()
                    return
                }
                if let error {
                    self.activeBackendProbe = nil
                    self.pendingStartCompletion = nil
                    self.reporter = nil
                    self.proxy = nil
                    self.backendProbingSuspended = true
                    self.backendProbeGeneration &+= 1
                    self.backendProbeLock.unlock()
                    currentReporter.markStartupFailed(.backendUnavailable)
                    self.runtime.stop()
                    startCompletion.call(error)
                    return
                }
                do {
                    try currentReporter.markRunning()
                    self.activeBackendProbe = nil
                    self.pendingStartCompletion = nil
                    self.backendProbeLock.unlock()
                    self.startPeriodicBackendProbe()
                    startCompletion.call(nil)
                } catch {
                    self.activeBackendProbe = nil
                    self.pendingStartCompletion = nil
                    self.reporter = nil
                    self.proxy = nil
                    self.backendProbingSuspended = true
                    self.backendProbeGeneration &+= 1
                    self.backendProbeLock.unlock()
                    currentReporter.markStartupFailed(.statusPersistenceFailed)
                    self.runtime.stop()
                    startCompletion.call(error)
                }
            }
        } catch {
            runtime.stop()
            dnsProxyProviderLogger.error(
                "DNS runtime reporter startup failed errorType=\(String(describing: type(of: error)), privacy: .public)"
            )
            completionHandler(error)
        }
    }

    private func rejectBootstrap(
        reason: DNSProxyStartupFailureReason,
        error: DNSProxyBootstrapError,
        bootstrap: DNSProxyBootstrapConfiguration?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        if let bootstrap {
            DNSProxyRuntimeRegistry.shared.publishStartupFailure(
                reason,
                for: bootstrap
            )
        }
        runtime.start(configuration: nil)
        runtime.stop()
        dnsProxyProviderLogger.error(
            "Rejected DNS bootstrap reason=\(reason.rawValue, privacy: .public)"
        )
        completionHandler(error)
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        backendProbeLock.lock()
        backendProbingSuspended = true
        backendProbeGeneration &+= 1
        consecutiveBackendProbeFailures = 0
        let timer = backendProbeTimer
        backendProbeTimer = nil
        let probe = activeBackendProbe
        activeBackendProbe = nil
        let pendingStartCompletion = pendingStartCompletion
        self.pendingStartCompletion = nil
        let reporter = reporter
        self.reporter = nil
        proxy = nil
        backendProbeLock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
        probe?.cancel()
        pendingStartCompletion?.call(DNSProxyBootstrapError.cancelledDuringStartup)
        tcpRelays.cancelAll()
        udpSessions.cancelAll()
        reporter?.stop(category: .cancelled)
        runtime.stop()
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        guard let tcpFlow = flow as? NEAppProxyTCPFlow else { return true }
        let runtimeState = runtimeDataPlaneSnapshot()
        guard let proxy = runtimeState.proxy,
              let destination = DNSProxyEndpointCompatibility.tcpDestination(tcpFlow)
        else {
            reject(flow, category: .flowConversionFailed)
            return true
        }
        let identifier = UUID()
        runtimeState.reporter?.beginFlow(identifier, transportProtocol: .tcp)
        let reporter = runtimeState.reporter
        let observer: @Sendable (AppRoutingRelaySnapshot) -> Void = { snapshot in
            reporter?.observe(
                snapshot,
                flowIdentifier: identifier,
                transportProtocol: .tcp
            )
        }
        if isTrustedMClashComponent(tcpFlow) {
            // Mihomo's own DNS egress must not be sent back through Mihomo's
            // SOCKS listener. Relay it from the provider process, whose own
            // sockets are outside the DNS interception path, to break the
            // otherwise recursive DNS→SOCKS→DNS loop.
            tcpRelays.startDirect(
                flow: tcpFlow,
                destination: destination,
                relayNote: "Trusted MClash DNS egress bypassed the private SOCKS listener.",
                activityObserver: observer
            )
        } else {
            tcpRelays.startMihomo(
                flow: tcpFlow,
                proxy: proxy,
                destination: destination,
                unavailableFallback: .reject,
                activityObserver: observer
            )
        }
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
        guard reporter != nil, proxy != nil else {
            backendProbeLock.unlock()
            return
        }
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
        timer.schedule(deadline: .now() + .seconds(4), repeating: .seconds(4))
        timer.setEventHandler { [weak self] in self?.runBackendProbe() }
        timer.resume()
        backendProbeTimer = timer
        backendProbeLock.unlock()
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
              let proxy,
              let reporter
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
            let currentReporter = self.reporter === reporter ? reporter : nil
            self.backendProbeLock.unlock()

            if error == nil {
                try? currentReporter?.markRunning()
            } else if stableFailure {
                currentReporter?.markBackendUnavailable(.backendUnavailable)
            }
        }
    }

    private func handleUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialDestination: SOCKS5Endpoint
    ) -> Bool {
        let runtimeState = runtimeDataPlaneSnapshot()
        guard let proxy = runtimeState.proxy else {
            reject(flow, category: .backendUnavailable)
            return true
        }
        let parentIdentifier = UUID()
        let bypassMihomo = isTrustedMClashComponent(flow)
        let initialPlan = dnsPlan(
            destination: initialDestination,
            proxy: bypassMihomo ? nil : proxy,
            bypassMihomo: bypassMihomo,
            parentIdentifier: parentIdentifier
        )
        let reporter = runtimeState.reporter
        let started = udpSessions.start(
            id: parentIdentifier,
            flow: flow,
            initialPlan: initialPlan,
            planner: { [weak self] destination in
                guard let self,
                      let proxy = self.runtimeDataPlaneSnapshot().proxy else {
                    return initialPlan
                }
                return self.dnsPlan(
                    destination: destination,
                    proxy: bypassMihomo ? nil : proxy,
                    bypassMihomo: bypassMihomo,
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
        proxy: ProviderSOCKSConfiguration?,
        bypassMihomo: Bool,
        parentIdentifier: UUID
    ) -> UDPFlowInterceptionPlan {
        let decision = FlowTrafficDecision(
            disposition: bypassMihomo ? .direct : .mihomo(.profileRules),
            reason: bypassMihomo
                ? .rule(.builtInBypass(.trustedMClashComponent))
                : .rule(.defaultDirect)
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
            configuredAction: bypassMihomo ? .direct : .mihomo(.profileRules),
            effectiveAction: bypassMihomo ? .direct : .mihomo(.profileRules),
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

    private func isTrustedMClashComponent(_ flow: NEAppProxyFlow) -> Bool {
        guard let auditToken = flow.metaData.sourceAppAuditToken else { return false }
        return trustedComponentPolicy.contains(
            identityResolver.resolve(sourceAppAuditToken: auditToken)
        )
    }

    private func reject(
        _ flow: NEAppProxyFlow,
        category: DNSProxyFailureCategory
    ) {
        let reporter = runtimeDataPlaneSnapshot().reporter
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

    private func runtimeDataPlaneSnapshot() -> (
        reporter: DNSProxyRuntimeReporter?,
        proxy: ProviderSOCKSConfiguration?
    ) {
        backendProbeLock.lock()
        let snapshot = (reporter, proxy)
        backendProbeLock.unlock()
        return snapshot
    }

    private static func data(_ value: Any?) -> Data? {
        switch value {
        case let value as Data: value
        case let value as NSData: value as Data
        default: nil
        }
    }
}

private final class DNSProxyStartCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let completion: (Error?) -> Void
    private var completed = false

    init(_ completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    func call(_ error: Error?) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
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
