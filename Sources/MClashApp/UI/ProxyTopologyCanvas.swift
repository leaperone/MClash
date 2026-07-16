import SwiftUI

struct ProxyTopologyCanvas: View {
    let topology: ProxyTopology
    let rootGroup: String
    let selectedPath: ProxySelectionPath?
    let delays: [String: Int]
    @Binding var focusedNodeName: String?
    let openGroup: (String) -> Void
    let showGroupList: (String) -> Void

    @State private var zoom = 1.0
    @State private var relationshipsExpanded = false
    @GestureState private var magnification = 1.0

    var body: some View {
        let projection = ProxyTopologyProjection(
            topology: topology,
            rootGroup: rootGroup,
            selectedPath: selectedPath,
            delays: delays
        )
        let layout = ProxyTopologyLayout(projection: projection)

        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    topologyLegend
                    relationshipsButton
                    Spacer()
                    zoomControls
                }

                HStack(spacing: 8) {
                    compactTopologyLegend
                    Spacer(minLength: 4)
                    relationshipsButton
                        .labelStyle(.iconOnly)
                    zoomMenu
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            if relationshipsExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(projection.edges.enumerated()), id: \.offset) { _, edge in
                            Label(
                                relationshipDescription(edge),
                                systemImage: edge.kind == .dialer || edge.isDialerPath
                                    ? "link"
                                    : "arrow.right"
                            )
                            .font(.caption)
                            .foregroundStyle(relationshipColor(edge))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
                .frame(maxHeight: 140)
                .background(Color(nsColor: .controlBackgroundColor))
                .accessibilityLabel("Topology relationships")
            }

            Divider()

