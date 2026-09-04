import Foundation

/// Bounded native observation fan-out. The store is intentionally connector
/// neutral and retains only the latest observation per flow, preventing a
/// busy listener from growing memory without bound.
public actor NativeFlowObservationStore {
    public let stream: AsyncStream<FlowRelayObservation>
    private let continuation: AsyncStream<FlowRelayObservation>.Continuation
    private var values: [String: FlowRelayObservation] = [:]
    private var order: [String] = []
    public let capacity: Int

    public init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
        let pair = AsyncStream<FlowRelayObservation>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, capacity))
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    public func receive(_ observation: FlowRelayObservation) {
        if values[observation.id] == nil { order.append(observation.id) }
        values[observation.id] = observation
        while order.count > capacity {
            values.removeValue(forKey: order.removeFirst())
        }
        continuation.yield(observation)
    }

    public func snapshot() -> [FlowRelayObservation] {
        order.compactMap { values[$0] }
    }

    public func finish() { continuation.finish() }
}
