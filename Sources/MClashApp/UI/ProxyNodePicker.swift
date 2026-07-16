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
                    Text("Choose a proxy node")
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
                        Label("Test All", systemImage: "speedometer")
                    }
                }
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
                        Image(systemName: nodeSymbol(proxy))
                            .foregroundStyle(nodeColor(proxy))
                            .accessibilityHidden(true)
                        Text(proxy)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .help(proxy)
                        Spacer()
                        if let delay = model.proxyDelays[proxy] {
                            Text("\(delay) ms")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(delayColor(delay))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(
                    proxy == group.now
                        || model.networkStateTransitionInProgress
                        || model.isPerforming(.selectProxy(group.name))
                )
                .accessibilityLabel(
                    accessibilityLabel(proxy)
                )
            }
            .searchable(text: $searchText, prompt: "Search nodes")
        }
        .frame(minWidth: 340, idealWidth: 400, maxWidth: 480, minHeight: 360, idealHeight: 440)
    }

    private var filteredNodes: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return group.all }
        return group.all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay <= 0 { return .secondary }
        if delay < 150 { return .green }
        if delay < 350 { return .orange }
        return .red
    }

    private func nodeSymbol(_ proxy: String) -> String {
        if proxy == group.now { return "checkmark.circle.fill" }
        if model.proxiesByName[proxy]?.alive == false { return "exclamationmark.circle" }
        return "circle"
    }

    private func nodeColor(_ proxy: String) -> Color {
        if proxy == group.now { return .accentColor }
        if model.proxiesByName[proxy]?.alive == false { return .red }
        return .secondary
    }

    private func accessibilityLabel(_ proxy: String) -> String {
        var parts = [proxy]
        if proxy == group.now { parts.append("selected") }
        if model.proxiesByName[proxy]?.alive == false { parts.append("unavailable") }
        if let delay = model.proxyDelays[proxy] { parts.append("\(delay) milliseconds") }
        return parts.joined(separator: ", ")
    }
}
