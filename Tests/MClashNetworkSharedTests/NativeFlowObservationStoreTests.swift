import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Native flow observation store")
struct NativeFlowObservationStoreTests {
    @Test("Keeps latest value per flow and bounds retention")
    func boundedLatest() async {
        let store = NativeFlowObservationStore(capacity: 2)
        await store.receive(FlowRelayObservation(id: "a", uploadBytes: 1))
        await store.receive(FlowRelayObservation(id: "b", uploadBytes: 2))
        await store.receive(FlowRelayObservation(id: "a", uploadBytes: 3, state: .completed))
        await store.receive(FlowRelayObservation(id: "c", uploadBytes: 4))
        let snapshot = await store.snapshot()
        #expect(snapshot.count == 2)
        #expect(snapshot.map(\.id) == ["a", "c"])
        #expect(snapshot.first?.uploadBytes == 3)
        #expect(snapshot.first?.state == .completed)
    }

    @Test("Observation values do not carry connector credentials")
    func noSecrets() async throws {
        let store = NativeFlowObservationStore(capacity: 1)
        await store.receive(FlowRelayObservation(id: "flow", connector: "socks5", routeChain: ["group"]))
        let value = try #require(await store.snapshot().first)
        #expect(!String(describing: value).contains("password"))
    }
}
