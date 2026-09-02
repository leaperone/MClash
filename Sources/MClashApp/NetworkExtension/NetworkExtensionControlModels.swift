import Foundation
import MClashNetworkShared

enum MClashNetworkExtensionIdentifiers {
    static let systemExtension = "one.leaper.mclash.network-extension"
    static let localizedDescription = "MClash Application Proxy"
}

struct NetworkExtensionRuntimeConfiguration: Equatable, Sendable {
    let revision: UInt64
    let activationIdentifier: UUID
    let dnsEnabled: Bool
    let failOpen: Bool
    let captureEnabled: Bool
    let encodedCaptureSnapshot: Data?
    let encodedMihomoRouteProxyCatalog: Data?
    let encodedDNSProxyBootstrap: Data?
    let mihomoListener: NetworkExtensionMihomoListenerConfiguration?
    let dnsUpstreamMode: DNSUpstreamMode

    init(
        revision: UInt64,
        dnsEnabled: Bool = true,
        failOpen: Bool = true,
        dnsUpstreamMode: DNSUpstreamMode = .mihomo,
        activationIdentifier: UUID = UUID()
    ) {
        self.revision = revision
        self.activationIdentifier = activationIdentifier
        self.dnsEnabled = dnsEnabled
        self.failOpen = failOpen
        self.dnsUpstreamMode = dnsUpstreamMode
        captureEnabled = true
        encodedCaptureSnapshot = nil
        encodedMihomoRouteProxyCatalog = nil
        encodedDNSProxyBootstrap = nil
        mihomoListener = nil
    }

    init(
        preferences: NetworkCapturePreferences,
        mihomoListener: NetworkExtensionMihomoListenerConfiguration,
        routeProxyEndpoints: [MihomoRouteProxyEndpoint]? = nil,
        dnsUpstreamMode: DNSUpstreamMode = .mihomo,
        activationIdentifier: UUID = UUID()
    ) throws {
        try preferences.snapshot.validate()
        guard preferences.snapshot.revision > 0 else {
            throw NetworkExtensionRuntimeConfigurationError.invalidRevision(
                preferences.snapshot.revision
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encodedSnapshot = try encoder.encode(preferences.snapshot)
        guard encodedSnapshot.count <= CaptureConfigurationSnapshotLoader.maximumEncodedSize else {
            throw NetworkExtensionRuntimeConfigurationError.snapshotTooLarge(
                actual: encodedSnapshot.count,
                maximum: CaptureConfigurationSnapshotLoader.maximumEncodedSize
            )
        }

        revision = preferences.snapshot.revision
        self.activationIdentifier = activationIdentifier
        dnsEnabled = preferences.enabled && preferences.dnsEnabled
        failOpen = preferences.failOpen
        self.dnsUpstreamMode = dnsUpstreamMode
        captureEnabled = preferences.enabled
        self.encodedCaptureSnapshot = encodedSnapshot
        let endpoints = try routeProxyEndpoints ?? mihomoListener.routeProxyEndpoints()
        let routeProxyCatalog = try MihomoRouteProxyCatalog.encode(endpoints)
        encodedMihomoRouteProxyCatalog = routeProxyCatalog
        guard let profileRulesProxy = endpoints.first(where: { $0.route == .profileRules }) else {
            throw NetworkExtensionRuntimeConfigurationError.missingProfileRulesProxy
        }
        encodedDNSProxyBootstrap = try DNSProxyBootstrapConfiguration(
            revision: revision,
            activationIdentifier: activationIdentifier,
            profileRulesProxy: profileRulesProxy,
            routeProxyEndpoints: endpoints,
            encodedCaptureSnapshot: encodedSnapshot,
            dnsUpstreamMode: dnsUpstreamMode
        ).encoded()
        self.mihomoListener = mihomoListener
    }

    var providerConfiguration: [String: NSObject] {
        var configuration: [String: NSObject] = [
            "revision": NSNumber(value: revision),
            "activationIdentifier": activationIdentifier.uuidString as NSString,
            "captureEnabled": NSNumber(value: captureEnabled),
            "failOpen": NSNumber(value: failOpen),
        ]
        if let encodedCaptureSnapshot {
            configuration["captureConfigurationSnapshot"] = encodedCaptureSnapshot as NSData
        }
        if let encodedMihomoRouteProxyCatalog {
            configuration["mihomoRouteProxyCatalog"] = encodedMihomoRouteProxyCatalog as NSData
        }
        if let encodedDNSProxyBootstrap {
            configuration["dnsProxyBootstrap"] = encodedDNSProxyBootstrap as NSData
        }
        if let mihomoListener {
            configuration["mihomoSOCKSHost"] = mihomoListener.ipv4Endpoint.host as NSString
            configuration["mihomoSOCKSPort"] = NSNumber(value: mihomoListener.port)
            if let authentication = mihomoListener.authentication {
                configuration["mihomoSOCKSUsername"] = authentication.username as NSString
                configuration["mihomoSOCKSPassword"] = authentication.password as NSString
            }
        }
        return configuration
    }

    /// A live update may add private Mihomo routes, but it must never move or
    /// re-key an endpoint that an existing Transparent/DNS relay already
    /// captured. AppModel keeps removed routes as an idle listener superset
    /// until the next cold start, so every live topology change is monotonic.
    func preservesExistingRouteEndpoints(
        from previous: NetworkExtensionRuntimeConfiguration
    ) -> Bool {
        switch (
            previous.encodedMihomoRouteProxyCatalog,
            encodedMihomoRouteProxyCatalog
        ) {
        case (nil, nil):
            return true
        case let (previousData?, candidateData?):
            guard let previousEndpoints = try? MihomoRouteProxyCatalog.decode(
                previousData
            ),
            let candidateEndpoints = try? MihomoRouteProxyCatalog.decode(
                candidateData
            ) else {
                return false
            }
            let candidateByRoute = Dictionary(
                uniqueKeysWithValues: candidateEndpoints.map { ($0.route, $0) }
            )
            return previousEndpoints.allSatisfy {
                candidateByRoute[$0.route] == $0
            }
        default:
            return false
        }
    }
}

enum NetworkExtensionRuntimeConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case invalidRevision(UInt64)
    case snapshotTooLarge(actual: Int, maximum: Int)
    case missingProfileRulesProxy

    var errorDescription: String? {
        switch self {
        case let .invalidRevision(revision):
            AppLocalization.format(
                "Network capture revision must be greater than zero; received %@.",
                String(revision)
            )
        case let .snapshotTooLarge(actual, maximum):
            AppLocalization.format(
                "Encoded network capture rules are %@ bytes; the maximum is %@.",
                String(actual),
                String(maximum)
            )
        case .missingProfileRulesProxy:
            AppLocalization.string(
                "The private Mihomo listener catalog is missing the profile-rules route required by DNS Routing."
            )
        }
    }
}

enum SystemExtensionRequestProgress: Equatable, Sendable {
    case awaitingUserApproval
}

enum SystemExtensionRequestOutcome: Equatable, Sendable {
    case completed
    case requiresReboot
}

enum NetworkExtensionEnableOutcome: Equatable, Sendable {
    case running
    case requiresReboot
}

enum NetworkExtensionEnableProgress: Equatable, Sendable {
    case awaitingSystemExtensionApproval
}

enum NetworkExtensionUninstallOutcome: Equatable, Sendable {
    case uninstalled
    case requiresReboot
}

enum NetworkExtensionControlOperation: String, Equatable, Sendable {
    case activateSystemExtension
    case configureTransparentProxy
    case startTransparentProxy
    case configureDNSProxy
    case inspectDNSProxy
    case disableDNSProxy
    case stopTransparentProxy
    case deactivateSystemExtension
    case stateTransition
}

struct NetworkExtensionControlFailure: Error, Equatable, Sendable, LocalizedError {
    let operation: NetworkExtensionControlOperation
    let message: String

