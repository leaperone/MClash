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
                Text("Choose an application, destinations, or both, then decide how matching traffic should be routed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                ruleSection
                applicationSection
                destinationSection
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
        .frame(minWidth: 640, idealWidth: 700, minHeight: 640, idealHeight: 760)
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
        Section("Application (Optional)") {
            Picker("Application", selection: selectedApplicationID) {
                Text("All applications").tag(nil as String?)
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
                Text("This rule applies to every application except MClash's built-in safety bypasses. Select an app only when the rule should be app-specific.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var destinationSection: some View {
        Section("Destinations (Optional)") {
            Text("A flow may match any destination below. If an application is selected, both the application and one of these destinations must match.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label("Domains", systemImage: "globe")
                    .font(.body.weight(.medium))

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField(
                        "openai.com, *.oaistatic.com",
                        text: $draft.domainInput,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 3)
                    .onSubmit(addDomains)

                    Button("Add", action: addDomains)
                        .disabled(draft.domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("Bare domains include their subdomains. Prefix = for an exact hostname. Paste several values separated by commas, spaces, or new lines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(draft.domainDestinations, id: \.self) { destination in
                    destinationRow(destination)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("IP Addresses & Networks", systemImage: "network")
                    .font(.body.weight(.medium))

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField(
                        "1.1.1.1, 104.18.0.0/16",
                        text: $draft.networkInput,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .lineLimit(1 ... 3)
                    .onSubmit(addNetworks)

                    Button("Add", action: addNetworks)
                        .disabled(draft.networkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("Accepts IPv4, IPv6, and CIDR networks. Domain matching uses the hostname macOS provides; if an app connects directly by IP, add that IP or CIDR here too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(draft.networkDestinations, id: \.self) { destination in
                    destinationRow(destination)
                }
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

            Text("Use advanced matching for one running process, an app identifier pattern, executable path, user, protocol, port range, or fallback behavior.")
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

    private func destinationRow(_ destination: DestinationMatcher) -> some View {
        HStack(spacing: 8) {
            Text(CaptureRuleDraft.destinationLabel(destination))
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Spacer()
            Button {
                draft.removeDestination(destination)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove destination")
            .accessibilityLabel("Remove \(CaptureRuleDraft.destinationLabel(destination))")
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
            source = "All applications"
        }

        let destinations = draft.destinationPreviewLabels
        let target: String
        if destinations.isEmpty {
            target = "any destination"
        } else if destinations.count <= 3 {
            target = destinations.joined(separator: ", ")
        } else {
            target = destinations.prefix(3).joined(separator: ", ")
                + " +\(destinations.count - 3) more"
        }

        let port = draft.portRange.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetWithPort = port.isEmpty ? target : "\(target):\(port)"
        let action = draft.action == .mihomoGroup
            && !draft.mihomoGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Mihomo · \(draft.mihomoGroup.trimmingCharacters(in: .whitespacesAndNewlines))"
            : draft.action.title
        return "\(source) → \(targetWithPort) → \(action)"
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

    private func addDomains() {
        do {
            try draft.commitDomainInput()
            submissionError = nil
        } catch {
            submissionError = error.localizedDescription
        }
    }

    private func addNetworks() {
        do {
            try draft.commitNetworkInput()
            submissionError = nil
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
            || !draft.matchesTCP
            || !draft.matchesUDP
            || !draft.portRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.unavailableFallback != .direct
    }
}
