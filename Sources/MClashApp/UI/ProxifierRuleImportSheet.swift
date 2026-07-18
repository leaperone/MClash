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
                    Text("Import Proxifier Rules")
                        .font(.title3.weight(.semibold))
                    Text("\(plan.sourceName) · v\(plan.profileVersion) · \(plan.platform)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(selectedRules.count) selected")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
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
                                    Text("CATCH-ALL")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.red)
                                }
                                if item.rule?.enabled == false {
                                    Text("DISABLED")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text("\(item.criteriaSummary) · \(actionTitle(item))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        if !item.notes.isEmpty {
                            Image(systemName: item.isImportable
                                ? "exclamationmark.triangle.fill"
                                : "xmark.circle.fill")
                                .foregroundStyle(item.isImportable ? .orange : .secondary)
                                .help(item.notes.joined(separator: "\n"))
                                .accessibilityLabel(
                                    item.isImportable ? "Conversion warning" : "Rule cannot be imported"
                                )
                                .accessibilityValue(item.notes.joined(separator: ". "))
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!item.isImportable)
                .help(item.notes.joined(separator: "\n"))
                .accessibilityLabel(
                    "\(item.importedName), \(item.criteriaSummary), \(actionTitle(item))"
                )
                .accessibilityHint(
                    item.notes.isEmpty
                        ? "Select this rule for import."
                        : item.notes.joined(separator: ". ")
                )
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 12) {
                Label(
                    "Only rules are imported; proxy servers and credentials are ignored.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(plan.notes.joined(separator: "\n"))

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import \(selectedRules.count) Rules") {
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
        guard let action = item.rule?.action else { return "Skipped" }
        return switch action {
        case .direct: "Direct"
        case .reject: "Reject"
        case .mihomo: "Mihomo Rules"
        }
    }
}
