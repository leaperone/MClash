import AppKit
import MClashNetworkShared
import SwiftUI
import UniformTypeIdentifiers

struct CaptureRuleEditorSheet: View {
    @Binding private var isPresented: Bool
    @Binding private var draft: CaptureRuleDraft
    private let applicationCandidates: [ApplicationCaptureCandidate]
    private let processCandidates: [RunningProcessCaptureCandidate]
    private let mihomoGroupNames: [String]
    private let existingRuleIDs: Set<String>
    private let appliesImmediately: Bool
    private let onCommit: @MainActor (CaptureRule) -> Void

    @State private var submissionError: String?
    @State private var showingApplicationImporter = false
    @State private var showsAdvancedOptions: Bool

    init(
        isPresented: Binding<Bool>,
        draft: Binding<CaptureRuleDraft>,
        applicationCandidates: [ApplicationCaptureCandidate],
        processCandidates: [RunningProcessCaptureCandidate],
        mihomoGroupNames: [String] = [],
        existingRuleIDs: Set<String> = [],
        appliesImmediately: Bool = false,
        onCommit: @escaping @MainActor (CaptureRule) -> Void
    ) {
        _isPresented = isPresented
        _draft = draft
        self.applicationCandidates = applicationCandidates
        self.processCandidates = processCandidates
        self.mihomoGroupNames = mihomoGroupNames
        self.existingRuleIDs = existingRuleIDs
        self.appliesImmediately = appliesImmediately
        self.onCommit = onCommit
        _showsAdvancedOptions = State(initialValue: Self.usesAdvancedOptions(draft.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("App Routing Rule")
                    .font(.title2.weight(.semibold))
                Text("Choose an application and what MClash should do with its traffic. Add target restrictions only when you need them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                ruleSection
                applicationSection
                actionSection
                advancedSection
                previewSection
            }
            .formStyle(.grouped)

            if let visibleError {
                Label(visibleError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("capture-rule-validation-error")
            }

            if appliesImmediately {
                Label(
                    "Saving updates the active App Routing configuration and restarts Mihomo. Current connections can close.",
                    systemImage: "arrow.clockwise.circle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
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
                .disabled(!draft.canSubmit || existingRuleIDs.contains(normalizedRuleName))
            }
        }
        .padding(24)
        .frame(minWidth: 610, idealWidth: 680, minHeight: 600, idealHeight: 700)
        .onChange(of: draft) { _, _ in
            submissionError = nil
        }
        .fileImporter(
            isPresented: $showingApplicationImporter,
            allowedContentTypes: [.applicationBundle],
            allowsMultipleSelection: false,
            onCompletion: importApplication
        )
    }

    private var ruleSection: some View {
        Section("Rule") {
            TextField("Name", text: $draft.identifier)
                .textFieldStyle(.roundedBorder)

            Toggle("Enabled", isOn: $draft.enabled)
        }
    }

    private var applicationSection: some View {
        Section("Application") {
            Picker("Running application", selection: selectedApplicationID) {
                Text("Choose an application").tag(nil as String?)
                ForEach(displayedApplicationCandidates) { candidate in
                    Label {
                        Text(applicationLabel(candidate))
                    } icon: {
                        Image(nsImage: applicationIcon(candidate))
                    }
                    .tag(candidate.id as String?)
                }
            }

            Button {
                showingApplicationImporter = true
            } label: {
                Label("Choose Other Application…", systemImage: "folder")
            }

            if let application = draft.selectedApplication {
                selectedApplicationSummary(application)
            } else {
                Text("Select a running application or choose any signed .app from your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionSection: some View {
        Section("Action") {
            Picker("Route traffic", selection: $draft.action) {
                ForEach(CaptureRuleDraftAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }

            if draft.action == .mihomoGroup {
                if availableMihomoGroups.isEmpty {
                    TextField("Policy group", text: $draft.mihomoGroup)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker("Policy group", selection: $draft.mihomoGroup) {
                        Text("Choose a group").tag("")
                        ForEach(availableMihomoGroups, id: \.self) { group in
                            Text(group).tag(group)
                        }
                    }
                }
            }

            Text(actionHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced Matching", isExpanded: $showsAdvancedOptions) {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Exact running process", selection: selectedProcessID) {
                        Text("Any process in the application").tag(nil as String?)
                        ForEach(displayedProcessCandidates) { candidate in
                            Text(candidate.displayName).tag(candidate.id as String?)
                        }
                    }

                    if let process = draft.selectedProcess {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Only this running instance", systemImage: "clock.badge.exclamationmark")
                            Text("PID \(process.processIdentifier) · \(process.executablePath)")
                                .textSelection(.enabled)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    TextField(
                        "Application name or bundle ID pattern (optional)",
                        text: $draft.applicationIdentifierPattern
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())

                    Text("Use * for any number of characters and ? for one character, for example com.google.*. Choosing an exact signed .app is safer when possible.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Executable path (optional)", text: $draft.executablePath)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .textContentType(.none)

                    TextField("User ID (optional)", text: $draft.userID)
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()

                    Divider()

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
                                Text("Domain and subdomains (*.example.com)")
                                    .tag(HostMatcher.Kind.suffix)
                            }
                        }
                    }

                    Divider()

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

                    Picker("If Mihomo is unavailable", selection: $draft.unavailableFallback) {
                        Text("Connect directly").tag(UnavailableFallback.direct)
                        Text("Reject the connection").tag(UnavailableFallback.reject)
                    }
                }
                .padding(.top, 8)
            }

            Text("Use advanced matching for an exact process, executable, user, domain wildcard, IP/CIDR, protocol, or port range.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var previewSection: some View {
        Section("Rule Preview") {
            Label(rulePreview, systemImage: "arrow.triangle.branch")
                .font(.callout)
        }
    }

    @ViewBuilder
    private func selectedApplicationSummary(_ application: ApplicationCaptureCandidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: applicationIcon(application))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(application.displayName)
                    .font(.body.weight(.medium))
                if let bundleIdentifier = application.bundleIdentifier {
                    Text(bundleIdentifier)
                }
                Text(application.executablePath)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()

            if !application.runningProcessIdentifiers.isEmpty {
                Text("Running")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.green.opacity(0.12), in: Capsule())
            }
        }
    }

    private var selectedApplicationID: Binding<String?> {
        Binding(
            get: { draft.selectedApplicationID },
            set: { id in
                draft.selectApplication(id: id, from: displayedApplicationCandidates)
                if let application = draft.selectedApplication {
                    suggestRuleName(for: application)
                }
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

    private var normalizedRuleName: String {
        draft.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleError: String? {
        if existingRuleIDs.contains(normalizedRuleName) {
            return "A rule named \(normalizedRuleName) already exists."
        }
        return submissionError ?? draft.validationMessage
    }

    private var actionHelp: String {
        switch draft.action {
        case .mihomoProfileRules:
            "Send matching traffic to Mihomo and apply the active profile's routing rules."
        case .mihomoGlobal:
            "Send matching traffic directly to Mihomo's GLOBAL routing target through a dedicated private listener."
        case .mihomoGroup:
            "Send matching traffic directly to the selected Mihomo policy group through its own private listener."
        case .direct:
            "Connect matching traffic directly without using a proxy."
        case .reject:
            "Block matching connections."
        }
    }

    private var availableMihomoGroups: [String] {
        var groups = mihomoGroupNames
        let selected = draft.mihomoGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty, !groups.contains(selected) {
            groups.append(selected)
        }
        return Array(Set(groups.filter { !$0.isEmpty })).sorted()
    }

    private var rulePreview: String {
        let source: String
        if let process = draft.selectedProcess {
            source = "\(process.displayName) (this run only)"
        } else if let application = draft.selectedApplication {
            source = application.displayName
        } else if !draft.applicationIdentifierPattern
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = draft.applicationIdentifierPattern
        } else if !draft.executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = URL(fileURLWithPath: draft.executablePath).lastPathComponent
        } else {
            source = "Matching traffic"
        }

        let target: String
        switch draft.destinationKind {
        case .any:
            target = "any target"
        case .domain:
            let value = draft.destinationValue.trimmingCharacters(in: .whitespacesAndNewlines)
            target = draft.domainKind == .suffix && !value.hasPrefix("*.")
                ? "*.\(value)"
                : value
        case .ipAddress, .network:
            target = draft.destinationValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let port = draft.portRange.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetWithPort = port.isEmpty ? target : "\(target):\(port)"
        let action = draft.action == .mihomoGroup
            && !draft.mihomoGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Mihomo · \(draft.mihomoGroup.trimmingCharacters(in: .whitespacesAndNewlines))"
            : draft.action.title
        return "\(source) → \(targetWithPort) → \(action)"
    }

    private var destinationPlaceholder: String {
        switch draft.destinationKind {
        case .any: ""
        case .ipAddress: "IP address, for example 203.0.113.8"
        case .network: "CIDR network, for example 203.0.113.0/24"
        case .domain: "Domain or wildcard, for example *.example.com"
        }
    }

    private func applicationLabel(_ candidate: ApplicationCaptureCandidate) -> String {
        guard !candidate.runningProcessIdentifiers.isEmpty else {
            return candidate.displayName
        }
        let processes = candidate.runningProcessIdentifiers.count
        return "\(candidate.displayName) · \(processes) running"
    }

    private func applicationIcon(_ candidate: ApplicationCaptureCandidate) -> NSImage {
        NSWorkspace.shared.icon(forFile: candidate.id)
    }

    private func importApplication(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let candidate = try ApplicationCaptureCandidateProvider().candidate(bundleURL: url)
            draft.selectedApplication = candidate
            draft.selectedProcess = nil
            submissionError = nil
            suggestRuleName(for: candidate)
        } catch {
            submissionError = error.localizedDescription
        }
    }

    private func suggestRuleName(for application: ApplicationCaptureCandidate) {
        guard normalizedRuleName.hasPrefix("New Rule")
                || normalizedRuleName.hasPrefix("capture-") else {
            return
        }
        let base = application.displayName
        if !existingRuleIDs.contains(base) {
            draft.identifier = base
            return
        }
        var suffix = 2
        while existingRuleIDs.contains("\(base) \(suffix)") {
            suffix += 1
        }
        draft.identifier = "\(base) \(suffix)"
    }

    private func commit() {
        do {
            guard !existingRuleIDs.contains(normalizedRuleName) else {
                throw CaptureRuleDraftError.invalidIdentifier
            }
            let rule = try draft.makeRule()
            onCommit(rule)
            isPresented = false
        } catch {
            submissionError = error.localizedDescription
        }
    }

    private static func usesAdvancedOptions(_ draft: CaptureRuleDraft) -> Bool {
        draft.selectedProcess != nil
            || !draft.applicationIdentifierPattern
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.destinationKind != .any
            || !draft.matchesTCP
            || !draft.matchesUDP
            || !draft.portRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.unavailableFallback != .direct
    }
}
