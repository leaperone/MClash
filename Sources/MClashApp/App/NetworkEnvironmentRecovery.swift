import AppKit
import Foundation
import Network

enum NetworkEnvironmentEvent: Equatable, Sendable {
    case willSleep
    case didWake
    case pathChanged(NetworkEnvironmentPath)
}

struct NetworkEnvironmentPath: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case satisfied
        case unsatisfied
        case requiresConnection
    }

    enum InterfaceKind: String, Hashable, Sendable {
        case wiredEthernet
        case wifi
        case cellular
        case loopback
        case other
    }

    let status: Status
    let isExpensive: Bool
    let isConstrained: Bool
    let supportsDNS: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool
    let interfaces: Set<InterfaceKind>

    var isUsable: Bool { status == .satisfied }

    init(
        status: Status,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        supportsDNS: Bool = true,
        supportsIPv4: Bool = true,
        supportsIPv6: Bool = false,
        interfaces: Set<InterfaceKind> = []
    ) {
        self.status = status
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsDNS = supportsDNS
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.interfaces = interfaces
    }

    init(_ path: NWPath) {
        status = switch path.status {
        case .satisfied: .satisfied
        case .unsatisfied: .unsatisfied
        case .requiresConnection: .requiresConnection
        @unknown default: .unsatisfied
        }
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        supportsDNS = path.supportsDNS
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
        interfaces = Set(path.availableInterfaces.map { interface in
            switch interface.type {
            case .wiredEthernet: .wiredEthernet
            case .wifi: .wifi
            case .cellular: .cellular
            case .loopback: .loopback
            case .other: .other
            @unknown default: .other
            }
        })
    }
}

@MainActor
protocol NetworkEnvironmentMonitoring: AnyObject {
    func start() -> AsyncStream<NetworkEnvironmentEvent>
    func stop()
}

/// Converts AppKit power events and Network.framework path updates into one
/// restartable stream. The first NWPath callback establishes a baseline; only
/// later changes are emitted so ordinary application startup does not schedule
/// a redundant recovery pass.
@MainActor
final class AppleNetworkEnvironmentMonitor: NetworkEnvironmentMonitoring {
    private let workspaceNotificationCenter: NotificationCenter
    private let pathQueue = DispatchQueue(
        label: "one.leaper.mclash.network-environment-path",
        qos: .utility
    )

    private var continuation: AsyncStream<NetworkEnvironmentEvent>.Continuation?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    private var lastPath: NetworkEnvironmentPath?

    init(
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
    }

    func start() -> AsyncStream<NetworkEnvironmentEvent> {
        stop()
        let pair = AsyncStream<NetworkEnvironmentEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        continuation = pair.continuation

        workspaceObservers = [
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.yield(.willSleep) }
            },
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.yield(.didWake) }
            },
        ]

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = NetworkEnvironmentPath(path)
            Task { @MainActor in self?.receive(snapshot) }
        }
        pathMonitor = monitor
        monitor.start(queue: pathQueue)
        return pair.stream
    }

    func stop() {
        pathMonitor?.pathUpdateHandler = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        for observer in workspaceObservers {
            workspaceNotificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll(keepingCapacity: false)
        continuation?.finish()
        continuation = nil
        lastPath = nil
    }

    private func receive(_ path: NetworkEnvironmentPath) {
        guard lastPath != nil else {
            lastPath = path
            return
        }
        // NWPathMonitor already coalesces unchanged paths. Emit every later
        // callback because switching between two Wi-Fi networks can preserve
        // the same coarse status/interface flags while replacing the route.
        lastPath = path
        yield(.pathChanged(path))
    }

    private func yield(_ event: NetworkEnvironmentEvent) {
        continuation?.yield(event)
    }
}

struct NetworkEnvironmentRecoveryPolicy: Sendable {
    struct Configuration: Equatable, Sendable {
        let debounceInterval: TimeInterval
        let minimumRecoveryInterval: TimeInterval
        let failureWindow: TimeInterval
        let maximumFailedRecoveries: Int

        static let live = Configuration(
            debounceInterval: 3,
            minimumRecoveryInterval: 30,
            failureWindow: 5 * 60,
            maximumFailedRecoveries: 3
        )

