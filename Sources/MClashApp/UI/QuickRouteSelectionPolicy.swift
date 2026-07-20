import Foundation

struct QuickRouteSelectionPolicy: Sendable {
    static let maximumVisibleRoutes = 3

    static func select(
        availableNames: [String],
        pinnedNames: [String],
        limit: Int = maximumVisibleRoutes
    ) -> [String] {
        guard limit > 0 else { return [] }

        var availableSeen = Set<String>()
        let available = availableNames.filter { name in
            !name.isEmpty && availableSeen.insert(name).inserted
        }
        let availableSet = Set(available)

        var selected: [String] = []
        var selectedSet = Set<String>()
        for name in pinnedNames where availableSet.contains(name) {
            guard selectedSet.insert(name).inserted else { continue }
            selected.append(name)
            if selected.count == limit { return selected }
        }

        for name in available where selectedSet.insert(name).inserted {
            selected.append(name)
            if selected.count == limit { break }
        }
        return selected
    }
}
