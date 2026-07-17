import MClashNetworkShared
import SwiftUI

struct NetworkCaptureSettingsSection: View {
    @Bindable var model: AppModel

    @State private var applicationCandidates: [ApplicationCaptureCandidate] = []
    @State private var processCandidates: [RunningProcessCaptureCandidate] = []
    @State private var draft = CaptureRuleDraft()
    @State private var editingRuleID: String?
    @State private var showingEditor = false
    @State private var editorError: String?

    var body: some View {
        Section("Per-App Network Capture") {
            Toggle("Route selected applications and destinations through Mihomo", isOn: enabled)
                .disabled(model.pendingNetworkCaptureEnabled != nil || !model.canPerform(.changeNetworkCapture))

            LabeledContent("Extension status", value: statusTitle)

            if rules.isEmpty {
                Text("No capture rules yet. Add an application, executable, IP/CIDR, domain, protocol, or port rule.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rules) { rule in
                    ruleRow(rule)
                }
            }

            HStack {
                Button("Add Rule…") {
                    refreshApplications()
                    editingRuleID = nil
                    draft = CaptureRuleDraft(priority: nextPriority)
                    showingEditor = true
                }
                .disabled(!model.canPerform(.changeNetworkCapture))

                Button("Refresh Applications") {
                    refreshApplications()
                }
            }

            if let editorError {
                Label(editorError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Text("MClash uses Apple's transparent Network Extension. Built-in loopback, link-local, multicast, and MClash-component bypasses cannot be overridden. macOS system proxy and per-app capture are mutually exclusive.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { refreshApplications() }
        .sheet(isPresented: $showingEditor) {
            CaptureRuleEditorSheet(
                isPresented: $showingEditor,
                draft: $draft,
                applicationCandidates: applicationCandidates,
                processCandidates: processCandidates
            ) { rule in
                save(rule)
            }
        }
    }

    private var rules: [CaptureRule] {
        model.networkCapturePreferences.snapshot.rules
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: {
                model.pendingNetworkCaptureEnabled
                    ?? model.networkCapturePreferences.enabled
            },
            set: { value in
                Task { await model.setNetworkCaptureEnabled(value) }
            }
        )
    }

    private var nextPriority: Int {
        (rules.map(\.priority).max() ?? 0) + 10
    }

    private var statusTitle: String {
        if let pending = model.pendingNetworkCaptureEnabled {
            return pending ? "Turning On" : "Turning Off"
        }
        return switch model.networkCaptureState {
        case .off: "Off"
        case .enabling: "Starting"
        case let .on(revision): "On · revision \(revision)"
        case .disabling: "Stopping"
        case .requiresReboot: "Restart Required"
        case .failed: "Needs Attention"
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: CaptureRule) -> some View {
        HStack(spacing: 10) {
            Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(rule.enabled ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.id)
                    .font(.body.weight(.medium))
                Text(ruleSummary(rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text("P\(rule.priority)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Edit") { edit(rule) }
            Button("Delete", role: .destructive) { remove(rule) }
        }
    }

    private func edit(_ rule: CaptureRule) {
        refreshApplications()
        do {
            draft = try CaptureRuleDraft(
                rule: rule,
                applicationCandidates: applicationCandidates,
                processCandidates: processCandidates
            )
            editingRuleID = rule.id
            editorError = nil
            showingEditor = true
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func save(_ rule: CaptureRule) {
        var updated = rules
        if let editingRuleID,
           let index = updated.firstIndex(where: { $0.id == editingRuleID }) {
            updated[index] = rule
        } else {
            updated.append(rule)
        }
        apply(updated)
    }

    private func remove(_ rule: CaptureRule) {
        apply(rules.filter { $0.id != rule.id })
    }

    private func apply(_ rules: [CaptureRule]) {
        editorError = nil
        Task {
            do {
                try await model.applyNetworkCaptureRules(
                    rules,
                    enabled: model.networkCapturePreferences.enabled
                )
            } catch {
                editorError = error.localizedDescription
            }
        }
    }

    private func refreshApplications() {
        let provider = ApplicationCaptureCandidateProvider()
        let applications = provider.runningApplications()
        applicationCandidates = applications
        processCandidates = provider.runningProcesses(from: applications)
    }

    private func ruleSummary(_ rule: CaptureRule) -> String {
        let source = rule.sources.isEmpty ? "any process" : "\(rule.sources.count) source matcher(s)"
        let destination = rule.destinations.isEmpty
            ? "any destination"
            : "\(rule.destinations.count) destination matcher(s)"
        let protocols = rule.protocols.isEmpty
            ? "TCP + UDP"
            : rule.protocols.map { $0.rawValue.uppercased() }.sorted().joined(separator: " + ")
        let action: String = switch rule.action {
        case .direct: "Direct"
        case .reject: "Reject"
        case .mihomo: "Mihomo"
        }
        return "\(source) · \(destination) · \(protocols) → \(action)"
    }
}
