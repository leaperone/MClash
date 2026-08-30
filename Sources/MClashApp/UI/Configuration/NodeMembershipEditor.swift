import SwiftUI

/// A selector-first node membership editor. It keeps fixed pins separate from
/// automatic matches, so a source refresh can add/remove matching nodes
/// without asking the user to maintain hundreds of toggles.
struct NodeMembershipEditor: View {
    let nodes: [Node]
    let sourceNames: [SourceID: String]
    @Binding var selectedNodeIDs: Set<NodeID>
    @Binding var selectors: [NodeSelector]

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
    @State private var isLoading = false
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

    private var activeFixedIDs: Set<NodeID> {
        Set(activeSelector?.fixedNodeIDs ?? [])
    }

    private var fixedNodes: [Node] {
        let query = fixedSearch.trimmed
        return nodes.filter { node in
            activeFixedIDs.contains(node.id)
                && (query.isEmpty
                    || (node.userAlias ?? node.displayName).localizedCaseInsensitiveContains(query)
                    || node.host.localizedCaseInsensitiveContains(query)
                    || node.proto.rawValue.localizedCaseInsensitiveContains(query))
        }.sorted(by: stableNodeOrder)
    }

    private var availableLibraryNodes: [Node] {
        let query = librarySearch.trimmed
        guard !query.isEmpty else { return [] }
        let pinned = Set(selectors.flatMap(\.fixedNodeIDs))
        return nodes.filter { node in
            !pinned.contains(node.id)
                && ((node.userAlias ?? node.displayName).localizedCaseInsensitiveContains(query)
                    || node.host.localizedCaseInsensitiveContains(query)
                    || node.proto.rawValue.localizedCaseInsensitiveContains(query)
                    || node.tags.contains { $0.localizedCaseInsensitiveContains(query) })
        }.sorted(by: stableNodeOrder)
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
                        addSelector()
                        librarySearchFocused = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(selectors) { selector in
                            Button {
                                selectSelector(selector.id)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: selector.id == activeSelectorID ? "checkmark.circle.fill" : "line.3.horizontal.decrease.circle")
                                    Text(selector.name)
                                    Text(AppLocalization.number(selector.fixedNodeIDs.count))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel(AppLocalization.format("Selector %@", selector.name))
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
                if !matchedNodes.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(matchedNodes) { node in
                                nodeRow(node, selected: activeFixedIDs.contains(node.id))
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            } else if matchedNodes.isEmpty {
                Label(AppLocalization.string("No nodes match these conditions"), systemImage: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(matchedNodes) { node in
                            nodeRow(node, selected: activeFixedIDs.contains(node.id))
                        }
                    }
                }
                .frame(maxHeight: 150)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var fixedMembers: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(AppLocalization.string("Fixed nodes"), systemImage: "pin")
                    .font(.headline)
                Spacer()
                Text(AppLocalization.format("%d pinned", activeFixedIDs.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            let missingFixedCount = activeFixedIDs.subtracting(Set(nodes.map(\.id))).count
            if missingFixedCount > 0 {
                Label(
                    AppLocalization.format("%d pinned nodes are unavailable after the last source refresh.", missingFixedCount),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            if activeSelectorID == nil {
                Text(AppLocalization.string("Add a selector before pinning a node. Pins are attached to the selected selector and never replaced silently."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField(AppLocalization.string("Search pinned nodes"), text: $fixedSearch)
                    .textFieldStyle(.roundedBorder)
                if fixedNodes.isEmpty {
                    Text(AppLocalization.string("No pinned nodes for this selector."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(fixedNodes) { node in
                            nodeRow(node, selected: true)
                                .contentShape(Rectangle())
                                .onTapGesture { togglePin(node.id, pinned: false) }
                        }
                    }
                }
                TextField(AppLocalization.string("Search node library to pin a node"), text: $librarySearch)
                    .textFieldStyle(.roundedBorder)
                    .focused($librarySearchFocused)
                if !availableLibraryNodes.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(availableLibraryNodes.prefix(100)) { node in
                                nodeRow(node, selected: false)
                                    .contentShape(Rectangle())
                                    .onTapGesture { togglePin(node.id, pinned: true) }
                            }
                        }
                    }
                    .frame(maxHeight: 130)
                    if availableLibraryNodes.count > 100 {
                        Text(AppLocalization.string("Showing the first 100 matches. Refine your search."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func nodeRow(_ node: Node, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
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
            fixedNodeIDs: activeSelector?.fixedNodeIDs ?? []
        )
    }

    private func prepare() {
        isLoading = true
        if selectors.isEmpty {
            if !selectedNodeIDs.isEmpty {
                let selector = NodeSelector(name: AppLocalization.string("Pinned nodes"), fixedNodeIDs: selectedNodeIDs.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString })
                selectors = [selector]
            }
        } else {
            // Older manifests stored fixed node members in `members` rather
            // than selector.fixedNodeIDs. Fold those durable pins into the
            // first selector so opening and saving the editor cannot lose them.
            let selectorPins = Set(selectors.flatMap(\.fixedNodeIDs))
            let legacyPins = selectedNodeIDs.subtracting(selectorPins)
            guard !legacyPins.isEmpty else {
                activeSelectorID = selectors.first?.id
                loadActiveSelector()
                isLoading = false
                return
            }
            let firstID = selectors[0].id
            if let index = selectors.firstIndex(where: { $0.id == firstID }) {
                let existing = Set(selectors[index].fixedNodeIDs)
                selectors[index].fixedNodeIDs = existing
                    .union(legacyPins)
                    .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            }
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
    }

    private func selectSelector(_ id: UUID) {
        guard id != activeSelectorID else { return }
        syncSelector()
        activeSelectorID = id
        loadActiveSelector()
    }

    private func removeActiveSelector() {
        guard let activeSelectorID else { return }
        selectors.removeAll { $0.id == activeSelectorID }
        self.activeSelectorID = selectors.first?.id
        if self.activeSelectorID == nil {
            selectorName = ""
            clearFields()
        } else { loadActiveSelector() }
        refreshSelectedPins()
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
        refreshSelectedPins()
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
        selectors[index] = selector
        refreshSelectedPins()
    }

    private func togglePin(_ id: NodeID, pinned: Bool) {
        guard let activeSelectorID,
              let index = selectors.firstIndex(where: { $0.id == activeSelectorID }) else { return }
        var ids = Set(selectors[index].fixedNodeIDs)
        if pinned { ids.insert(id) } else { ids.remove(id) }
        selectors[index].fixedNodeIDs = ids.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        refreshSelectedPins()
    }

    private func refreshSelectedPins() {
        selectedNodeIDs = Set(selectors.flatMap(\.fixedNodeIDs))
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
