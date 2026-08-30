import AppKit
import SwiftUI

/// Rockxy-inspired three-pane shell for the strategy-owned configuration
/// model. The shell owns selection and filtering while callers own actions.
struct ConfigurationWorkbench: View {
    let title: String
    let sections: [ConfigurationWorkbenchSection]
    let items: [ConfigurationWorkbenchSection: [ConfigurationWorkbenchItem]]
    var onAdd: ((ConfigurationWorkbenchSection) -> Void)?
    var onActivate: ((UUID) -> Void)?
    var statusMessage: String?
    var onToggleEnabled: ((ConfigurationWorkbenchSection, UUID) -> Void)?
    var onEdit: ((ConfigurationWorkbenchSection, UUID) -> Void)?

    @State private var section: ConfigurationWorkbenchSection
    @State private var selectedID: UUID?
    @State private var query = ""
    @State private var filter: WorkbenchFilter = .all
    @State private var compactLayout = false
    @State private var compactInspectorPresented = false
    @SceneStorage("mclash.configuration.inspectorVisible") private var inspectorVisible = true

    init(
        title: String = "Configuration",
        sections: [ConfigurationWorkbenchSection] = ConfigurationWorkbenchSection.allCases,
        items: [ConfigurationWorkbenchSection: [ConfigurationWorkbenchItem]] = [:],
        onAdd: ((ConfigurationWorkbenchSection) -> Void)? = nil,
        onActivate: ((UUID) -> Void)? = nil,
        statusMessage: String? = nil,
        onToggleEnabled: ((ConfigurationWorkbenchSection, UUID) -> Void)? = nil,
        onEdit: ((ConfigurationWorkbenchSection, UUID) -> Void)? = nil
    ) {
        self.title = title
        self.sections = sections
        self.items = items
        self.onAdd = onAdd
        self.onActivate = onActivate
        self.statusMessage = statusMessage
        self.onToggleEnabled = onToggleEnabled
        self.onEdit = onEdit
        _section = State(initialValue: sections.first ?? .workspaces)
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if sections.count > 1 {
                    workbenchSidebar
                        .frame(minWidth: geometry.size.width < 700 ? 144 : 180, idealWidth: 208, maxWidth: 240)
                    Divider()
                }
                itemList
                    .frame(minWidth: 0, idealWidth: 350, maxWidth: .infinity)
            }
            .onAppear { updateCompactLayout(for: geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in
                updateCompactLayout(for: width)
            }
        }
        .navigationTitle(AppLocalization.string(title))
        .background(Color(nsColor: .windowBackgroundColor))
        .inspector(isPresented: Binding(
            get: { inspectorVisible && !compactLayout },
            set: { inspectorVisible = $0 }
        )) {
            inspector
                .inspectorColumnWidth(min: 220, ideal: 300, max: 400)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    if compactLayout {
                        compactInspectorPresented = true
                    } else {
                        inspectorVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help(AppLocalization.string(inspectorButtonTitle))
                .accessibilityLabel(AppLocalization.string(inspectorButtonTitle))
            }
        }
        .sheet(isPresented: $compactInspectorPresented) {
            inspector
                .frame(minWidth: 320, minHeight: 420)
        }
        .onChange(of: section) { _, _ in
            query = ""
            filter = .all
            selectedID = currentItems.first?.id
        }
        .onChange(of: currentItemIDs) { _, _ in
            if let selectedID, currentItems.contains(where: { $0.id == selectedID }) {
                return
            }
            selectedID = currentItems.first?.id
        }
        .onChange(of: statusMessage, initial: true) { _, message in
            guard let message, !message.isEmpty else { return }
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue
                ]
            )
        }
        .onAppear {
            selectedID = filteredItems.first?.id
        }
    }

    private var currentItems: [ConfigurationWorkbenchItem] { items[section] ?? [] }
    private var currentItemIDs: [UUID] { currentItems.map(\.id) }
    private var filteredItems: [ConfigurationWorkbenchItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return currentItems.filter { item in
            let queryMatches = normalizedQuery.isEmpty
                || item.searchText.localizedCaseInsensitiveContains(normalizedQuery)
            let filterMatches: Bool
            switch filter {
            case .all: filterMatches = true
            case .enabled: filterMatches = item.isEnabled == true
            case .attention: filterMatches = item.isEnabled == false
            }
            return queryMatches && filterMatches
        }
    }
    private var selectedItem: ConfigurationWorkbenchItem? {
        filteredItems.first { $0.id == selectedID }
            ?? currentItems.first { $0.id == selectedID }
    }

    private func updateCompactLayout(for width: CGFloat) {
        // GeometryReader reports the primary column after the inspector has
        // taken its share.  Keep the three-pane layout at the normal 1,180pt
        // window, and fall back to the sheet when the remaining list column
        // would be too narrow to read (roughly the 900pt minimum window).
        let compact = width < 600
        compactLayout = compact
        // Hiding the system inspector can expand the content column. Keep the
        // user's explicit visibility choice off after that transition instead
        // of immediately reopening it and oscillating at the breakpoint.
        if compact && inspectorVisible {
            inspectorVisible = false
        }
        if !compact {
            compactInspectorPresented = false
        }
    }

    private var workbenchSidebar: some View {
        List(selection: $section) {
            Section(AppLocalization.string("Organize")) {
                ForEach(sections) { item in
                    HStack(spacing: 8) {
                        Label(AppLocalization.string(item.presentationTitle), systemImage: item.symbol)
                        Spacer(minLength: 4)
                        if let count = items[item]?.count, count > 0 {
                            Text(AppLocalization.number(count))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(item)
                }
            }
            Section {
                Label(AppLocalization.string("Unified strategy"), systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .accessibilityLabel(AppLocalization.string("Unified strategy: imports provide nodes only"))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .padding(.vertical, 8)
    }

    private var itemList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalization.string(section.presentationTitle))
                        .font(.title2.weight(.semibold))
                    Text(sectionSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(AppLocalization.number(filteredItems.count))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { onAdd?(section) } label: { Image(systemName: "plus") }
                    .buttonStyle(.bordered)
                    .help(AppLocalization.format("Add %@", AppLocalization.string(section.presentationSingularTitle)))
                    .accessibilityLabel(AppLocalization.format("Add %@", AppLocalization.string(section.presentationSingularTitle)))
                    .disabled(onAdd == nil)
            }
            .padding(.horizontal, MClashLayout.pagePadding)
            .padding(.top, MClashLayout.pagePadding)
            .padding(.bottom, 12)

            if let statusMessage, !statusMessage.isEmpty {
                Label(statusMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MClashLayout.pagePadding)
                    .padding(.bottom, 8)
            }

            ListFilterBar(query: $query, filter: $filter)
                .padding(.horizontal, MClashLayout.pagePadding)
                .padding(.bottom, 10)

            List(selection: $selectedID) {
                ForEach(filteredItems) { item in
                    ConfigurationWorkbenchRow(item: item)
                        .tag(item.id)
                }
            }
            .listStyle(.inset)
            .mclashListSurface(horizontalMargin: 8, verticalMargin: 4)
            .overlay {
                if filteredItems.isEmpty {
                    ContentUnavailableView {
                        Label(
                            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? AppLocalization.string("Nothing here yet")
                                : AppLocalization.string("No matching items"),
                            systemImage: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? section.symbol
                                : "magnifyingglass"
                        )
                    } description: {
                        Text(emptyDescription)
                    } actions: {
                        if let onAdd,
                           query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           filter == .all {
                            Button(AppLocalization.format("Add %@", AppLocalization.string(section.presentationSingularTitle))) {
                                onAdd(section)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
    }

    private var inspector: some View {
        Group {
            if let item = selectedItem {
                ConfigurationWorkbenchInspector(item: item, section: section, onActivate: onActivate, onToggleEnabled: onToggleEnabled, onEdit: onEdit)
            } else {
                ContentUnavailableView(AppLocalization.string("Select an item"), systemImage: "sidebar.right")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.32))
    }

    private var sectionSubtitle: String {
        switch section {
        case .nodes: AppLocalization.string("Search by name, host, protocol or source.")
        case .proxyGroups: AppLocalization.string("Pin nodes or describe automatic membership conditions.")
        case .rules: AppLocalization.string("Rules are evaluated from the lowest priority number.")
        case .entrances: AppLocalization.string("Choose where traffic enters the unified policy.")
        case .dns: AppLocalization.string("MClash resolves DNS using this shared policy.")
        case .sources: AppLocalization.string("Sources provide node data only.")
        case .workspaces: AppLocalization.string("The current configuration connects all sections.")
        }
    }

    private var inspectorButtonTitle: String {
        compactLayout || !inspectorVisible ? "Show Inspector" : "Hide Inspector"
    }

    private var emptyDescription: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AppLocalization.string("Try a different search term or clear the filter.")
        }
        if filter != .all {
            return AppLocalization.string("No items match this filter.")
        }
        switch section {
        case .sources: return AppLocalization.string("Add a subscription or local YAML source to import nodes.")
        case .nodes: return AppLocalization.string("Nodes appear here after a source is imported.")
        case .proxyGroups: return AppLocalization.string("Add a group, then choose fixed nodes or automatic matches.")
        case .rules: return AppLocalization.string("Add a rule to route an application, domain, IP or port.")
        case .entrances: return AppLocalization.string("No traffic entrances are configured yet.")
        case .dns: return AppLocalization.string("Create a DNS policy to choose resolvers and takeover behavior.")
        case .workspaces: return AppLocalization.string("Create a configuration to choose the active policy.")
        }
    }
}

private enum WorkbenchFilter: String, CaseIterable, Identifiable {
    case all, enabled, attention

    var id: Self { self }

    var title: String {
        switch self {
        case .all: AppLocalization.string("All")
        case .enabled: AppLocalization.string("Enabled")
        case .attention: AppLocalization.string("Review")
        }
    }
}

private struct ListFilterBar: View {
    @Binding var query: String
    @Binding var filter: WorkbenchFilter

    var body: some View {
        HStack(spacing: 10) {
            Picker(AppLocalization.string("Filter"), selection: $filter) {
                ForEach(WorkbenchFilter.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 110, idealWidth: 170, maxWidth: 190)
            .layoutPriority(1)
            .labelsHidden()

            TextField(AppLocalization.string("Search"), text: $query)
                .textFieldStyle(.roundedBorder)
                .overlay(alignment: .trailing) {
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 7)
                        .accessibilityLabel(AppLocalization.string("Clear search"))
                    }
                }
        }
    }
}

private struct ConfigurationWorkbenchRow: View {
    let item: ConfigurationWorkbenchItem
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).foregroundStyle(.tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let isEnabled = item.isEnabled {
                Image(systemName: isEnabled ? "circle.fill" : "circle")
                    .font(.caption2)
                    .foregroundStyle(isEnabled ? .green : .secondary)
                    .accessibilityLabel(AppLocalization.string(isEnabled ? "Enabled" : "Disabled"))
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct ConfigurationWorkbenchInspector: View {
    let item: ConfigurationWorkbenchItem
    let section: ConfigurationWorkbenchSection
    var onActivate: ((UUID) -> Void)?
    var onToggleEnabled: ((ConfigurationWorkbenchSection, UUID) -> Void)?
    var onEdit: ((ConfigurationWorkbenchSection, UUID) -> Void)?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MClashLayout.panelSpacing) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.symbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if onActivate != nil {
                    Button(AppLocalization.string("Use This Configuration")) { onActivate?(item.id) }
                        .buttonStyle(.borderedProminent)
                }
                if let isEnabled = item.isEnabled, onToggleEnabled != nil {
                    Button(AppLocalization.string(isEnabled ? "Disable" : "Enable")) {
                        onToggleEnabled?(section, item.id)
                    }
                    .buttonStyle(.bordered)
                }
                if let onEdit {
                    Button(AppLocalization.string("Edit")) { onEdit(section, item.id) }
                        .buttonStyle(.bordered)
                }
                Divider()
                ForEach(Array(item.metadata.enumerated()), id: \.offset) { _, pair in
                    LabeledContent(pair.0, value: pair.1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MClashLayout.pagePadding)
        }
        .accessibilityElement(children: .contain)
    }
}

private extension ConfigurationWorkbenchItem {
    var searchText: String {
        ([title, subtitle, detail] + metadata.flatMap { [$0.0, $0.1] })
            .joined(separator: " ")
    }
}
