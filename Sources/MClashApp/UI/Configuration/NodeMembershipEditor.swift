import SwiftUI

/// A selector-first node membership editor. It keeps fixed pins separate from
/// automatic matches, so a source refresh can add/remove matching nodes
/// without asking the user to maintain hundreds of toggles.
struct NodeMembershipEditor: View {
    let nodes: [Node]
    let sourceNames: [SourceID: String]
    @Binding var selectedNodeIDs: Set<NodeID>
    @Binding var selectors: [NodeSelector]
    @Binding var orderedNodeIDs: [NodeID]

    @State private var activeSelectorID: UUID?
    @State private var selectorName = ""
    @State private var nameContains = ""
    @State private var nameEquals = ""
    @State private var hostContains = ""
    @State private var hostEquals = ""
    @State private var sourceChoice: SourceID?
    @State private var protocolChoice: NodeProtocol?
    @State private var tagContains = ""
    @State private var excludeNameContains = ""
    @State private var excludeHostContains = ""
    @State private var fixedSearch = ""
    @State private var librarySearch = ""
    @State private var librarySelectedIDs: Set<NodeID> = []
    @State private var isLoading = false
    @State private var advancedConditionsExpanded = false
    @FocusState private var librarySearchFocused: Bool

    private var activeSelector: NodeSelector? {
        guard let activeSelectorID else { return nil }
        return selectors.first { $0.id == activeSelectorID }
    }

    private var activeCriteria: [String] {
        var result: [String] = []
        if !nameContains.trimmed.isEmpty { result.append(AppLocalization.format("Name contains %@", nameContains.trimmed)) }
        if !nameEquals.trimmed.isEmpty { result.append(AppLocalization.format("Name is %@", nameEquals.trimmed)) }
        if !hostContains.trimmed.isEmpty { result.append(AppLocalization.format("Host/IP contains %@", hostContains.trimmed)) }
        if !hostEquals.trimmed.isEmpty { result.append(AppLocalization.format("Host/IP is %@", hostEquals.trimmed)) }
        if let sourceChoice { result.append(AppLocalization.format("Source is %@", sourceNames[sourceChoice] ?? AppLocalization.string("selected source"))) }
        if let protocolChoice { result.append(AppLocalization.format("Protocol is %@", protocolChoice.rawValue.uppercased())) }
        if !tagContains.trimmed.isEmpty { result.append(AppLocalization.format("Tag contains %@", tagContains.trimmed)) }
        if !excludeNameContains.trimmed.isEmpty { result.append(AppLocalization.format("Exclude name %@", excludeNameContains.trimmed)) }
        if !excludeHostContains.trimmed.isEmpty { result.append(AppLocalization.format("Exclude host/IP %@", excludeHostContains.trimmed)) }
        return result
    }

    private var matchedNodes: [Node] {
        guard activeSelectorID != nil else { return [] }
        let selector = draftSelector
        // An empty include expression intentionally means all enabled nodes;
        // show that result explicitly so the default group never looks empty
        // merely because it has no text condition.
        let candidates = nodes.filter {
            $0.enabled
                && $0.health.availability != .sourceRemoved
                && $0.health.availability != .unsupported
        }
        return candidates.filter { selector.matchesForPreview($0) }.sorted(by: stableNodeOrder)
    }

    private var fixedNodes: [Node] {
        let query = fixedSearch.trimmed
        return nodes.filter { node in
            selectedNodeIDs.contains(node.id)
                && (query.isEmpty
                    || (node.userAlias ?? node.displayName).localizedCaseInsensitiveContains(query)
                    || node.host.localizedCaseInsensitiveContains(query)
                    || node.proto.rawValue.localizedCaseInsensitiveContains(query))
        }.sorted { lhs, rhs in
            let leftIndex = orderedNodeIDs.firstIndex(of: lhs.id) ?? .max
            let rightIndex = orderedNodeIDs.firstIndex(of: rhs.id) ?? .max
            if leftIndex != rightIndex { return leftIndex < rightIndex }
            return stableNodeOrder(lhs, rhs)
        }
    }

