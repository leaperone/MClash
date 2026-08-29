import SwiftUI

struct ProxyNodePicker: View {
    @Bindable var model: AppModel
    let group: MihomoProxy
    @Binding var isPresented: Bool
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.headline)
                    Text(group.groupBehavior == .selector
                        ? AppLocalization.string("Choose a proxy node")
                        : AppLocalization.string("Pin the automatic group to a preferred node"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.measureGroupDelays(group: group.name) }
                } label: {
                    if model.isPerforming(.measureGroupDelay(group.name)) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Test Latencies", systemImage: "speedometer")
                    }
                }
                .accessibilityLabel(AppLocalization.string("Test Latencies"))
                .disabled(model.networkStateTransitionInProgress)
            }
            .padding(14)

            Divider()

            List(filteredNodes, id: \.self) { proxy in
                Button {
                    Task {
                        let selected = await model.selectProxy(group: group.name, proxy: proxy)
                        if selected {
                            isPresented = false
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        if model.pendingProxySelections[group.name] == proxy {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: nodeSymbol(proxy))
                                .foregroundStyle(nodeColor(proxy))
                                .accessibilityHidden(true)
                        }
                        Text(proxy)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .help(proxy)
                        Spacer()
                        if let delay = model.proxyDelay(for: proxy, in: group.name) {
                            Text(
                                AppLocalization.format(
                                    "%@ ms",
                                    formattedCount(delay)
                                )
                            )
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(delayColor(delay))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(
                    isAlreadyChosen(proxy)
                        || group.groupBehavior?.supportsSelectionUpdate != true
                        || model.networkStateTransitionInProgress
                        || model.isPerforming(.selectProxy(group.name))
                )
                .accessibilityLabel(
                    accessibilityLabel(proxy)
                )
            }
            .searchable(text: $searchText, prompt: "Search nodes")
            .overlay {
                if !normalizedSearchText.isEmpty, filteredNodes.isEmpty {
                    ContentUnavailableView.search(text: normalizedSearchText)
                }
            }
        }
        .frame(minWidth: 340, idealWidth: 400, maxWidth: 480, minHeight: 360, idealHeight: 440)
    }

    private var filteredNodes: [String] {
        guard !normalizedSearchText.isEmpty else { return group.all }
        return group.all.filter { $0.localizedCaseInsensitiveContains(normalizedSearchText) }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay <= 0 { return .secondary }
        if delay < 150 { return .green }
        if delay < 350 { return .orange }
        return .red
    }

    private func nodeSymbol(_ proxy: String) -> String {
        if proxy == group.fixedOverride { return "pin.circle.fill" }
        if proxy == group.now { return "checkmark.circle.fill" }
        if model.proxyAlive(for: proxy, in: group.name) == false {
            return "exclamationmark.circle"
        }
        return "circle"
    }

    private func nodeColor(_ proxy: String) -> Color {
        if proxy == group.fixedOverride { return .orange }
        if proxy == group.now { return .accentColor }
        if model.proxyAlive(for: proxy, in: group.name) == false { return .red }
        return .secondary
    }

    private func accessibilityLabel(_ proxy: String) -> String {
        var parts = [proxy]
        if model.pendingProxySelections[group.name] == proxy {
            parts.append(AppLocalization.string("Switching"))
        }
        if proxy == group.fixedOverride {
            parts.append(AppLocalization.string("Pinned preference"))
        }
        if proxy == group.now { parts.append(AppLocalization.string("Selected")) }
        if model.proxyAlive(for: proxy, in: group.name) == false {
            parts.append(AppLocalization.string("Unavailable"))
        }
        if let delay = model.proxyDelay(for: proxy, in: group.name) {
            parts.append(
                AppLocalization.format(
                    "%@ milliseconds",
                    formattedCount(delay)
                )
            )
        }
        return parts.joined(separator: ", ")
    }

    private func isAlreadyChosen(_ proxy: String) -> Bool {
        if group.groupBehavior == .selector { return proxy == group.now }
        return proxy == group.fixedOverride
    }
}
