import Observation
import SwiftUI

struct RulesView: View {
    @Bindable var model: AppModel
    @State private var searchText = ""
    @State private var presentation = RulePresentationStore()

    var body: some View {
        ruleContent
            .navigationTitle("Rules")
            .mclashPageSurface()
            .searchable(text: $searchText, prompt: "Type, payload, or policy")
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.errorMessage == nil,
                   let message = model.rulesErrorMessage,
                   !model.rules.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(message)
                            .font(.callout)
                            .lineLimit(2)
                            .help(message)
                        Spacer()
                        Button("Retry") { Task { await model.refreshRules() } }
                            .disabled(!model.canPerform(.refreshRules))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.bar)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
            .task(id: model.controllerIsReady) {
                await loadRulesWhenAvailable()
            }
            .onChange(of: model.rules, initial: true) { _, rules in
                presentation.updateRules(rules)
            }
            .onChange(of: searchText, initial: true) { _, query in
                presentation.updateSearch(query)
            }
            .onDisappear {
                presentation.cancelPendingWork()
            }
            .toolbar {
                ToolbarItem {
                    Text("\(formattedCount(model.rules.count)) rules")
                        .foregroundStyle(.secondary)
                }
                ToolbarItem {
                    Button {
                        Task { await model.refreshRules() }
                    } label: {
                        if model.isPerforming(.refreshRules) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(
                        !model.controllerIsReady
                            || !model.canPerform(.refreshRules)
                    )
                }
            }
    }