    private var availableLibraryNodes: [Node] {
        let query = librarySearch.trimmed
        return nodes.filter { node in
            !selectedNodeIDs.contains(node.id)
                && ((node.userAlias ?? node.displayName).localizedCaseInsensitiveContains(query)
                    || node.host.localizedCaseInsensitiveContains(query)
                    || node.proto.rawValue.localizedCaseInsensitiveContains(query)
                    || node.tags.contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted(by: stableNodeOrder).prefix(200).map { $0 }
    }

    private var remainingFixedNodeCapacity: Int {
        max(0, ConfigurationAutomationLimits.groupMembers - selectedNodeIDs.count)
    }

    var body: some View {
        Section {
            selectorPicker
            selectorCriteria
            automaticPreview
            fixedMembers
        } header: {
            Label(AppLocalization.string("Which nodes should be in this group?"), systemImage: "line.3.horizontal.decrease.circle")
        } footer: {
            Text(AppLocalization.string("Each selector combines its filled conditions with AND. Multiple selectors are combined with OR. Fixed nodes stay selected until you remove them."))
        }
        .onAppear(perform: prepare)
        .onChange(of: nameContains) { _, _ in syncSelector() }
        .onChange(of: selectorName) { _, _ in syncSelector() }
        .onChange(of: nameEquals) { _, _ in syncSelector() }
        .onChange(of: hostContains) { _, _ in syncSelector() }
        .onChange(of: hostEquals) { _, _ in syncSelector() }
        .onChange(of: sourceChoice) { _, _ in syncSelector() }
        .onChange(of: protocolChoice) { _, _ in syncSelector() }
        .onChange(of: tagContains) { _, _ in syncSelector() }
        .onChange(of: excludeNameContains) { _, _ in syncSelector() }
        .onChange(of: excludeHostContains) { _, _ in syncSelector() }
    }

    private var selectorPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(AppLocalization.string("Automatic selectors"))
                    .font(.headline)
                Spacer()
                Menu {
                    Button(AppLocalization.string("All enabled nodes")) {
                        addPresetSelector(name: AppLocalization.string("All enabled nodes"), pattern: nil)
                    }
                    Button(AppLocalization.string("US / United States")) {
                        addPresetSelector(name: AppLocalization.string("US / United States"), pattern: "US")
                    }
                    Button(AppLocalization.string("JP / Japan")) {
                        addPresetSelector(name: AppLocalization.string("JP / Japan"), pattern: "JP")
                    }
                    Button(AppLocalization.string("HK / Hong Kong")) {
                        addPresetSelector(name: AppLocalization.string("HK / Hong Kong"), pattern: "HK")
                    }
                } label: {
                    Label(AppLocalization.string("Quick match"), systemImage: "wand.and.stars")
                }
                .menuStyle(.borderlessButton)
                Button {
                    addSelector()
                } label: {
                    Label(AppLocalization.string("Add selector"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if selectors.isEmpty {
                Text(AppLocalization.string("No automatic selector yet. Add one to describe a group such as “name contains US” or “source is Primary”."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(AppLocalization.string("Add automatic selector"), action: addSelector)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button(AppLocalization.string("Pin a fixed node")) {
                        librarySearchFocused = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Text(AppLocalization.string("Fallback checks members from top to bottom and uses the first healthy option. Move members to set priority."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(selectors.enumerated()), id: \.element.id) { index, selector in
                            HStack(spacing: 4) {
                                Button {
                                    selectSelector(selector.id)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: selector.id == activeSelectorID ? "checkmark.circle.fill" : "line.3.horizontal.decrease.circle")
                                        Text(selector.name)
                                        Text(
                                            AppLocalization.format(
                                                "%d matches",
                                                selectorMatchCount(selector)
                                            )
                                        )
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        Spacer(minLength: 0)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityLabel(AppLocalization.format("Selector %@", selector.name))

                                Button {
                                    moveSelector(selector.id, by: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)
                                .accessibilityLabel(AppLocalization.string("Move selector up"))

                                Button {
                                    moveSelector(selector.id, by: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index >= selectors.count - 1)
                                .accessibilityLabel(AppLocalization.string("Move selector down"))
                            }
                        }
                    }
                }
                .frame(maxHeight: 144)
            }
        }
    }

    @ViewBuilder
    private var selectorCriteria: some View {
        if activeSelectorID != nil {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(AppLocalization.string("Match conditions"))
                        .font(.headline)
                    TextField(AppLocalization.string("Selector name"), text: $selectorName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    Spacer()
                    Button(AppLocalization.string("Remove selector"), role: .destructive) {
                        removeActiveSelector()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                Text(AppLocalization.string("All included conditions must match. Exclusions apply to automatic matches; fixed pins remain in the group."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Image(systemName: "textformat")
                        .foregroundStyle(.secondary)
                    TextField(AppLocalization.string("Name contains or matches (for example US or US*)"), text: $nameContains)
                }
                HStack(spacing: 8) {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                    TextField(AppLocalization.string("Host/IP contains or matches (for example us.*)"), text: $hostContains)
                }
                DisclosureGroup(
                    AppLocalization.string("More conditions"),
                    isExpanded: $advancedConditionsExpanded
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "equal.circle")
                                .foregroundStyle(.secondary)
                            TextField(AppLocalization.string("Exact name (optional)"), text: $nameEquals)
                            TextField(AppLocalization.string("Exact Host/IP (optional)"), text: $hostEquals)
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "tag")
                                .foregroundStyle(.secondary)
                            TextField(AppLocalization.string("Tag contains (for example premium)"), text: $tagContains)
                        }
                        HStack {
                            Picker(AppLocalization.string("Source"), selection: $sourceChoice) {
                                Text(AppLocalization.string("Any source")).tag(Optional<SourceID>.none)
                                ForEach(sortedSourceIDs, id: \.self) { sourceID in
                                    Text(sourceNames[sourceID] ?? "Source").tag(Optional(sourceID))
                                }
                            }
                            Picker(AppLocalization.string("Protocol"), selection: $protocolChoice) {
                                Text(AppLocalization.string("Any protocol")).tag(Optional<NodeProtocol>.none)
                                ForEach(NodeProtocol.allCases, id: \.self) { proto in
                                    Text(proto.rawValue.uppercased()).tag(Optional(proto))
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.secondary)
                            TextField(AppLocalization.string("Exclude name contains (optional)"), text: $excludeNameContains)
                            TextField(AppLocalization.string("Exclude host/IP contains (optional)"), text: $excludeHostContains)
                        }
                    }
                    .padding(.top, 6)
                }

                if !activeCriteria.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 5) {
                        ForEach(activeCriteria, id: \.self) { criterion in
                            Text(criterion)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
        }
    }

    private var automaticPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(AppLocalization.string("Automatic preview"), systemImage: "wand.and.stars")
                    .font(.headline)
                Spacer()
                Text(AppLocalization.format("%d matches", matchedNodes.count))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if activeSelectorID == nil {
                Text(AppLocalization.string("Add a selector to describe which nodes belong to this group."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if activeCriteria.isEmpty {
                Text(AppLocalization.string("No include condition means all enabled nodes. Add a condition to narrow the match."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if matchedNodes.isEmpty {
                Label(AppLocalization.string("No nodes match these conditions"), systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(AppLocalization.format("%@ nodes match; automatic membership updates on refresh.", AppLocalization.number(matchedNodes.count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(matchedNodes.prefix(100)) { node in
                            nodeRow(
                                node,
                                symbol: selectedNodeIDs.contains(node.id)
                                    ? "pin.fill"
                                    : "wand.and.stars",
                                tint: selectedNodeIDs.contains(node.id)
                                    ? Color.accentColor
                                    : Color.secondary
                            )
                        }
                    }
                }
                .frame(maxHeight: 150)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                if matchedNodes.count > 100 {
                    Text(AppLocalization.string("Showing the first 100 matches. Refine your search."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var fixedMembers: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(AppLocalization.string("Fixed nodes"), systemImage: "pin")
                    .font(.headline)
                Spacer()
                Text(AppLocalization.format("%d pinned", selectedNodeIDs.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            let missingFixedCount = selectedNodeIDs.subtracting(Set(nodes.map(\.id))).count
            if missingFixedCount > 0 {
                Label(
                    AppLocalization.format("%d pinned nodes are unavailable after the last source refresh.", missingFixedCount),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text(AppLocalization.string("Fixed nodes stay in this group until you remove them. They do not depend on automatic conditions."))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(AppLocalization.string("Search pinned nodes"), text: $fixedSearch)
                .textFieldStyle(.roundedBorder)
            if fixedNodes.isEmpty {
                Text(AppLocalization.string("No fixed nodes yet."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(fixedNodes) { node in
                            HStack(spacing: 6) {
                                Button {
                                    togglePin(node.id, pinned: false)
                                } label: {
                                    nodeRow(
                                        node,
                                        symbol: "pin.fill",
                                        tint: Color.accentColor
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint(
                                    AppLocalization.string("Remove this fixed node")
                                )
                                let position = orderedNodeIDs.firstIndex(of: node.id) ?? 0
                                Button {
                                    movePinnedNode(node.id, by: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(position == 0)
                                .accessibilityLabel(AppLocalization.string("Move fixed node up"))
                                Button {
                                    movePinnedNode(node.id, by: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(position >= orderedNodeIDs.count - 1)
                                .accessibilityLabel(AppLocalization.string("Move fixed node down"))
                            }
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
            TextField(AppLocalization.string("Search node library to pin a node"), text: $librarySearch)
                .textFieldStyle(.roundedBorder)
                .focused($librarySearchFocused)
            if !availableLibraryNodes.isEmpty {
                HStack {
                    Text(AppLocalization.format("%@ matching nodes", AppLocalization.number(availableLibraryNodes.count)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    let pinCount = min(
                        availableLibraryNodes.count,
                        remainingFixedNodeCapacity
                    )
                    Button(AppLocalization.format("Pin all %@", AppLocalization.number(pinCount))) {
                        pinAvailableNodes()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(pinCount == 0)
                    let selectedCount = librarySelectedIDs.intersection(Set(availableLibraryNodes.map(\.id))).count
                    Button(AppLocalization.format("Pin selected %@", AppLocalization.number(selectedCount))) {
                        pinSelectedLibraryNodes()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedCount == 0)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(availableLibraryNodes.prefix(100)) { node in
                            Button {
                                if librarySelectedIDs.contains(node.id) { librarySelectedIDs.remove(node.id) }
                                else { librarySelectedIDs.insert(node.id) }
                            } label: {
                                nodeRow(
                                    node,
                                    symbol: librarySelectedIDs.contains(node.id) ? "checkmark.circle.fill" : "circle",
                                    tint: librarySelectedIDs.contains(node.id) ? Color.accentColor : Color.secondary
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(remainingFixedNodeCapacity == 0)
                            .accessibilityHint(
                                AppLocalization.string("Add this fixed node")
                            )
                        }
                    }
                }
                .frame(maxHeight: 130)
                if availableLibraryNodes.count > remainingFixedNodeCapacity {
                    Text(
                        AppLocalization.format(
                            "Only %@ more fixed nodes can be added to this group.",
                            AppLocalization.number(remainingFixedNodeCapacity)
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
                if availableLibraryNodes.count > 100 {
                    Text(AppLocalization.string("Showing the first 100 matches. Refine your search."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func nodeRow(
        _ node: Node,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.userAlias ?? node.displayName).lineLimit(1)
                Text(AppLocalization.format("%@ · %@:%d", node.proto.rawValue.uppercased(), node.host, node.port))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let region = node.region, !region.isEmpty {
                Text(region).font(.caption2).foregroundStyle(.secondary)
            }
            if node.health.availability == .sourceRemoved || node.health.availability == .unsupported {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(AppLocalization.string("This node is no longer available from its source."))
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var sortedSourceIDs: [SourceID] {
        sourceNames.keys.sorted { (sourceNames[$0] ?? "").localizedCaseInsensitiveCompare(sourceNames[$1] ?? "") == .orderedAscending }
    }

    private var draftSelector: NodeSelector {
        var include: [NodeSelectorCondition] = []
        if !nameContains.trimmed.isEmpty { include.append(.nameContains(nameContains.trimmed)) }
        if !nameEquals.trimmed.isEmpty { include.append(.nameEquals(nameEquals.trimmed)) }
        if !hostContains.trimmed.isEmpty { include.append(.hostContains(hostContains.trimmed)) }
        if !hostEquals.trimmed.isEmpty { include.append(.hostEquals(hostEquals.trimmed)) }
        if let sourceChoice { include.append(.source(sourceChoice)) }
        if let protocolChoice { include.append(.protocolIs(protocolChoice)) }
        if !tagContains.trimmed.isEmpty { include.append(.tagContains(tagContains.trimmed)) }
        var exclude: [NodeSelectorCondition] = []
        if !excludeNameContains.trimmed.isEmpty { exclude.append(.nameContains(excludeNameContains.trimmed)) }
        if !excludeHostContains.trimmed.isEmpty { exclude.append(.hostContains(excludeHostContains.trimmed)) }
        return NodeSelector(
            id: activeSelectorID ?? UUID(),
            name: selectorName.trimmed.isEmpty
                ? (activeSelector?.name ?? AppLocalization.string("Selector"))
                : selectorName.trimmed,
            include: include,
            exclude: exclude,
            fixedNodeIDs: []
        )
    }

    private func prepare() {
        isLoading = true
        // v1.4's first editor attached durable pins to a selector. Fold those
        // pins into explicit group members once so fixed and automatic
        // membership are independent concepts in both the UI and the model.
        selectedNodeIDs.formUnion(selectors.flatMap(\.fixedNodeIDs))
        for index in selectors.indices where !selectors[index].fixedNodeIDs.isEmpty {
            selectors[index].fixedNodeIDs = []
        }
        orderedNodeIDs = orderedNodeIDs.filter { selectedNodeIDs.contains($0) }
            + selectedNodeIDs.subtracting(Set(orderedNodeIDs)).sorted {
                $0.rawValue.uuidString < $1.rawValue.uuidString
            }
        activeSelectorID = selectors.first?.id
        loadActiveSelector()
        isLoading = false
    }

    private func addSelector() {
        let selector = NodeSelector(
            name: AppLocalization.format("Selector %@", AppLocalization.number(selectors.count + 1))
        )
        selectors.append(selector)
        activeSelectorID = selector.id
        selectorName = selector.name
        clearFields()
        advancedConditionsExpanded = false
    }

    private func addPresetSelector(name: String, pattern: String?) {
        let include = pattern.map { [NodeSelectorCondition.nameContains($0)] } ?? []
        let selector = NodeSelector(name: name, include: include)
        selectors.append(selector)
        activeSelectorID = selector.id
        selectorName = selector.name
        clearFields()
        nameContains = pattern ?? ""
        advancedConditionsExpanded = false
        syncSelector()
    }

    private func selectSelector(_ id: UUID) {
        guard id != activeSelectorID else { return }
        syncSelector()
        activeSelectorID = id
        loadActiveSelector()
    }

    private func moveSelector(_ id: UUID, by offset: Int) {
        guard let index = selectors.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard selectors.indices.contains(destination) else { return }
        selectors.swapAt(index, destination)
    }

    private func removeActiveSelector() {
        guard let activeSelectorID else { return }
        selectors.removeAll { $0.id == activeSelectorID }
        self.activeSelectorID = selectors.first?.id
        if self.activeSelectorID == nil {
            selectorName = ""
            clearFields()
        } else { loadActiveSelector() }
    }

    private func loadActiveSelector() {
        guard let selector = activeSelector else { return }
        isLoading = true
        selectorName = selector.name
        clearFields()
        for condition in selector.include {
            apply(condition, to: false)
        }
        for condition in selector.exclude {
            apply(condition, to: true)
        }
        advancedConditionsExpanded = !nameEquals.trimmed.isEmpty
            || !hostEquals.trimmed.isEmpty
            || sourceChoice != nil
            || protocolChoice != nil
            || !tagContains.trimmed.isEmpty
            || !excludeNameContains.trimmed.isEmpty
            || !excludeHostContains.trimmed.isEmpty
        isLoading = false
    }

    private func clearFields() {
        nameContains = ""
        nameEquals = ""
        hostContains = ""
        hostEquals = ""
        sourceChoice = nil
        protocolChoice = nil
        tagContains = ""
        excludeNameContains = ""
        excludeHostContains = ""
        fixedSearch = ""
        librarySearch = ""
    }

    private func apply(_ condition: NodeSelectorCondition, to exclusion: Bool) {
        switch condition {
        case let .nameContains(value): exclusion ? (excludeNameContains = value) : (nameContains = value)
        case let .nameEquals(value): if !exclusion { nameEquals = value }
        case let .hostContains(value): exclusion ? (excludeHostContains = value) : (hostContains = value)
        case let .hostEquals(value): if !exclusion { hostEquals = value }
        case let .source(id): if !exclusion { sourceChoice = id }
        case let .protocolIs(value): if !exclusion { protocolChoice = value }
        case let .tagContains(value): if !exclusion { tagContains = value }
        default: break
        }
    }

    private func syncSelector() {
        guard !isLoading, let activeSelectorID,
              let index = selectors.firstIndex(where: { $0.id == activeSelectorID }) else { return }
        var selector = selectors[index]
        selector.name = selectorName.trimmed.isEmpty ? selector.name : selectorName.trimmed
        selector.include = draftSelector.include
        selector.exclude = draftSelector.exclude
        selector.fixedNodeIDs = []
        selectors[index] = selector
    }

    private func togglePin(_ id: NodeID, pinned: Bool) {
        if pinned {
            selectedNodeIDs.insert(id)
            if !orderedNodeIDs.contains(id) { orderedNodeIDs.append(id) }
        } else {
            selectedNodeIDs.remove(id)
            orderedNodeIDs.removeAll { $0 == id }
        }
    }

    private func movePinnedNode(_ id: NodeID, by offset: Int) {
        guard let index = orderedNodeIDs.firstIndex(of: id) else { return }
        let destination = index + offset
        guard orderedNodeIDs.indices.contains(destination) else { return }
        orderedNodeIDs.swapAt(index, destination)
    }

    private func pinAvailableNodes() {
        for id in availableLibraryNodes.prefix(remainingFixedNodeCapacity).map(\.id) {
            selectedNodeIDs.insert(id)
            if !orderedNodeIDs.contains(id) { orderedNodeIDs.append(id) }
        }
    }

    private func pinSelectedLibraryNodes() {
        let ids = librarySelectedIDs.intersection(Set(availableLibraryNodes.map(\.id)))
        for id in ids.prefix(remainingFixedNodeCapacity) {
            togglePin(id, pinned: true)
        }
        librarySelectedIDs.subtract(ids)
    }

    private func selectorMatchCount(_ selector: NodeSelector) -> Int {
        nodes.lazy.filter {
            $0.enabled
                && $0.health.availability != .sourceRemoved
                && $0.health.availability != .unsupported
                && selector.matchesForPreview($0)
        }.count
    }

    private func stableNodeOrder(_ lhs: Node, _ rhs: Node) -> Bool {
        let left = (lhs.userAlias ?? lhs.displayName).lowercased() + "|" + lhs.host + "|" + lhs.id.rawValue.uuidString
        let right = (rhs.userAlias ?? rhs.displayName).lowercased() + "|" + rhs.host + "|" + rhs.id.rawValue.uuidString
        return left < right
    }
}

private extension NodeSelector {
    func matchesForPreview(_ node: Node) -> Bool {
        (include.isEmpty || include.allSatisfy { $0.matches(node) })
            && !exclude.contains { $0.matches(node) }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
