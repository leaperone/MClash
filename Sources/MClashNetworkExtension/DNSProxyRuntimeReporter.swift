import Foundation
import MClashNetworkShared

/// Aggregates DNS relay lifecycle and delivery-boundary bytes into the bounded
/// App Group heartbeat consumed by the host app.
final class DNSProxyRuntimeReporter: @unchecked Sendable {
    private struct FlowState {
        let transportProtocol: TransportProtocol
        var uploadBytes: UInt64 = 0
        var downloadBytes: UInt64 = 0
        var terminal = false
    }

    private let lock = NSLock()
    private let file: DNSProxyStatusFile
    private let heartbeatQueue = DispatchQueue(
        label: "one.leaper.mclash.dns-runtime-heartbeat"
    )
    private var heartbeat: DispatchSourceTimer?
    private var status: DNSProxyRuntimeStatus
    private var flows: [UUID: FlowState] = [:]
    private var stopped = false

    convenience init(
        revision: UInt64,
        activationIdentifier: UUID,
        now: Date = Date()
    ) throws {
        try self.init(
            revision: revision,
            activationIdentifier: activationIdentifier,
            file: try DNSProxyStatusFile(),
            now: now
        )
    }

    init(
        revision: UInt64,
        activationIdentifier: UUID,
        file: DNSProxyStatusFile,
        now: Date = Date()
    ) throws {
        self.file = file
        status = DNSProxyRuntimeStatus(
            revision: revision,
            activationIdentifier: activationIdentifier,
            phase: .starting,
            backendReady: false,
            startedAt: now
        )
        try file.write(status)
    }

    func startHeartbeat() {
        lock.lock()
        guard heartbeat == nil else {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        heartbeat = timer
        lock.unlock()
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in self?.recordHeartbeat() }
        timer.resume()
    }

    func markRunning() throws {
        try mutateAndPublish { value, now in
            self.stopped = false
            value.phase = .running
            value.backendReady = true
            value.lastBackendAssociationAt = now
            value.updatedAt = now
        }
    }

    func beginFlow(_ identifier: UUID, transportProtocol: TransportProtocol) {
        publishBestEffort { value, now in
            guard !self.stopped else { return }
            guard self.flows[identifier] == nil else { return }
            self.flows[identifier] = FlowState(transportProtocol: transportProtocol)
            value.totalFlows = Self.increment(value.totalFlows)
            switch transportProtocol {
            case .tcp: value.activeTCPFlows = Self.increment(value.activeTCPFlows)
            case .udp: value.activeUDPFlows = Self.increment(value.activeUDPFlows)
            }
            value.updatedAt = now
        }
    }

    func observe(
        _ snapshot: AppRoutingRelaySnapshot,
        flowIdentifier: UUID,
        transportProtocol: TransportProtocol
    ) {
        publishBestEffort { value, now in
            guard !self.stopped else { return }
            if self.flows[flowIdentifier] == nil {
                self.flows[flowIdentifier] = FlowState(
                    transportProtocol: transportProtocol
                )
                value.totalFlows = Self.increment(value.totalFlows)
                switch transportProtocol {
                case .tcp: value.activeTCPFlows = Self.increment(value.activeTCPFlows)
                case .udp: value.activeUDPFlows = Self.increment(value.activeUDPFlows)
                }
            }
            guard var flow = self.flows[flowIdentifier], !flow.terminal else { return }
            let uploadDelta = Self.delta(
                new: snapshot.uploadBytes,
                old: flow.uploadBytes
            )
            let downloadDelta = Self.delta(
                new: snapshot.downloadBytes,
                old: flow.downloadBytes
            )
            value.uploadBytes = Self.add(value.uploadBytes, uploadDelta)
            value.downloadBytes = Self.add(value.downloadBytes, downloadDelta)
            if uploadDelta > 0 {
                value.lastQueryForwardedAt = now
            }
            if downloadDelta > 0 {
                value.lastResponseDeliveredAt = now
            }
            flow.uploadBytes = max(flow.uploadBytes, snapshot.uploadBytes)
            flow.downloadBytes = max(flow.downloadBytes, snapshot.downloadBytes)

            switch snapshot.state {
            case .ready, .relaying:
                break
            case .completed:
                flow.terminal = true
                Self.decrementActive(&value, transportProtocol: flow.transportProtocol)
                value.completedFlows = Self.increment(value.completedFlows)
            case .failed:
                flow.terminal = true
                Self.decrementActive(&value, transportProtocol: flow.transportProtocol)
                value.failedFlows = Self.increment(value.failedFlows)
                value.lastFailureAt = now
                value.failureCategory = transportProtocol == .tcp
                    ? .tcpRelayFailed
                    : .udpRelayFailed
            case .notApplicable, .pending, .connecting:
                break
            }
            self.flows[flowIdentifier] = flow
            value.updatedAt = now
        }
    }

    func markStartupFailed(_ category: DNSProxyFailureCategory) {
        publishBestEffort { value, now in
            value.phase = .failed
            value.backendReady = false
            value.lastFailureAt = now
            value.failureCategory = category
            value.updatedAt = now
        }
    }

    func markBackendUnavailable(_ category: DNSProxyFailureCategory) {
        publishBestEffort { value, now in
            guard !self.stopped else { return }
            value.phase = .running
            value.backendReady = false
            value.lastFailureAt = now
            value.failureCategory = category
            value.updatedAt = now
        }
    }

    /// Records the latest per-flow failure without changing the independently
    /// probed backend health. One malformed or failed DNS flow must not make
    /// the entire provider appear offline.
    func recordFlowFailure(_ category: DNSProxyFailureCategory) {
        publishBestEffort { value, now in
            guard !self.stopped else { return }
            value.lastFailureAt = now
            value.failureCategory = category
            value.updatedAt = now
        }
    }

    func stop(category: DNSProxyFailureCategory? = nil) {
        lock.lock()
        let timer = heartbeat
        heartbeat = nil
        lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()

        publishBestEffort { value, now in
            self.stopped = true
            let active = value.activeFlows
            value.failedFlows = Self.add(value.failedFlows, active)
            value.activeTCPFlows = 0
            value.activeUDPFlows = 0
            value.backendReady = false
            value.phase = .stopped
            if let category, active > 0 {
                value.lastFailureAt = now
                value.failureCategory = category
            }
            value.updatedAt = now
            self.flows.removeAll(keepingCapacity: false)
        }
    }

    private func recordHeartbeat() {
        publishBestEffort { value, now in value.updatedAt = now }
    }

    private func publishBestEffort(
        _ mutation: (inout DNSProxyRuntimeStatus, Date) -> Void
    ) {
        try? mutateAndPublish(mutation)
    }

    private func mutateAndPublish(
        _ mutation: (inout DNSProxyRuntimeStatus, Date) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        mutation(&status, Date())
        try file.write(status)
    }

    private static func decrementActive(
        _ status: inout DNSProxyRuntimeStatus,
        transportProtocol: TransportProtocol
    ) {
        switch transportProtocol {
        case .tcp:
            status.activeTCPFlows = status.activeTCPFlows > 0
                ? status.activeTCPFlows - 1
                : 0
        case .udp:
            status.activeUDPFlows = status.activeUDPFlows > 0
                ? status.activeUDPFlows - 1
                : 0
        }
    }

    private static func increment(_ value: UInt64) -> UInt64 {
        value == .max ? .max : value + 1
    }

    private static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }

    private static func delta(new: UInt64, old: UInt64) -> UInt64 {
        new >= old ? new - old : 0
    }
}
