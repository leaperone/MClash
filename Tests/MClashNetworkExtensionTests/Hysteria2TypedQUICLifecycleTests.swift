import Foundation
import Testing
@testable import MClashNetworkExtension

@Suite("Hysteria2 typed QUIC lifecycle timing")
struct Hysteria2TypedQUICLifecycleTests {
    @Test("Readiness completion is delivered exactly once across ready/failure/cancel races")
    func completionGateIsExactlyOnce() async {
        let gate = NativeHysteria2ContinuationGate()
        let counter = CompletionCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    gate.resume {
                        counter.increment()
                    }
                }
            }
        }
        #expect(counter.value == 1)
    }

    @Test("A cancellation/failure callback cannot resume an already-ready wait")
    func firstLifecycleResultWins() {
        let gate = NativeHysteria2ContinuationGate()
        var results = [String]()
        gate.resume { results.append("ready") }
        gate.resume { results.append("failure") }
        gate.resume { results.append("cancelled") }
        #expect(results == ["ready"])
    }
}

private final class CompletionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }
}
