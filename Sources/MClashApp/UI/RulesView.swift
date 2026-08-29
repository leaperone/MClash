import Observation
import OSLog
import SwiftUI

private let rulesPerformanceLogger = Logger(
    subsystem: "one.leaper.mclash",
    category: "RulesPerformance"
)

struct RulesView: View {
    @Bindable var model: AppModel
    @SceneStorage("mclash.rules.searchText") private var searchText = ""
    @State private var presentation = RulePresentationStore()
    @State private var hasCompletedInitialLoad = false

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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.isConnected,
                   !model.rules.isEmpty,
                   !presentation.isPreparingRows,
                   presentation.totalMatches > 0 || presentation.isFiltering {
                    RuleResultsStatusBar(presentation: presentation)
                }
            }
            .task(id: [
                model.controllerIsReady,
                model.mainWindowPresentationTelemetryIsVisible,
            ]) {
                guard model.controllerIsReady,
                      model.mainWindowPresentationTelemetryIsVisible else {
                    if !model.controllerIsReady {
                        hasCompletedInitialLoad = false
                    }
                    return
                }
                await loadRulesWhenAvailable()
                guard !Task.isCancelled,
                      model.controllerIsReady,
                      model.mainWindowPresentationTelemetryIsVisible else { return }
                hasCompletedInitialLoad = true
                while !Task.isCancelled,
                      model.controllerIsReady,
                      model.mainWindowPresentationTelemetryIsVisible {
                    do {
                        try await Task.sleep(for: .seconds(15))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled,
                          model.controllerIsReady,
                          model.mainWindowPresentationTelemetryIsVisible,
                          model.canPerform(.refreshRules) else { continue }
                    await model.refreshRules()
                }
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
                    Text(
                        AppLocalization.format(
                            "Rules %@ · %@",
                            formattedCount(model.rules.count),
                            rulesFreshnessTitle
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(rulesFreshnessHelp)
                }
                ToolbarItem {
                    Menu {
                        Button {
                            Task { await model.refreshRules() }
                        } label: {
                            Label("Refresh Rules", systemImage: "arrow.clockwise")
                        }
                        .disabled(
                            !model.controllerIsReady
                                || !model.canPerform(.refreshRules)
                        )
                    } label: {
                        if model.isPerforming(.refreshRules) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("More", systemImage: "ellipsis.circle")
                                .labelStyle(.iconOnly)
                        }
                    }
                    .accessibilityLabel(AppLocalization.string("Refresh Rules"))
                }
            }
    }

    private var rulesFreshnessTitle: String {
        guard let loadedAt = model.rulesLastLoadedAt else {
            return AppLocalization.string("Not loaded")
        }
        return AppLocalization.format(
            "Updated %@",
            AppLocalization.relativeDate(loadedAt)
        )
    }

    private var rulesFreshnessHelp: String {
        guard let loadedAt = model.rulesLastLoadedAt else {
            return AppLocalization.string("Mihomo rule statistics have not been loaded.")
        }
        return AppLocalization.format(
            "Mihomo rule statistics last loaded %@. They refresh every 15 seconds while this page is open.",
            AppLocalization.relativeDate(loadedAt)
        )
    }

    @ViewBuilder
    private var ruleContent: some View {
        Group {
            if !model.isConnected {
                DisconnectedUnavailableView(
                    model: model,
                    title: AppLocalization.string("Connect to inspect rules"),
                    systemImage: "list.bullet.rectangle",
                    description: AppLocalization.string(
                        "Rules are read from the active mihomo runtime configuration."
                    )
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
            } else if model.rules.isEmpty,
                      model.isPerforming(.refreshRules) || !hasCompletedInitialLoad {
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
                    ContentUnavailableView(
                        AppLocalization.string("No matching rules"),
                        systemImage: "magnifyingglass",
                        description: Text(
                            AppLocalization.format(
                                "No rules contain “%@”.",
                                searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                        )
                    )
                } else {
                    RuleTableSurface(
                        rows: presentation.rows,
                        revision: presentation.presentationRevision
                    )
                    .equatable()
                }
            }
        }
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
        if !Task.isCancelled,
           model.controllerIsReady,
           model.mainWindowPresentationTelemetryIsVisible,
           model.rules.isEmpty,
           model.rulesErrorMessage == nil,
           model.canPerform(.refreshRules) {
            await model.refreshRules()
        }
    }
}

