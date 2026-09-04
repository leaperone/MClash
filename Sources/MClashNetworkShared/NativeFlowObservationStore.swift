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

    public func finish() {
        let continuations = subscribers.values
        subscribers.removeAll()
        for continuation in continuations { continuation.finish() }
    }

    private func removeSubscriber(_ identifier: UUID) {
        subscribers.removeValue(forKey: identifier)
    }
}
