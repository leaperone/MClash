import SwiftUI

/// Shows the members exposed by the running proxy group and applies a choice
/// directly to that group. The same surface is used for every group name,
/// including groups whose members happen to be regional.
struct RuntimeGroupMemberList: View {
    @Bindable var model: AppModel
    let group: ProxyGroup
    let runtime: MihomoProxy
    @State private var searchText = ""

    private var choice: String? {
        runtime.fixedOverride ?? runtime.now
    }

    private var isBusy: Bool {
        model.isPerforming(.selectProxy(group.name))
            || model.isPerforming(.clearProxyOverride(group.name))
    }

    private var canSelect: Bool {
        model.canPerform(.selectProxy(group.name))
            && !isBusy
            && !model.configurationHasUnappliedChanges
    }

    private var filteredMembers: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return runtime.all }
        return runtime.all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label(AppLocalization.string("Members"), systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                    Spacer(minLength: 8)
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(AppLocalization.string("Updating…"))
                    }
                }

                if let choice {
                    Text(AppLocalization.format("Current choice: %@", choice))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if runtime.all.isEmpty {
                    Text(AppLocalization.string("Proxy group has no members."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    TextField(AppLocalization.string("Search nodes"), text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    List(filteredMembers, id: \.self) { member in
                        Button {
                            select(member)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: memberSymbol(member))
                                    .foregroundStyle(memberColor(member))
                                    .frame(width: 18)
                                Text(member)
                                    .lineLimit(1)
                                    .help(member)
                                Spacer(minLength: 8)
                                if let delay = model.proxyDelay(for: member, in: group.name) {
                                    Text(AppLocalization.format("%@ ms", formattedCount(delay)))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(delayColor(delay))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSelect || choice == member || runtime.groupBehavior?.supportsSelectionUpdate != true)
                        .accessibilityIdentifier("configuration.runtime-group-member-" + member)
                        .accessibilityLabel(memberAccessibilityLabel(member))
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 210, maxHeight: .infinity)
                }

                if runtime.fixedOverride != nil,
                   runtime.groupBehavior?.supportsClearingOverride == true {
                    Button(AppLocalization.string("Resume automatic selection")) {
                        Task { _ = await model.clearProxyOverride(group: group.name) }
                    }
                    .disabled(!canSelect)
                }
            }
        }
    }

    private func select(_ member: String) {
        guard member != choice else { return }
        Task { _ = await model.selectProxy(group: group.name, proxy: member) }
    }

    private func memberSymbol(_ member: String) -> String {
        if member == runtime.fixedOverride { return "pin.circle.fill" }
        if member == runtime.now { return "checkmark.circle.fill" }
        if model.proxyAlive(for: member, in: group.name) == false { return "exclamationmark.circle" }
        return "circle"
    }

    private func memberColor(_ member: String) -> Color {
        if member == runtime.fixedOverride { return .orange }
        if member == runtime.now { return .accentColor }
        if model.proxyAlive(for: member, in: group.name) == false { return .red }
        return .secondary
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay <= 0 { return .secondary }
        if delay < 150 { return .green }
        if delay < 350 { return .orange }
        return .red
    }

    private func memberAccessibilityLabel(_ member: String) -> String {
        var parts = [member]
        if member == runtime.fixedOverride { parts.append(AppLocalization.string("Pinned preference")) }
        if member == runtime.now { parts.append(AppLocalization.string("Selected")) }
        if model.proxyAlive(for: member, in: group.name) == false {
            parts.append(AppLocalization.string("Unavailable"))
        }
        return parts.joined(separator: ", ")
    }
}
