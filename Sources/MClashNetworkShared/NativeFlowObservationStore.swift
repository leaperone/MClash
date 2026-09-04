import Foundation

/// Bounded native observation fan-out. The store is intentionally connector
/// neutral and retains only the latest observation per flow, preventing a
/// busy listener from growing memory without bound. Each consumer receives an
/// independent bounded stream so reconnecting a runtime cannot race a cancelled
/// iterator left over from the previous session.
public actor NativeFlowObservationStore {
    private var values: [String: FlowRelayObservation] = [:]
    private var order: [String] = []
    private var subscribers: [
        UUID: AsyncStream<FlowRelayObservation>.Continuation
    ] = [:]
    public let capacity: Int

    public init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    public func makeStream() -> AsyncStream<FlowRelayObservation> {
        let identifier = UUID()
        let pair = AsyncStream<FlowRelayObservation>.makeStream(
            bufferingPolicy: .bufferingNewest(capacity)
        )
        subscribers[identifier] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(identifier) }
        }
        return pair.stream
    }

    public func receive(_ observation: FlowRelayObservation) {
        if values[observation.id] != nil {
            order.removeAll { $0 == observation.id }
        }
        order.append(observation.id)
        values[observation.id] = observation
        while order.count > capacity {
            values.removeValue(forKey: order.removeFirst())
        }
        for continuation in subscribers.values {
            continuation.yield(observation)
        }
    }

    public func snapshot() -> [FlowRelayObservation] {
        order.compactMap { values[$0] }
    }

    /// Gracefully terminally closes observations when the owning runtime is
    /// stopped. Network callbacks can arrive after a listener has been
    /// cancelled (or not arrive at all), so relying only on the transport
    /// callback would leave the monitor showing a flow as live forever.
    @discardableResult
    public func finishActive() -> Int {
        var finished = 0
        for identifier in order {
            guard let current = values[identifier], current.state == .active else {
                continue
            }
            let terminal = FlowRelayObservation(
                id: current.id,
                startedAt: current.startedAt,
                endedAt: Date(),
                network: current.network,
                destinationHost: current.destinationHost,
                destinationIP: current.destinationIP,
                destinationPort: current.destinationPort,
                process: current.process,
                processPath: current.processPath,
                inboundName: current.inboundName,
                rule: current.rule,
                rulePayload: current.rulePayload,
                routeChain: current.routeChain,
                providerChain: current.providerChain,
                connector: current.connector,
                uploadBytes: current.uploadBytes,
                downloadBytes: current.downloadBytes,
                state: .completed,
                route: current.route,
                failureReason: current.failureReason
            )
            values[identifier] = terminal
            for continuation in subscribers.values {
                continuation.yield(terminal)
            }
            finished += 1
        }
        return finished
    }

    public func finish() {
        let continuations = subscribers.values
        subscribers.removeAll()
        for continuation in continuations { continuation.finish() }
    }

    private func removeSubscriber(_ identifier: UUID) {
        subscribers.removeValue(forKey: identifier)
    }
}
