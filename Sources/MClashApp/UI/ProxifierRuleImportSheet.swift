import MClashNetworkShared
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Must match the imported type declaration in Support/Info.plist.
    static let proxifierProfile = UTType(
        importedAs: "one.leaper.mclash.proxifier-profile",
        conformingTo: .xml
    )
}

struct ProxifierRuleImportSheet: View {
    @Environment(\.dismiss) private var dismiss

    let plan: ProxifierRuleImportPlan
    let onImport: ([CaptureRule]) -> Void

    @State private var selectedRuleIDs: Set<Int>

    init(
        plan: ProxifierRuleImportPlan,
        onImport: @escaping ([CaptureRule]) -> Void
    ) {
        self.plan = plan
        self.onImport = onImport
        _selectedRuleIDs = State(initialValue: Set(
            plan.items.filter(\.selectedByDefault).map(\.id)
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalization.string("Import Proxifier Rules"))
                        .font(.title3.weight(.semibold))
                    Text(
                        AppLocalization.format(
                            "%@ · v%@ · %@",
                            plan.sourceName,
                            plan.profileVersion,
                            plan.platform
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(AppLocalization.format("%d selected", selectedRules.count))
                        .font(.callout.monospacedDigit())
                    Text(importSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            List(plan.items) { item in
                Toggle(isOn: selectionBinding(for: item)) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.importedName)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                if item.isCatchAll {
                                    Text(AppLocalization.string("CATCH-ALL"))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.red)
                                }
                                if item.rule?.enabled == false {
                                    Text(AppLocalization.string("DISABLED"))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(
                                AppLocalization.format(
                                    "%@ · %@",
                                    item.criteriaSummary,
                                    actionTitle(item)
                                )
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if !item.notes.isEmpty {
                                Label(
                                    item.notes.joined(separator: " · "),
                                    systemImage: item.isImportable
                                        ? "exclamationmark.triangle.fill"
                                        : "xmark.circle.fill"
                                )
                                .font(.caption2)
                                .foregroundStyle(item.isImportable ? .orange : .secondary)
                                .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 12)
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!item.isImportable)
                .help(item.notes.joined(separator: "\n"))
                .accessibilityLabel(
                    AppLocalization.format(
                        "%@, %@, %@",
                        item.importedName,
                        item.criteriaSummary,
                        actionTitle(item)
                    )
                )
                .accessibilityHint(
                    item.notes.isEmpty
                        ? AppLocalization.string("Select this rule for import.")
                        : item.notes.joined(separator: ". ")
                )
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 12) {
                Label(
                    AppLocalization.string(
                        "Only rules are imported; proxy servers and credentials are ignored."
                    ),
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(plan.notes.joined(separator: "\n"))

                Spacer()

                Button(AppLocalization.string("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppLocalization.string("Import Rules")) {
                    onImport(selectedRules)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRules.isEmpty)
            }
            .padding(16)
        }
        .frame(
            minWidth: 620,
            idealWidth: 720,
            maxWidth: 760,
            minHeight: 440,
            idealHeight: 520,
            maxHeight: 560
        )
    }

    private var selectedRules: [CaptureRule] {
        plan.items.compactMap { item in
            guard selectedRuleIDs.contains(item.id) else { return nil }
            return item.rule
        }
    }

    private var importSummary: String {
        let ready = plan.items.filter { $0.isImportable && $0.notes.isEmpty }.count
        let warnings = plan.items.filter { $0.isImportable && !$0.notes.isEmpty }.count
        let skipped = plan.items.count - ready - warnings
        return AppLocalization.format(
            "Ready %d · Warnings %d · Skipped %d",
            ready,
            warnings,
            skipped
        )
    }

    private func selectionBinding(for item: ProxifierRuleImportItem) -> Binding<Bool> {
        Binding(
            get: { selectedRuleIDs.contains(item.id) },
            set: { selected in
                guard item.isImportable else { return }
                if selected {
                    selectedRuleIDs.insert(item.id)
                } else {
                    selectedRuleIDs.remove(item.id)
                }
            }
        )
    }

    private func actionTitle(_ item: ProxifierRuleImportItem) -> String {
        guard let action = item.rule?.action else {
            return AppLocalization.string("Skipped")
        }
        return switch action {
        case .direct: AppLocalization.string("Direct")
        case .reject: AppLocalization.string("Reject")
        case .mihomo: AppLocalization.string("Mihomo Rules")
        }
    }
}
