import SwiftUI

struct RulesView: View {
    @Bindable var model: AppModel
    @State private var searchText = ""
    @State private var debouncedSearchText = ""

    var body: some View {
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
            } else if filteredRules.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(filteredRules, id: \.index) { rule in
                    RuleRow(rule: rule)
                }
                .listStyle(.inset)
                .mclashListSurface()
            }
        }
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

    private var filteredRules: [MihomoRule] {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.rules }
        return model.rules.filter { rule in
            rule.type.localizedCaseInsensitiveContains(query)
                || rule.payload.localizedCaseInsensitiveContains(query)
                || rule.proxy.localizedCaseInsensitiveContains(query)
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

private struct RuleRow: View {
    let rule: MihomoRule

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(rule.index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(minWidth: 38, alignment: .trailing)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(rule.type)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if rule.extra?.disabled == true {
                        Text("Disabled")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(rule.payload.isEmpty ? "Any" : rule.payload)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            if let hitCount = rule.extra?.hitCount, hitCount > 0 {
                Text("\(hitCount) hits")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(rule.proxy)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Rule \(rule.index + 1), \(rule.type), \(rule.payload), policy \(rule.proxy)"
        )
    }
}
