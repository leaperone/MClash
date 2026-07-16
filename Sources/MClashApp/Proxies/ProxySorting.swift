import Foundation

enum ProxyNodeSortMode: String, CaseIterable, Sendable {
    case profile
    case latency
    case name
}

struct ProxyNodeSorter: Sendable {
    func sortedNodeNames(
        _ names: [String],
        in groupName: String?,
        topology: ProxyTopology,
        delays: [String: Int],
        mode: ProxyNodeSortMode
    ) -> [String] {
        let profileNames = groupName.flatMap { topology.childrenByGroup[$0] } ?? names
        let profileIndexes = Dictionary(
            profileNames.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: min
        )

        return names.enumerated().sorted { left, right in
            compare(
                left: left,
                right: right,
                topology: topology,
                delays: delays,
                profileIndexes: profileIndexes,
                mode: mode
            )
        }.map(\.element)
    }

    private func compare(
        left: (offset: Int, element: String),
        right: (offset: Int, element: String),
        topology: ProxyTopology,
        delays: [String: Int],
        profileIndexes: [String: Int],
        mode: ProxyNodeSortMode
    ) -> Bool {
        let leftName = left.element
        let rightName = right.element
        let leftProfile = profileIndexes[leftName] ?? Int.max
        let rightProfile = profileIndexes[rightName] ?? Int.max
        let leftType = topology.vertices[leftName]?.type ?? ""
        let rightType = topology.vertices[rightName]?.type ?? ""

        switch mode {
        case .profile:
            if leftProfile != rightProfile { return leftProfile < rightProfile }
            if leftName != rightName { return proxyStableNameComesBefore(leftName, rightName) }
            if leftType != rightType { return proxyStableNameComesBefore(leftType, rightType) }
        case .latency:
            let leftDelay = validDelay(delays[leftName])
            let rightDelay = validDelay(delays[rightName])
            if leftDelay != nil, rightDelay == nil { return true }
            if leftDelay == nil, rightDelay != nil { return false }
            if let leftDelay, let rightDelay, leftDelay != rightDelay { return leftDelay < rightDelay }
            if leftProfile != rightProfile { return leftProfile < rightProfile }
            if leftName != rightName { return proxyStableNameComesBefore(leftName, rightName) }
            if leftType != rightType { return proxyStableNameComesBefore(leftType, rightType) }
        case .name:
            if leftName != rightName { return proxyStableNameComesBefore(leftName, rightName) }
            if leftType != rightType { return proxyStableNameComesBefore(leftType, rightType) }
            if leftProfile != rightProfile { return leftProfile < rightProfile }
        }
        return left.offset < right.offset
    }

    private func validDelay(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
