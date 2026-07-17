import Foundation
import MClashNetworkShared

enum MClashNetworkExtensionIdentifiers {
    static let systemExtension = "one.leaper.mclash.network-extension"
    static let localizedDescription = "MClash Application Proxy"
}

struct NetworkExtensionRuntimeConfiguration: Equatable, Sendable {
    let revision: UInt64
    let dnsEnabled: Bool
    let failOpen: Bool
    let captureEnabled: Bool
    let encodedCaptureSnapshot: Data?
    let mihomoListener: NetworkExtensionMihomoListenerConfiguration?

    init(revision: UInt64, dnsEnabled: Bool = true, failOpen: Bool = true) {
        self.revision = revision
        self.dnsEnabled = dnsEnabled
        self.failOpen = failOpen
        captureEnabled = true
        encodedCaptureSnapshot = nil
        mihomoListener = nil
    }

    init(
        preferences: NetworkCapturePreferences,
        mihomoListener: NetworkExtensionMihomoListenerConfiguration
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
        dnsEnabled = preferences.enabled && preferences.dnsEnabled
        failOpen = preferences.failOpen
        captureEnabled = preferences.enabled
        self.encodedCaptureSnapshot = encodedSnapshot
        self.mihomoListener = mihomoListener
    }

    var providerConfiguration: [String: NSObject] {
        var configuration: [String: NSObject] = [
            "revision": NSNumber(value: revision),
            "captureEnabled": NSNumber(value: captureEnabled),
            "failOpen": NSNumber(value: failOpen),
        ]
        if let encodedCaptureSnapshot {
            configuration["captureConfigurationSnapshot"] = encodedCaptureSnapshot as NSData
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
}

enum NetworkExtensionRuntimeConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case invalidRevision(UInt64)
    case snapshotTooLarge(actual: Int, maximum: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidRevision(revision):
            "Network capture revision must be greater than zero; received \(revision)."
        case let .snapshotTooLarge(actual, maximum):
            "Encoded network capture rules are \(actual) bytes; the maximum is \(maximum)."
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
        var message = underlyingError.localizedDescription
        if underlyingError.domain != NSCocoaErrorDomain {
            message += " (\(underlyingError.domain) \(underlyingError.code))"
        }
        self.init(operation: operation, message: message)
    }

    var errorDescription: String? {
        "\(operation.displayName): \(message)"
    }
}

private extension NetworkExtensionControlOperation {
    var displayName: String {
        switch self {
        case .activateSystemExtension: "System extension installation"
        case .configureTransparentProxy: "Network filter configuration"
        case .startTransparentProxy: "Network filter startup"
        case .configureDNSProxy: "DNS proxy configuration"
        case .disableDNSProxy: "DNS proxy shutdown"
        case .stopTransparentProxy: "Network filter shutdown"
        case .deactivateSystemExtension: "System extension removal"
        case .stateTransition: "Network Extension state transition"
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
            return "Invalid network extension transition from \(phase.rawValue): \(event)"
        }
    }
}