        init(
            debounceInterval: TimeInterval,
            minimumRecoveryInterval: TimeInterval,
            failureWindow: TimeInterval,
            maximumFailedRecoveries: Int
        ) {
            precondition(debounceInterval >= 0)
            precondition(minimumRecoveryInterval >= 0)
            precondition(failureWindow > 0)
            precondition(maximumFailedRecoveries > 0)
            self.debounceInterval = debounceInterval
            self.minimumRecoveryInterval = minimumRecoveryInterval
            self.failureWindow = failureWindow
            self.maximumFailedRecoveries = maximumFailedRecoveries
        }
    }

    enum Directive: Equatable, Sendable {
        case none
        case cancelScheduledRecovery
        case schedule(after: TimeInterval)
        case recover
        case suppressAfterRepeatedFailures
    }

    private let configuration: Configuration
    private(set) var isArmed = false
    private(set) var isSleeping = false
    private(set) var recoveryIsInProgress = false
    private(set) var recoveryIsScheduled = false
    private var pathIsUsable: Bool?
    private var recoveryRequested = false
    private var lastRecoveryStartedAt: Date?
    private var failedRecoveryDates: [Date] = []

    init(configuration: Configuration = .live) {
        self.configuration = configuration
    }

    mutating func setArmed(_ armed: Bool, at now: Date = Date()) -> Directive {
        guard armed != isArmed else { return .none }
        isArmed = armed
        guard armed else {
            recoveryRequested = false
            recoveryIsScheduled = false
            failedRecoveryDates.removeAll(keepingCapacity: true)
            return .cancelScheduledRecovery
        }
        trimFailures(at: now)
        return .none
    }

    mutating func receive(
        _ event: NetworkEnvironmentEvent,
        at now: Date = Date()
    ) -> Directive {
        switch event {
        case .willSleep:
            isSleeping = true
            recoveryRequested = false
            recoveryIsScheduled = false
            return .cancelScheduledRecovery

        case .didWake:
            isSleeping = false
            recoveryRequested = true
            return scheduleIfPossible(at: now)

        case let .pathChanged(path):
            pathIsUsable = path.isUsable
            recoveryRequested = true
            guard path.isUsable else {
                recoveryIsScheduled = false
                return .cancelScheduledRecovery
            }
            return scheduleIfPossible(at: now)
        }
    }

    mutating func scheduledRecoveryFired(at now: Date = Date()) -> Directive {
        recoveryIsScheduled = false
        guard isArmed,
              !isSleeping,
              pathIsUsable != false,
              recoveryRequested,
              !recoveryIsInProgress else { return .none }

        trimFailures(at: now)
        guard failedRecoveryDates.count < configuration.maximumFailedRecoveries else {
            recoveryRequested = false
            return .suppressAfterRepeatedFailures
        }

        let cooldown = remainingCooldown(at: now)
        guard cooldown <= 0 else {
            recoveryIsScheduled = true
            return .schedule(after: cooldown)
        }

        recoveryRequested = false
        recoveryIsInProgress = true
        lastRecoveryStartedAt = now
        return .recover
    }

    mutating func recoveryCompleted(
        succeeded: Bool,
        at now: Date = Date()
    ) -> Directive {
        guard recoveryIsInProgress else { return .none }
        recoveryIsInProgress = false
        if succeeded {
            failedRecoveryDates.removeAll(keepingCapacity: true)
        } else {
            failedRecoveryDates.append(now)
            recoveryRequested = true
        }
        return scheduleIfPossible(at: now)
    }

    private mutating func scheduleIfPossible(at now: Date) -> Directive {
        guard isArmed, !isSleeping, pathIsUsable != false else { return .none }
        guard !recoveryIsInProgress else { return .none }
        let delay = max(configuration.debounceInterval, remainingCooldown(at: now))
        recoveryIsScheduled = true
        return .schedule(after: delay)
    }

    private func remainingCooldown(at now: Date) -> TimeInterval {
        guard let lastRecoveryStartedAt else { return 0 }
        return max(
            0,
            configuration.minimumRecoveryInterval
                - now.timeIntervalSince(lastRecoveryStartedAt)
        )
    }

    private mutating func trimFailures(at now: Date) {
        let failureWindow = configuration.failureWindow
        failedRecoveryDates.removeAll {
            now.timeIntervalSince($0) >= failureWindow
        }
    }
}
