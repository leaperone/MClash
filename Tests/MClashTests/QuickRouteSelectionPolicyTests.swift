import Foundation
import Testing
@testable import MClashApp

@Suite("Quick Route selection")
struct QuickRouteSelectionPolicyTests {
    @Test("Pinned routes lead and automatic routes fill remaining slots")
    func pinnedRoutesLead() {
        #expect(
            QuickRouteSelectionPolicy.select(
                availableNames: ["Primary", "Media", "Work", "Fallback"],
                pinnedNames: ["Work"]
            ) == ["Work", "Primary", "Media"]
        )
    }

    @Test("Missing and duplicate pins do not create empty slots")
    func missingPinsAreIgnored() {
        #expect(
            QuickRouteSelectionPolicy.select(
                availableNames: ["Primary", "Primary", "Media"],
                pinnedNames: ["Missing", "Media", "Media"]
            ) == ["Media", "Primary"]
        )
    }

    @Test("Limit remains explicit and bounded")
    func boundedSelection() {
        #expect(
            QuickRouteSelectionPolicy.select(
                availableNames: ["A", "B", "C"],
                pinnedNames: ["C", "B"],
                limit: 1
            ) == ["C"]
        )
        #expect(
            QuickRouteSelectionPolicy.select(
                availableNames: ["A"],
                pinnedNames: [],
                limit: 0
            ).isEmpty
        )
    }

    @MainActor
    @Test("Pinned routes persist in normalized order")
    func pinnedRoutesPersist() throws {
        let suiteName = "mclash-quick-routes-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appending(
            path: suiteName,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ProfileDirectoryLayout(rootDirectory: root)

        let model = makeTestAppModel(
            profileDirectoryLayout: layout,
            preferenceDefaults: defaults
        )
        model.setQuickRoutePinned(
            " Work ",
            pinned: true,
            availableNames: ["Primary", "Work", "Media"]
        )
        model.setQuickRoutePinned(
            "Media",
            pinned: true,
            availableNames: ["Primary", "Work", "Media"]
        )

        #expect(model.pinnedQuickRouteNames == ["Work", "Media"])
        let reloaded = makeTestAppModel(
            profileDirectoryLayout: layout,
            preferenceDefaults: defaults
        )
        #expect(reloaded.pinnedQuickRouteNames == ["Work", "Media"])

        reloaded.clearPinnedQuickRoutes()
        #expect(defaults.stringArray(forKey: AppModel.pinnedQuickRouteNamesKey) == nil)
    }
}