private struct RuleTableSurface: Equatable, View {
    let rows: [RuleTableRow]
    let revision: UInt64

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision
    }

    var body: some View {
        Table(rows) {
            TableColumn("#") { row in
                Text("\(row.rule.index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel(
                        AppLocalization.format("Rule %d", row.rule.index + 1)
                    )
            }
            .width(min: 38, ideal: 46, max: 58)

            TableColumn("Match") { row in
                VStack(alignment: .leading, spacing: 2) {
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
                    Text(row.displayPayload)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .help("\(row.rule.type) · \(row.displayPayload)")
                .accessibilityLabel(
                    row.rule.extra?.disabled == true
                        ? AppLocalization.format(
                            "%@, %@, %@",
                            row.rule.type,
                            row.displayPayload,
                            AppLocalization.string("Disabled")
                        )
                        : AppLocalization.format(
                            "%@, %@",
                            row.rule.type,
                            row.displayPayload
                        )
                )
            }
            .width(min: 300, ideal: 620, max: 1_200)

            TableColumn("Policy") { row in
                Text(row.rule.proxy)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(row.rule.proxy)
                    .accessibilityLabel(
                        AppLocalization.format("Policy %@", row.rule.proxy)
                    )
            }
            .width(min: 120, ideal: 180, max: 320)

            TableColumn("Activity") { row in
                VStack(alignment: .trailing, spacing: 2) {
                    if let hitCount = row.rule.extra?.hitCount {
                        Text(
                            AppLocalization.format(
                                "Hits %@",
                                hitCount.formatted(
                                    .number
                                        .grouping(.automatic)
                                        .locale(AppLocalization.selectedLocale)
                                )
                            )
                        )
                            .monospacedDigit()
                    } else {
                        Text("—")
                    }
                    if let lastHitAt = row.lastHitAt {
                        Text(AppLocalization.relativeDate(lastHitAt))
                    } else if row.rule.extra != nil {
                        Text("Never")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 120, max: 160)
        }
        .accessibilityLabel(AppLocalization.string("Runtime rules"))
    }
}

private struct RuleResultsStatusBar: View {
    let presentation: RulePresentationStore

    var body: some View {
        HStack(spacing: 10) {
            if presentation.isFiltering {
                ProgressView()
                    .controlSize(.small)
                Text("Searching rules…")
            } else {
                Text(presentation.resultSummary)
                    .monospacedDigit()
            }

            Spacer(minLength: 12)

            if presentation.canLoadMore {
                Button("Load 500 More") {
                    presentation.loadMore()
                }
                .controlSize(.small)
                .help("Show the next 500 matching rules")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

@MainActor
@Observable
final class RulePresentationStore {
    private static let pageSize = 500

    private(set) var rows: [RuleTableRow] = []
    private(set) var isPreparingRows = false
    private(set) var isFiltering = false
    private(set) var totalMatches = 0
    private(set) var presentationRevision: UInt64 = 0

    private var allRows: [RuleTableRow] = []
    private var matchingRows: [RuleTableRow] = []
    private var visibleLimit = pageSize
    private var activeQuery = ""
    private var requestedQuery = ""
    private var rulesRevision: UInt64 = 0
    private var searchRevision: UInt64 = 0
    private var filterRevision: UInt64 = 0
    private var buildTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?

    var canLoadMore: Bool {
        rows.count < totalMatches
    }

    var resultSummary: String {
        AppLocalization.format(
            activeQuery.isEmpty
                ? "Showing %@ of %@ rules"
                : "Showing %@ of %@ matches",
            formattedCount(rows.count),
            formattedCount(totalMatches)
        )
    }

    func updateRules(_ rules: [MihomoRule]) {
        rulesRevision &+= 1
        filterRevision &+= 1
        let revision = rulesRevision

        buildTask?.cancel()
        buildTask = nil
        filterTask?.cancel()
        filterTask = nil

        allRows = []
        matchingRows = []
        rows = []
        totalMatches = 0
        visibleLimit = Self.pageSize
        isFiltering = false
        presentationRevision &+= 1
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
        isFiltering = true

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
            guard !allRows.isEmpty else {
                isFiltering = isPreparingRows
                return
            }
            scheduleFilter(query: query)
        }
    }

    func loadMore() {
        guard canLoadMore else { return }
        visibleLimit = min(visibleLimit + Self.pageSize, totalMatches)
        publishVisibleRows(reason: "load-more")
    }

    func cancelPendingWork() {
        buildTask?.cancel()
        buildTask = nil
        searchTask?.cancel()
        searchTask = nil
        filterTask?.cancel()
        filterTask = nil
        isPreparingRows = false
        isFiltering = false

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
        visibleLimit = Self.pageSize

        guard !query.isEmpty else {
            matchingRows = allRows
            totalMatches = matchingRows.count
            isFiltering = false
            publishVisibleRows(reason: "empty-query")
            return
        }

        isFiltering = true

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

            matchingRows = filteredRows
            totalMatches = filteredRows.count
            isFiltering = false
            filterTask = nil
            publishVisibleRows(reason: "search")
        }
    }

    private func publishVisibleRows(reason: String) {
        let publishStarted = DispatchTime.now().uptimeNanoseconds
        rows = Array(matchingRows.prefix(visibleLimit))
        presentationRevision &+= 1
        let visibleCount = rows.count
        let totalCount = totalMatches
        let revision = presentationRevision
        rulesPerformanceLogger.debug(
            "publish reason=\(reason, privacy: .public) visible=\(visibleCount, privacy: .public) total=\(totalCount, privacy: .public) revision=\(revision, privacy: .public)"
        )

        // This callback cannot run while SwiftUI/AppKit is monopolizing the main
        // run loop. Its delay makes a large table reconciliation visible in logs
        // without recording any rule or query content.
        DispatchQueue.main.async {
            let readyDelayMilliseconds =
                (DispatchTime.now().uptimeNanoseconds - publishStarted) / 1_000_000
            rulesPerformanceLogger.debug(
                "main-ready visible=\(visibleCount, privacy: .public) total=\(totalCount, privacy: .public) revision=\(revision, privacy: .public) delayMs=\(readyDelayMilliseconds, privacy: .public)"
            )
        }
    }
}

enum RulePresentationComputation {
    static func buildRows(from rules: [MihomoRule]) -> [RuleTableRow]? {
        let started = DispatchTime.now().uptimeNanoseconds
        var rows: [RuleTableRow] = []
        rows.reserveCapacity(rules.count)

        for (offset, rule) in rules.enumerated() {
            if offset.isMultiple(of: 256), Task.isCancelled { return nil }
            rows.append(RuleTableRow(rule: rule))
        }
        let elapsedMilliseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        rulesPerformanceLogger.debug(
            "build source=\(rules.count, privacy: .public) durationMs=\(elapsedMilliseconds, privacy: .public)"
        )
        return rows
    }

    static func filter(_ rows: [RuleTableRow], query: String) -> [RuleTableRow]? {
        let started = DispatchTime.now().uptimeNanoseconds
        var matches: [RuleTableRow] = []
        matches.reserveCapacity(min(rows.count, 512))

        for (offset, row) in rows.enumerated() {
            if offset.isMultiple(of: 256), Task.isCancelled { return nil }
            if row.matches(query) {
                matches.append(row)
            }
        }
        let elapsedMilliseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        rulesPerformanceLogger.debug(
            "filter queryLength=\(query.count, privacy: .public) source=\(rows.count, privacy: .public) matches=\(matches.count, privacy: .public) durationMs=\(elapsedMilliseconds, privacy: .public)"
        )
        return matches
    }
}

struct RuleTableRow: Identifiable, Sendable {
    let rule: MihomoRule
    let payload: String
    let lastHitAt: Date?

    init(rule: MihomoRule) {
        self.rule = rule
        payload = rule.payload
        if let value = rule.extra?.hitAt,
           !value.isEmpty,
           rule.extra?.hitCount != 0 {
            lastHitAt = try? Date(value, strategy: .iso8601)
        } else {
            lastHitAt = nil
        }
    }

    var id: Int { rule.index }

    var displayPayload: String {
        payload.isEmpty ? AppLocalization.string("Any") : payload
    }

    func matches(_ query: String) -> Bool {
        rule.type.localizedCaseInsensitiveContains(query)
            || rule.payload.localizedCaseInsensitiveContains(query)
            || rule.proxy.localizedCaseInsensitiveContains(query)
    }
}
