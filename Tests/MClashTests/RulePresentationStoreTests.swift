import Foundation
import Testing
@testable import MClashApp

@Suite("Rule presentation store")
struct RulePresentationStoreTests {
    @MainActor
    @Test("Rapid repeated searches publish only the latest bounded result")
    func rapidRepeatedSearchesStayBounded() async throws {
        let store = RulePresentationStore()
        let rules = (0..<7_374).map { index in
            MihomoRule(
                index: index,
                type: index.isMultiple(of: 2) ? "DomainSuffix" : "ProcessName",
                payload: index.isMultiple(of: 3) ? "alpha-\(index)" : "beta-\(index)",
                proxy: index.isMultiple(of: 5) ? "Policy-A" : "Policy-B",
                size: 0,
                extra: nil
            )
        }

        store.updateRules(rules)
        try await waitUntil {
            !store.isPreparingRows && !store.isFiltering && store.totalMatches == rules.count
        }
        #expect(store.rows.count == 500)
        #expect(store.canLoadMore)

        store.updateSearch("alpha")
        store.updateSearch("beta")
        store.updateSearch("Policy-A")
        try await waitUntil {
            !store.isFiltering && store.totalMatches == 1_475
        }
        #expect(store.rows.count == 500)
        #expect(store.rows.allSatisfy { $0.rule.proxy == "Policy-A" })

        store.updateSearch("ProcessName")
        try await waitUntil {
            !store.isFiltering && store.totalMatches == 3_687
        }
        #expect(store.rows.count == 500)
        #expect(store.rows.allSatisfy { $0.rule.type == "ProcessName" })

        store.updateSearch("")
        try await waitUntil {
            !store.isFiltering && store.totalMatches == rules.count
        }
        #expect(store.rows.count == 500)

        store.loadMore()
        #expect(store.rows.count == 1_000)
        #expect(store.totalMatches == rules.count)
        store.cancelPendingWork()
    }

    @MainActor
    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the rule presentation state")
    }
}
