import SwiftUI

struct ConfigurationRuleTrafficStrategyPicker: View {
    @Bindable var model: AppModel
    @State private var inspectedGroupID: ProxyGroupID?

    private var strategy: ConfigurationTrafficStrategy {
        ConfigurationTrafficStrategy(document: model.configurationDocument)
    }

    private var routeGroup: ProxyGroup? {
        strategy.groups.first { $0.id == inspectedGroupID } ?? strategy.groups.first
    }

    var body: some View {
        GroupBox {
            if strategy.mode == .direct {
                Label(AppLocalization.string("Direct routing is active"), systemImage: "arrow.right")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("configuration.rule-route-direct")
            } else if let group = routeGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Label(AppLocalization.string("Proxy selection"), systemImage: "globe")
                        .font(.headline)
                    if strategy.groups.count > 1 {
                        Picker(AppLocalization.string("Node Group"), selection: Binding(
                            get: { group.id }, set: { inspectedGroupID = $0 }
                        )) {
                            ForEach(strategy.groups) { candidate in
                                Text(configurationDisplayName(candidate.name)).tag(candidate.id)
                            }
                        }
                    }
                    if model.isConnected, model.controllerIsReady,
                       let runtime = model.proxiesByName[group.name] {
                        liveSelection(group: group, runtime: runtime)
                    } else {
                        Text(AppLocalization.format("Connect to choose nodes in %@. Your last choice will be restored.", group.name))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(AppLocalization.string("No selectable groups"))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: model.configurationRevision) {
            await model.refreshRoutingForAutomation()
        }
    }

    @ViewBuilder
    private func liveSelection(group: ProxyGroup, runtime: MihomoProxy) -> some View {
        let busy = model.isPerforming(.selectProxy(group.name)) || model.isPerforming(.clearProxyOverride(group.name))
        let path = model.proxySelectionPaths[group.name]?.route ?? [group.name]

        HStack {
            Text(path.map(configurationDisplayName).joined(separator: " → "))
                .font(.callout.weight(.medium))
                .textSelection(.enabled)
                .accessibilityIdentifier("configuration.rule-route-current")
            Spacer(minLength: 0)
            if busy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(AppLocalization.string("Applying routing change…"))
            }
        }
        if runtime.groupBehavior?.supportsSelectionUpdate == true, !runtime.all.isEmpty {
            RuntimeGroupMemberList(model: model, group: group, runtime: runtime)
        }
        Text(AppLocalization.format("Applies to new connections routed through %@. Existing connections keep their route.", group.name))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

}