    @ViewBuilder
    private var ruleContent: some View {
        Group {
            if !model.isConnected {
                ContentUnavailableView(
                    "Connect to inspect rules",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Rules are read from the active mihomo runtime configuration.")
                )
            } else if case let .degraded(message) = model.controllerState {
                ContentUnavailableView {
                    Label("Rules unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Reconnect") { Task { await model.restartConnection() } }
                        .disabled(!model.canPerform(.connection))
                    Button("View Logs") { model.selection = .logs }
                }
            } else if model.isPerforming(.refreshRules), model.rules.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading rules…")
                        .foregroundStyle(.secondary)
                }
            } else if let message = model.rulesErrorMessage, model.rules.isEmpty {
                ContentUnavailableView {
                    Label("Rules unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await model.refreshRules() } }
                        .disabled(!model.canPerform(.refreshRules))
                    Button("View Logs") { model.selection = .logs }
                }
            } else if model.rules.isEmpty {
                ContentUnavailableView(
                    "No rules",
                    systemImage: "list.bullet.rectangle",
                    description: Text("The active runtime configuration did not expose any rules.")
                )
            } else if presentation.isPreparingRows, presentation.rows.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Preparing rules…")
                        .foregroundStyle(.secondary)
                }
            } else {
                if presentation.rows.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ruleTable(presentation.rows)
                }
            }
        }
    }

    private func ruleTable(_ rows: [RuleTableRow]) -> some View {
        Table(rows) {
            TableColumn("#") { row in
                Text("\(row.rule.index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel("Rule \(row.rule.index + 1)")
            }
            .width(min: 38, ideal: 46, max: 58)

            TableColumn("Type") { row in
                HStack(spacing: 7) {
                    Text(row.rule.type)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if row.rule.extra?.disabled == true {
                        Text("Disabled")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .help(row.rule.type)
                .accessibilityLabel(
                    row.rule.extra?.disabled == true
                        ? "\(row.rule.type), disabled"
                        : row.rule.type
                )
            }
            .width(min: 100, ideal: 140, max: 220)

            TableColumn("Payload") { row in
                Text(row.payload)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .help(row.payload)
                    .accessibilityLabel(row.payload)
            }
            .width(min: 220, ideal: 460, max: 1_200)

            TableColumn("Hits") { row in
                if let hitCount = row.rule.extra?.hitCount, hitCount > 0 {
                    let hitCountText = hitCount.formatted(.number.grouping(.automatic))
                    Text(hitCountText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel("\(hitCountText) hits")
                }
            }
            .width(min: 54, ideal: 72, max: 96)

            TableColumn("Policy") { row in
                Text(row.rule.proxy)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(row.rule.proxy)
                    .accessibilityLabel("Policy \(row.rule.proxy)")
            }
            .width(min: 120, ideal: 180, max: 320)
        }
        .accessibilityLabel("Runtime rules")
    }

    private func loadRulesWhenAvailable() async {
        guard model.controllerIsReady, model.rules.isEmpty, model.rulesErrorMessage == nil else {
            return
        }
        while model.controllerIsReady,
              model.rules.isEmpty,
              model.rulesErrorMessage == nil,
              !model.canPerform(.refreshRules) {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
        if model.controllerIsReady,
           model.rules.isEmpty,
           model.rulesErrorMessage == nil,
           model.canPerform(.refreshRules) {
            await model.refreshRules()
        }
    }
}

@MainActor
@Observable
private final class RulePresentationStore {
    private(set) var rows: [RuleTableRow] = []
    private(set) var isPreparingRows = false

    private var allRows: [RuleTableRow] = []
    private var activeQuery = ""
    private var requestedQuery = ""
    private var rulesRevision: UInt64 = 0
    private var searchRevision: UInt64 = 0
    private var filterRevision: UInt64 = 0
    private var buildTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?

    func updateRules(_ rules: [MihomoRule]) {
        rulesRevision &+= 1
        filterRevision &+= 1
        let revision = rulesRevision

        buildTask?.cancel()
        buildTask = nil
        filterTask?.cancel()
        filterTask = nil

        allRows = []
        rows = []
        guard !rules.isEmpty else {
            isPreparingRows = false
            return
        }

        isPreparingRows = true
        let worker = Task.detached(priority: .userInitiated) {
            RulePresentationComputation.buildRows(from: rules)
        }
        buildTask = Task { [weak self] in
            let builtRows = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard let self,
                  !Task.isCancelled,
                  revision == rulesRevision,
                  let builtRows else {
                return
            }

            allRows = builtRows
            isPreparingRows = false
            buildTask = nil

            // A pending debounce owns the next presentation. Publishing the previous
            // query here would briefly flash stale results while the user is typing.
            guard searchTask == nil else { return }
            scheduleFilter(query: activeQuery)
        }
    }

    func updateSearch(_ searchText: String) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != requestedQuery else { return }

        requestedQuery = query
        searchRevision &+= 1
        filterRevision &+= 1
        let revision = searchRevision

        searchTask?.cancel()
        searchTask = nil
        filterTask?.cancel()
        filterTask = nil

        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }

            guard let self,
                  !Task.isCancelled,
                  revision == searchRevision else {
                return
            }

            activeQuery = query
            searchTask = nil
            guard !allRows.isEmpty else { return }
            scheduleFilter(query: query)
        }
    }

    func cancelPendingWork() {
        buildTask?.cancel()
        buildTask = nil
        searchTask?.cancel()
        searchTask = nil
        filterTask?.cancel()
        filterTask = nil

        // Make an initial onChange reschedule a debounce if the view disappeared
        // before the most recently requested query became active.
        requestedQuery = activeQuery
    }

    private func scheduleFilter(query: String) {
        filterRevision &+= 1
        let revision = filterRevision
        let expectedRulesRevision = rulesRevision
        let expectedSearchRevision = searchRevision

        filterTask?.cancel()
        filterTask = nil

        guard !query.isEmpty else {
            rows = allRows
            return
        }

        let sourceRows = allRows
        let worker = Task.detached(priority: .userInitiated) {
            RulePresentationComputation.filter(sourceRows, query: query)
        }
        filterTask = Task { [weak self] in
            let filteredRows = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard let self,
                  !Task.isCancelled,
                  revision == filterRevision,
                  expectedRulesRevision == rulesRevision,
                  expectedSearchRevision == searchRevision,
                  let filteredRows else {
                return
            }

            rows = filteredRows
            filterTask = nil
        }
    }
}

private enum RulePresentationComputation {
    static func buildRows(from rules: [MihomoRule]) -> [RuleTableRow]? {
        var rows: [RuleTableRow] = []
        rows.reserveCapacity(rules.count)

        for (offset, rule) in rules.enumerated() {
            if offset.isMultiple(of: 256), Task.isCancelled { return nil }
            rows.append(RuleTableRow(rule: rule))
        }
        return rows
    }

    static func filter(_ rows: [RuleTableRow], query: String) -> [RuleTableRow]? {
        var matches: [RuleTableRow] = []
        matches.reserveCapacity(min(rows.count, 512))

        for (offset, row) in rows.enumerated() {
            if offset.isMultiple(of: 256), Task.isCancelled { return nil }
            if row.matches(query) {
                matches.append(row)
            }
        }
        return matches
    }
}

private struct RuleTableRow: Identifiable, Sendable {
    let rule: MihomoRule
    let payload: String

    init(rule: MihomoRule) {
        self.rule = rule
        payload = rule.payload.isEmpty ? "Any" : rule.payload
    }

    var id: Int { rule.index }

    func matches(_ query: String) -> Bool {
        rule.type.localizedCaseInsensitiveContains(query)
            || rule.payload.localizedCaseInsensitiveContains(query)
            || rule.proxy.localizedCaseInsensitiveContains(query)
    }
}
