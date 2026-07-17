import MClashNetworkShared
import SwiftUI

/// Standalone editor for a targeted host capture rule.
///
/// The owner supplies application candidates and owns both presentation and
/// draft state. A successfully validated `CaptureRule` is returned through
/// `onCommit`; the view has no dependency on `AppModel` or configuration
/// persistence.
struct CaptureRuleEditorSheet: View {
    @Binding private var isPresented: Bool
    @Binding private var draft: CaptureRuleDraft
    private let applicationCandidates: [ApplicationCaptureCandidate]
    private let processCandidates: [RunningProcessCaptureCandidate]
    private let onCommit: @MainActor (CaptureRule) -> Void

    @State private var submissionError: String?

    init(
        isPresented: Binding<Bool>,
        draft: Binding<CaptureRuleDraft>,
        applicationCandidates: [ApplicationCaptureCandidate],
        processCandidates: [RunningProcessCaptureCandidate],
        onCommit: @escaping @MainActor (CaptureRule) -> Void
    ) {
        _isPresented = isPresented
        _draft = draft
        self.applicationCandidates = applicationCandidates
        self.processCandidates = processCandidates
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Traffic Capture Rule")
                    .font(.title2.weight(.semibold))
                Text("Match a signed application, executable, user, destination, or a combination of them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                ruleSection
                sourceSection
                destinationSection
                transportSection
                actionSection
            }
            .formStyle(.grouped)

            if let visibleError {
                Label(visibleError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("capture-rule-validation-error")
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Save Rule") {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.canSubmit)
            }
        }
        .padding(24)
        .frame(minWidth: 600, idealWidth: 680, minHeight: 640, idealHeight: 720)
        .onChange(of: draft) { _, _ in
            submissionError = nil
        }
    }

    private var ruleSection: some View {
        Section("Rule") {
            TextField("Identifier", text: $draft.identifier)
                .textFieldStyle(.roundedBorder)

            LabeledContent("Priority") {
                HStack(spacing: 8) {
                    TextField("Priority", value: $draft.priority, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 96)
                    Stepper("Priority", value: $draft.priority)
                        .labelsHidden()
                }
            }
            Text("Lower priority numbers are evaluated first.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Rule enabled", isOn: $draft.enabled)
        }
    }

    private var sourceSection: some View {
        Section("Source") {
            Picker("Running application", selection: selectedApplicationID) {
                Text("Any application").tag(nil as String?)
                ForEach(displayedApplicationCandidates) { candidate in
                    Text(applicationLabel(candidate)).tag(candidate.id as String?)
                }
            }


            Picker("Running process", selection: selectedProcessID) {
                Text("Any process instance").tag(nil as String?)
                ForEach(displayedProcessCandidates) { candidate in
                    Text(candidate.displayName).tag(candidate.id as String?)
                }
            }

            if let process = draft.selectedProcess {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PID \(process.processIdentifier)")
                    Text(process.executablePath)
                        .textSelection(.enabled)
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

                Text("This process-instance rule expires when that exact PID/start-time execution exits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let application = draft.selectedApplication {
                VStack(alignment: .leading, spacing: 3) {
                    if let bundleIdentifier = application.bundleIdentifier {
                        Text(bundleIdentifier)
                    }
                    if !application.executablePath.isEmpty {
                        Text(application.executablePath)
                            .textSelection(.enabled)
                    }
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

                if !application.executablePath.isEmpty,
                   draft.executablePath != application.executablePath {
                    Button("Also match this executable path") {
                        draft.useSelectedApplicationExecutable()
                    }
                }
            }

            TextField("Executable path (optional)", text: $draft.executablePath)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .textContentType(.none)
            Text("An executable-path matcher is an alternative source. When it matches the selected app, its signing requirement is retained.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("User ID (optional)", text: $draft.userID)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
        }
    }

    private var destinationSection: some View {
        Section("Destination") {
            Picker("Target", selection: $draft.destinationKind) {
                ForEach(CaptureRuleDestinationKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }

            if draft.destinationKind != .any {
                TextField(destinationPlaceholder, text: $draft.destinationValue)
                    .textFieldStyle(.roundedBorder)
                    .font(draft.destinationKind == .domain ? .body : .body.monospaced())

                if draft.destinationKind == .domain {
                    Picker("Domain match", selection: $draft.domainKind) {
                        Text("Exact domain").tag(HostMatcher.Kind.exact)
                        Text("Domain and subdomains").tag(HostMatcher.Kind.suffix)
                    }
                }
            }
        }
    }

    private var transportSection: some View {
        Section("Protocol & Port") {
            LabeledContent("Transport") {
                HStack(spacing: 18) {
                    Toggle("TCP", isOn: $draft.matchesTCP)
                        .toggleStyle(.checkbox)
                    Toggle("UDP", isOn: $draft.matchesUDP)
                        .toggleStyle(.checkbox)
                }
            }

            TextField("Port or range (optional)", text: $draft.portRange)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
            Text("Leave blank for every port, enter one port such as 443, or a range such as 8000-9000.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actionSection: some View {
        Section("Action") {
            Picker("Route", selection: $draft.action) {
                ForEach(CaptureRuleDraftAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }

            Picker("If the selected route is unavailable", selection: $draft.unavailableFallback) {
                Text("Connect directly").tag(UnavailableFallback.direct)
                Text("Reject the connection").tag(UnavailableFallback.reject)
            }
            Text("Fallback is applied when the selected Mihomo route cannot accept the flow.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedApplicationID: Binding<String?> {
        Binding(
            get: { draft.selectedApplicationID },
            set: { id in
                draft.selectApplication(id: id, from: displayedApplicationCandidates)
            }
        )
    }

    private var selectedProcessID: Binding<String?> {
        Binding(
            get: { draft.selectedProcessID },
            set: { id in
                draft.selectProcess(id: id, from: displayedProcessCandidates)
            }
        )
    }

    private var displayedApplicationCandidates: [ApplicationCaptureCandidate] {
        guard let selected = draft.selectedApplication,
              !applicationCandidates.contains(where: { $0.id == selected.id }) else {
            return applicationCandidates
        }
        return [selected] + applicationCandidates
    }

    private var displayedProcessCandidates: [RunningProcessCaptureCandidate] {
        guard let selected = draft.selectedProcess,
              !processCandidates.contains(where: { $0.id == selected.id }) else {
            return processCandidates
        }
        return [selected] + processCandidates
    }

    private func applicationLabel(_ candidate: ApplicationCaptureCandidate) -> String {
        guard !candidate.runningProcessIdentifiers.isEmpty else {
            return candidate.displayName
        }
        let processes = candidate.runningProcessIdentifiers.count
        return "\(candidate.displayName) · \(processes) running \(processes == 1 ? "process" : "processes")"
    }

    private var destinationPlaceholder: String {
        switch draft.destinationKind {
        case .any: ""
        case .ipAddress: "IP address, for example 203.0.113.8"
        case .network: "CIDR network, for example 203.0.113.0/24"
        case .domain: "Domain, for example example.com"
        }
    }

    private var visibleError: String? {
        submissionError ?? draft.validationMessage
    }

    private func commit() {
        do {
            let rule = try draft.makeRule()
            onCommit(rule)
            isPresented = false
        } catch {
            submissionError = error.localizedDescription
        }
    }
}
