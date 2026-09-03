import Foundation
import Testing
@testable import MClashApp

@Suite("Connection snapshot ordering")
struct ConnectionSnapshotOrderingTests {
    @Test("ordering is independent of source order")
    func orderingIsDeterministic() {
        let older = fixture(id: "older", start: "2026-01-01T00:00:00Z")
        let newer = fixture(id: "newer", start: "2026-01-02T00:00:00Z")
        let first = ConnectionSnapshotOrdering.stableNewestFirst([older, newer])
        let second = ConnectionSnapshotOrdering.stableNewestFirst([newer, older])
        #expect(first.map(\.id) == ["newer", "older"])
        #expect(second.map(\.id) == first.map(\.id))
    }

    @Test("identical timestamps use the connection ID as a tie breaker")
    func identicalTimestampsUseID() {
        let zulu = fixture(id: "zulu", start: "2026-01-01T00:00:00Z")
        let alpha = fixture(id: "alpha", start: "2026-01-01T00:00:00Z")
        #expect(ConnectionSnapshotOrdering.stableNewestFirst([zulu, alpha]).map(\.id) == ["alpha", "zulu"])
    }

    private func fixture(id: String, start: String) -> MihomoConnection {
        let json = #"{"id":"\#(id)","metadata":{"network":"tcp","type":"HTTP","destinationIP":"1.1.1.1","destinationPort":"443","host":"example.com","process":"Test"},"upload":0,"download":0,"start":"\#(start)","chains":[],"providerChains":[],"rule":"DIRECT","rulePayload":""}"#
        return try! JSONDecoder().decode(MihomoConnection.self, from: Data(json.utf8))
    }
}