    init(operation: NetworkExtensionControlOperation, message: String) {
        self.operation = operation
        self.message = message
    }

    init(operation: NetworkExtensionControlOperation, underlying error: Error) {
        if let failure = error as? NetworkExtensionControlFailure {
            self.init(operation: operation, message: failure.message)
            return
        }
        let underlyingError = error as NSError
        var message: String
        if underlyingError.domain == "OSSystemExtensionErrorDomain",
           underlyingError.code == 9 {
            message = AppLocalization.string(
                "macOS rejected the Network Extension package during validation. Install the latest MClash update or reinstall the application"
            )
        } else {
            message = underlyingError.localizedDescription
        }
        if underlyingError.domain != NSCocoaErrorDomain {
            message += " (\(underlyingError.domain) \(underlyingError.code))"
        }
        self.init(operation: operation, message: message)
    }

    var errorDescription: String? {
        AppLocalization.format("%@: %@", operation.displayName, message)
    }
}

private extension NetworkExtensionControlOperation {
    var displayName: String {
        switch self {
        case .activateSystemExtension:
            AppLocalization.string("System extension installation")
        case .configureTransparentProxy:
            AppLocalization.string("Network filter configuration")
        case .startTransparentProxy:
            AppLocalization.string("Network filter startup")
        case .configureDNSProxy:
            AppLocalization.string("DNS proxy configuration")
        case .inspectDNSProxy:
            AppLocalization.string("DNS proxy status")
        case .disableDNSProxy:
            AppLocalization.string("DNS proxy shutdown")
        case .stopTransparentProxy:
            AppLocalization.string("Network filter shutdown")
        case .deactivateSystemExtension:
            AppLocalization.string("System extension removal")
        case .stateTransition:
            AppLocalization.string("Network Extension state transition")
        }
    }
}

enum NetworkExtensionControlPhase: String, Equatable, Sendable {
    case inactive
    case activatingSystemExtension
    case configuringTransparentProxy
    case startingTransparentProxy
    case configuringDNSProxy
    case running
    case disablingDNSProxy
    case stoppingTransparentProxy
    case deactivatingSystemExtension
    case requiresReboot
    case uninstalled
    case failed
}

struct NetworkExtensionControlState: Equatable, Sendable {
    var phase: NetworkExtensionControlPhase
    var revision: UInt64?
    var dnsRequested: Bool
    var userApprovalRequired: Bool
    var failure: NetworkExtensionControlFailure?

    static let inactive = NetworkExtensionControlState(
        phase: .inactive,
        revision: nil,
        dnsRequested: false,
        userApprovalRequired: false,
        failure: nil
    )
}

enum NetworkExtensionControlEvent: Equatable, Sendable {
    case beginEnable(revision: UInt64, dnsEnabled: Bool)
    case systemExtensionNeedsApproval
    case systemExtensionActivated
    case transparentProxyConfigured
    case transparentProxyStarted
    case dnsProxyConfigured
    case beginDisable
    case dnsProxyDisabled
    case transparentProxyStopped
    case beginDeactivation
    case systemExtensionDeactivated
    case rebootRequired
    case failed(NetworkExtensionControlFailure)
}

enum NetworkExtensionStateReductionError: Error, Equatable, Sendable, LocalizedError {
    case invalidTransition(
        phase: NetworkExtensionControlPhase,
        event: NetworkExtensionControlEvent
    )

    var errorDescription: String? {
        switch self {
        case let .invalidTransition(phase, event):
            return AppLocalization.format(
                "Invalid network extension transition from %@: %@",
                phase.rawValue,
                String(describing: event)
            )
        }
    }
}