            if projection.nodes.isEmpty {
                ContentUnavailableView(
                    "No topology available",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("This group did not expose any route dependencies.")
                )
            } else {
                ScrollView([.horizontal, .vertical]) {
                    topologySurface(projection: projection, layout: layout)
                        .scaleEffect(effectiveZoom, anchor: .topLeading)
                        .frame(
                            width: layout.size.width * effectiveZoom,
                            height: layout.size.height * effectiveZoom,
                            alignment: .topLeading
                        )
                        .padding(20)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .gesture(
                    MagnificationGesture()
                        .updating($magnification) { value, state, _ in
                            state = value
                        }
                        .onEnded { value in
                            zoom = min(1.6, max(0.65, zoom * value))
                        }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proxy topology for \(rootGroup)")
    }

    private var topologyLegend: some View {
        HStack(spacing: 10) {
            Label("Current path", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.callout.weight(.medium))

            Label("Dependency", systemImage: "arrow.right")
                .foregroundStyle(.secondary)

            Label("Dialer", systemImage: "link")
                .foregroundStyle(.orange)
        }
    }

    private var compactTopologyLegend: some View {
        HStack(spacing: 8) {
            Label("Path", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.callout.weight(.medium))
            Label("Edge", systemImage: "arrow.right")
                .foregroundStyle(.secondary)
            Label("Dialer", systemImage: "link")
                .foregroundStyle(.orange)
        }
        .labelStyle(.iconOnly)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current path, dependency edge, and dialer path legend")
    }

    private var relationshipsButton: some View {
        Button {
            relationshipsExpanded.toggle()
        } label: {
            Label("Relationships", systemImage: "list.bullet.indent")
        }
        .help(
            relationshipsExpanded
                ? "Hide the accessible relationship outline"
                : "Show an accessible relationship outline"
        )
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button {
                zoom = max(0.65, zoom - 0.1)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(effectiveZoom <= 0.65)
            .help("Zoom Out")

            Text("\(Int(effectiveZoom * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42)

            Button {
                zoom = min(1.6, zoom + 0.1)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(effectiveZoom >= 1.6)
            .help("Zoom In")

            Button("Reset") { zoom = 1 }
                .help("Reset topology scale to 100 percent")
        }
    }

    private var zoomMenu: some View {
        Menu {
            Button("Zoom In") { zoom = min(1.6, zoom + 0.1) }
                .disabled(effectiveZoom >= 1.6)
            Button("Zoom Out") { zoom = max(0.65, zoom - 0.1) }
                .disabled(effectiveZoom <= 0.65)
            Divider()
            Button("Reset to 100%") { zoom = 1 }
        } label: {
            Label("\(Int(effectiveZoom * 100))%", systemImage: "magnifyingglass")
        }
        .help("Topology zoom")
    }

    private var effectiveZoom: Double {
        min(1.6, max(0.65, zoom * magnification))
    }

    private func relationshipDescription(_ edge: ProxyTopologyDisplayEdge) -> String {
        if edge.kind == .dialer {
            return "\(edge.source) uses \(edge.target) as a dialer dependency"
        }
        if edge.isDialerPath {
            return "Dialer path: \(edge.source) selects \(edge.target)"
        }
        if edge.isSelected {
            return "Current path: \(edge.source) selects \(edge.target)"
        }
        return "\(edge.source) contains \(edge.target)"
    }

    private func relationshipColor(_ edge: ProxyTopologyDisplayEdge) -> Color {
        if edge.kind == .dialer || edge.isDialerPath { return .orange }
        if edge.isSelected { return .accentColor }
        return .secondary
    }

    private func topologySurface(
        projection: ProxyTopologyProjection,
        layout: ProxyTopologyLayout
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for edge in projection.edges {
                    guard let source = layout.positions[edge.source],
                          let target = layout.positions[edge.target] else { continue }

                    let start = CGPoint(
                        x: source.x + ProxyTopologyLayout.nodeSize.width,
                        y: source.y + ProxyTopologyLayout.nodeSize.height / 2
                    )
                    let end = CGPoint(
                        x: target.x,
                        y: target.y + ProxyTopologyLayout.nodeSize.height / 2
                    )
                    let controlOffset = max(34, (end.x - start.x) * 0.45)
                    var path = Path()
                    path.move(to: start)
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x + controlOffset, y: start.y),
                        control2: CGPoint(x: end.x - controlOffset, y: end.y)
                    )

                    let color: Color
                    if edge.kind == .dialer || edge.isDialerPath {
                        color = .orange.opacity(0.8)
                    } else if edge.isSelected {
                        color = .accentColor
                    } else {
                        color = Color(nsColor: .separatorColor).opacity(0.85)
                    }
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(
                            lineWidth: edge.isSelected || edge.isDialerPath ? 2.4 : 1.2,
                            lineCap: .round,
                            dash: edge.kind == .dialer || edge.isDialerPath ? [5, 4] : []
                        )
                    )
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)
            .accessibilityHidden(true)

            ForEach(projection.nodes) { node in
                if let position = layout.positions[node.id] {
                    ProxyTopologyNodeView(
                        node: node,
                        accessibilityDescription: nodeAccessibilityDescription(
                            node,
                            projection: projection
                        ),
                        isFocused: focusedNodeName == node.sourceName,
                        onFocus: { focusedNodeName = node.sourceName },
                        onOpenGroup: node.opensGroup ? {
                            if node.isSummary {
                                showGroupList(node.sourceName)
                            } else {
                                openGroup(node.sourceName)
                            }
                        } : nil
                    )
                    .frame(
                        width: ProxyTopologyLayout.nodeSize.width,
                        height: ProxyTopologyLayout.nodeSize.height
                    )
                    .offset(x: position.x, y: position.y)
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    private func nodeAccessibilityDescription(
        _ node: ProxyTopologyDisplayNode,
        projection: ProxyTopologyProjection
    ) -> String {
        var details = [node.title, node.subtitle]
        if node.isSelectedPath { details.append("On the current route") }

        for edge in projection.edges where edge.source == node.id {
            if edge.kind == .dialer {
                details.append("Uses \(edge.target) as a dialer dependency")
            } else if edge.isDialerPath {
                details.append("Dialer path selects \(edge.target)")
            } else if edge.isSelected {
                details.append("Current route selects \(edge.target)")
            } else {
                details.append("Contains \(edge.target)")
            }
        }
        for edge in projection.edges where edge.target == node.id {
            if edge.kind == .dialer {
                details.append("Dialer dependency from \(edge.source)")
            } else if edge.isDialerPath {
                details.append("Dialer dependency from \(edge.source)")
            } else if edge.isSelected {
                details.append("Selected by \(edge.source) on the current route")
            } else {
                details.append("Member of \(edge.source)")
            }
        }
        return details.joined(separator: ". ")
    }
}

private struct ProxyTopologyNodeView: View {
    let node: ProxyTopologyDisplayNode
    let accessibilityDescription: String
    let isFocused: Bool
    let onFocus: () -> Void
    let onOpenGroup: (() -> Void)?

    @ViewBuilder
    var body: some View {
        if let onOpenGroup {
            nodeButton
                .accessibilityAction(named: "Open Group", onOpenGroup)
        } else {
            nodeButton
        }
    }

    private var nodeButton: some View {
        Button(action: onFocus) {
            HStack(spacing: 9) {
                Image(systemName: node.symbol)
                    .foregroundStyle(node.symbolColor)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(node.title)
                        .font(.callout.weight(node.isSelectedPath ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(node.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if node.opensGroup {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(node.backgroundColor)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        node.borderColor(isFocused: isFocused),
                        lineWidth: node.isSelectedPath || isFocused ? 2 : 1
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onOpenGroup?()
            }
        )
        .contextMenu {
            if let onOpenGroup {
                Button("Open Group", action: onOpenGroup)
            }
        }
        .help(node.opensGroup ? "Click to inspect; double-click to open group" : node.subtitle)
        .accessibilityLabel(accessibilityDescription)
    }
}

struct ProxyTopologyProjection {
    let nodes: [ProxyTopologyDisplayNode]
    let edges: [ProxyTopologyDisplayEdge]

    init(
        topology: ProxyTopology,
        rootGroup: String,
        selectedPath: ProxySelectionPath?,
        delays: [String: Int]
    ) {
        guard topology.vertices[rootGroup] != nil else {
            nodes = []
            edges = []
            return
        }

        let selectedNames = Set(selectedPath?.route ?? [rootGroup])
        let selectedEdgeKeys = Set(
            (selectedPath?.selectionHops ?? []).map { "\($0.source)\u{0}\($0.target)" }
        )
        let dialerEdgeKeys = Set(
            (selectedPath?.dialerHops ?? []).map { "\($0.source)\u{0}\($0.target)" }
        )
        let groupRank = Dictionary(
            uniqueKeysWithValues: topology.groupOrder.enumerated().map { ($0.element, $0.offset) }
        )

        var depths: [String: Int] = [rootGroup: 0]
        var dependencyQueue = [rootGroup]
        var visitedDependencies = Set<String>()
        var groupQueue: [String] = []
        var requiredEndpoints = Set<String>()
        var queueIndex = 0
        while queueIndex < dependencyQueue.count {
            let name = dependencyQueue[queueIndex]
            queueIndex += 1
            guard visitedDependencies.insert(name).inserted,
                  let vertex = topology.vertices[name] else { continue }
            let depth = depths[name, default: 0]

            if vertex.isGroup {
                groupQueue.append(name)
                for child in topology.childrenByGroup[name, default: []]
                where topology.vertices[child]?.isGroup == true {
                    depths[child] = min(depths[child] ?? Int.max, depth + 1)
                    dependencyQueue.append(child)
                }
                if let current = vertex.now,
                   topology.childrenByGroup[name, default: []].contains(current) {
                    depths[current] = min(depths[current] ?? Int.max, depth + 1)
                    dependencyQueue.append(current)
                }
            } else {
                requiredEndpoints.insert(name)
                if let dialer = vertex.dialerProxy {
                    depths[dialer] = min(depths[dialer] ?? Int.max, depth + 1)
                    dependencyQueue.append(dialer)
                }
            }
        }

        var displayNodes: [String: ProxyTopologyDisplayNode] = [:]
        var displayEdges: [ProxyTopologyDisplayEdge] = []

        for group in groupQueue {
            guard let vertex = topology.vertices[group] else { continue }
            displayNodes[group] = ProxyTopologyDisplayNode(
                id: group,
                sourceName: group,
                title: group,
                subtitle: groupSubtitle(vertex),
                kind: vertex.kind,
                depth: depths[group, default: 0],
                order: groupRank[group] ?? Int.max,
                isSelectedPath: selectedNames.contains(group),
                opensGroup: true
            )
        }

        for group in groupQueue {
            guard let sourceDepth = depths[group] else { continue }
            let children = topology.childrenByGroup[group, default: []]
            let leafChildren = children.filter { topology.vertices[$0]?.isGroup != true }
            let selectedChild = selectedPath?.selectionHops
                .first(where: { $0.source == group })?.target
            let limit = group == rootGroup ? 7 : (selectedNames.contains(group) ? 4 : 0)
            var visibleLeaves: [String] = []
            if let selectedChild, leafChildren.contains(selectedChild) {
                visibleLeaves.append(selectedChild)
            }
            for child in leafChildren where requiredEndpoints.contains(child) {
                if !visibleLeaves.contains(child) { visibleLeaves.append(child) }
            }
            for child in leafChildren where visibleLeaves.count < limit {
                if !visibleLeaves.contains(child) { visibleLeaves.append(child) }
            }

            for (index, child) in visibleLeaves.enumerated() {
                let vertex = topology.vertices[child]
                displayNodes[child] = ProxyTopologyDisplayNode(
                    id: child,
                    sourceName: child,
                    title: child,
                    subtitle: endpointSubtitle(vertex, delay: delays[child]),
                    kind: vertex?.kind ?? .unresolved,
                    depth: sourceDepth + 1,
                    order: index,
                    isSelectedPath: selectedNames.contains(child),
                    opensGroup: vertex?.isGroup == true
                )
            }

            let hiddenCount = max(0, leafChildren.count - visibleLeaves.count)
            if hiddenCount > 0 {
                let summaryID = "__summary__:\(group)"
                displayNodes[summaryID] = ProxyTopologyDisplayNode.summary(
                    id: summaryID,
                    sourceName: group,
                    title: "\(hiddenCount) more nodes",
                    subtitle: "Switch to List to inspect all members",
                    depth: sourceDepth + 1,
                    order: Int.max - 1
                )
                displayEdges.append(
                    ProxyTopologyDisplayEdge(
                        source: group,
                        target: summaryID,
                        kind: .member,
                        isSelected: false,
                        isDialerPath: false
                    )
                )
            }
        }

        for endpoint in requiredEndpoints where displayNodes[endpoint] == nil {
            let vertex = topology.vertices[endpoint]
            displayNodes[endpoint] = ProxyTopologyDisplayNode(
                id: endpoint,
                sourceName: endpoint,
                title: endpoint,
                subtitle: endpointSubtitle(vertex, delay: delays[endpoint]),
                kind: vertex?.kind ?? .unresolved,
                depth: depths[endpoint, default: 1],
                order: Int.max - 2,
                isSelectedPath: selectedNames.contains(endpoint),
                opensGroup: vertex?.isGroup == true
            )
        }

        for edge in topology.edges {
            guard displayNodes[edge.source] != nil else { continue }
            if displayNodes[edge.target] == nil,
               edge.kind == .dialer,
               let target = topology.vertices[edge.target] {
                let depth = (displayNodes[edge.source]?.depth ?? 0) + 1
                displayNodes[edge.target] = ProxyTopologyDisplayNode(
                    id: edge.target,
                    sourceName: edge.target,
                    title: edge.target,
                    subtitle: endpointSubtitle(target, delay: delays[edge.target]),
                    kind: target.kind,
                    depth: depth,
                    order: Int.max - 2,
                    isSelectedPath: selectedNames.contains(edge.target),
                    opensGroup: target.isGroup
                )
            }
            guard displayNodes[edge.target] != nil else { continue }
            displayEdges.append(
                ProxyTopologyDisplayEdge(
                    source: edge.source,
                    target: edge.target,
                    kind: edge.kind,
                    isSelected: selectedEdgeKeys.contains("\(edge.source)\u{0}\(edge.target)"),
                    isDialerPath: dialerEdgeKeys.contains(
                        "\(edge.source)\u{0}\(edge.target)"
                    )
                )
            )
        }

        nodes = displayNodes.values.sorted { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return proxyStableNameComesBefore(lhs.title, rhs.title)
        }
        edges = Array(Set(displayEdges)).sorted { lhs, rhs in
            if lhs.source != rhs.source { return proxyStableNameComesBefore(lhs.source, rhs.source) }
            if lhs.target != rhs.target { return proxyStableNameComesBefore(lhs.target, rhs.target) }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }
}

struct ProxyTopologyDisplayNode: Identifiable {
    enum DisplayKind: Equatable {
        case group(ProxyGroupKind)
        case endpoint
        case unresolved
        case summary
    }

    let id: String
    let sourceName: String
    let title: String
    let subtitle: String
    let kind: DisplayKind
    let depth: Int
    let order: Int
    let isSelectedPath: Bool
    let opensGroup: Bool

    init(
        id: String,
        sourceName: String,
        title: String,
        subtitle: String,
        kind: ProxyTopologyVertexKind,
        depth: Int,
        order: Int,
        isSelectedPath: Bool,
        opensGroup: Bool
    ) {
        self.id = id
        self.sourceName = sourceName
        self.title = title
        self.subtitle = subtitle
        self.depth = depth
        self.order = order
        self.isSelectedPath = isSelectedPath
        self.opensGroup = opensGroup
        switch kind {
        case let .group(groupKind): self.kind = .group(groupKind)
        case .endpoint: self.kind = .endpoint
        case .unresolved: self.kind = .unresolved
        }
    }

    private init(
        id: String,
        sourceName: String,
        title: String,
        subtitle: String,
        kind: DisplayKind,
        depth: Int,
        order: Int,
        isSelectedPath: Bool,
        opensGroup: Bool
    ) {
        self.id = id
        self.sourceName = sourceName
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.depth = depth
        self.order = order
        self.isSelectedPath = isSelectedPath
        self.opensGroup = opensGroup
    }

    static func summary(
        id: String,
        sourceName: String,
        title: String,
        subtitle: String,
        depth: Int,
        order: Int
    ) -> ProxyTopologyDisplayNode {
        ProxyTopologyDisplayNode(
            id: id,
            sourceName: sourceName,
            title: title,
            subtitle: subtitle,
            kind: .summary,
            depth: depth,
            order: order,
            isSelectedPath: false,
            opensGroup: true
        )
    }

    var symbol: String {
        switch kind {
        case .group(.selector): "slider.horizontal.3"
        case .group(.urlTest): "speedometer"
        case .group(.fallback): "arrow.triangle.branch"
        case .group(.loadBalance): "scale.3d"
        case .group: "point.3.connected.trianglepath.dotted"
        case .endpoint: "network"
        case .unresolved: "questionmark.diamond"
        case .summary: "ellipsis"
        }
    }

    var isSummary: Bool {
        if case .summary = kind { return true }
        return false
    }

    var symbolColor: Color {
        switch kind {
        case .unresolved: .red
        case .summary: .secondary
        default: isSelectedPath ? .accentColor : .secondary
        }
    }

    var backgroundColor: Color {
        if isSelectedPath { return Color.accentColor.opacity(0.1) }
        return Color(nsColor: .controlBackgroundColor)
    }

    func borderColor(isFocused: Bool) -> Color {
        if isFocused || isSelectedPath { return .accentColor }
        if case .unresolved = kind { return .red }
        return Color(nsColor: .separatorColor)
    }
}

struct ProxyTopologyDisplayEdge: Hashable {
    let source: String
    let target: String
    let kind: ProxyTopologyEdgeKind
    let isSelected: Bool
    let isDialerPath: Bool
}

private struct ProxyTopologyLayout {
    static let nodeSize = CGSize(width: 194, height: 64)
    private static let horizontalGap: CGFloat = 72
    private static let verticalGap: CGFloat = 18
    private static let inset: CGFloat = 24

    let positions: [String: CGPoint]
    let size: CGSize

    init(projection: ProxyTopologyProjection) {
        let columns = Dictionary(grouping: projection.nodes, by: \.depth)
        var positions: [String: CGPoint] = [:]
        var maximumColumnCount = 0
        let maximumDepth = columns.keys.max() ?? 0

        for depth in 0...maximumDepth {
            let nodes = columns[depth, default: []]
            maximumColumnCount = max(maximumColumnCount, nodes.count)
            for (index, node) in nodes.enumerated() {
                positions[node.id] = CGPoint(
                    x: Self.inset + CGFloat(depth) * (Self.nodeSize.width + Self.horizontalGap),
                    y: Self.inset + CGFloat(index) * (Self.nodeSize.height + Self.verticalGap)
                )
            }
        }

        self.positions = positions
        size = CGSize(
            width: max(
                680,
                Self.inset * 2
                    + CGFloat(maximumDepth + 1) * Self.nodeSize.width
                    + CGFloat(maximumDepth) * Self.horizontalGap
            ),
            height: max(
                400,
                Self.inset * 2
                    + CGFloat(maximumColumnCount) * Self.nodeSize.height
                    + CGFloat(max(0, maximumColumnCount - 1)) * Self.verticalGap
            )
        )
    }
}

private func groupSubtitle(_ vertex: ProxyTopologyVertex) -> String {
    if case .group(.loadBalance) = vertex.kind {
        return "LoadBalance · per connection"
    }
    let current = vertex.now.map { " · \($0)" } ?? ""
    return "\(vertex.type)\(current)"
}

private func endpointSubtitle(_ vertex: ProxyTopologyVertex?, delay: Int?) -> String {
    guard let vertex else { return "Missing runtime node" }
    let delayText = delay.map { " · \($0) ms" } ?? ""
    let provider = normalized(vertex.providerName).map { " · \($0)" } ?? ""
    return "\(vertex.type)\(delayText)\(provider)"
}
