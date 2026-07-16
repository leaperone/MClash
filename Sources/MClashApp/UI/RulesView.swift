import SwiftUI

struct RulesView: View {
    @Bindable var model: AppModel
    @State private var searchText = ""
    @State private var debouncedSearchText = ""

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
            .task(id: searchText) {
                do {
                    try await Task.sleep(for: .milliseconds(180))
                    debouncedSearchText = searchText
                } catch {
                    return
                }
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
            } else {
                let rows = filteredRuleRows
                if rows.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ruleTable(rows)
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

    private var filteredRuleRows: [RuleTableRow] {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.rules.compactMap { rule in
            guard query.isEmpty
                    || rule.type.localizedCaseInsensitiveContains(query)
                    || rule.payload.localizedCaseInsensitiveContains(query)
                    || rule.proxy.localizedCaseInsensitiveContains(query) else {
                return nil
            }
            return RuleTableRow(rule: rule)
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
        if model.controllerIsReady,
           model.rules.isEmpty,
           model.rulesErrorMessage == nil,
           model.canPerform(.refreshRules) {
            await model.refreshRules()
        }
    }
}

private struct RuleTableRow: Identifiable {
    let rule: MihomoRule

    var id: Int { rule.index }
    var payload: String { rule.payload.isEmpty ? "Any" : rule.payload }
}
