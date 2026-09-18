import SwiftUI

/// Shows the members exposed by the running proxy group and applies a choice
/// directly to that group. The same surface is used for every group name,
/// including groups whose members happen to be regional.
struct RuntimeGroupMemberList: View {
    @Bindable var model: AppModel
    let group: ProxyGroup
    let runtime: MihomoProxy

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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], alignment: .leading, spacing: 8) {
                        ForEach(runtime.all, id: \.self) { member in
                            Button {
                                select(member)
                            } label: {
                                Label(
                                    member,
                                    systemImage: choice == member ? "checkmark.circle.fill" : "circle"
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .tint(choice == member ? Color.accentColor : Color.secondary)
                            .disabled(!canSelect || choice == member)
                            .accessibilityIdentifier("configuration.runtime-group-member-" + member)
                            .accessibilityValue(AppLocalization.string(choice == member ? "Selected" : "Not selected"))
                        }
                    }
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
}
