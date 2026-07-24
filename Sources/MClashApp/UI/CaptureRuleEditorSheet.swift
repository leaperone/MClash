import AppKit
import MClashNetworkShared
import SwiftUI
import UniformTypeIdentifiers

struct CaptureRuleEditorSheet: View {
    @Binding private var isPresented: Bool
    @Binding private var draft: CaptureRuleDraft
    private let applicationCandidates: [ApplicationCaptureCandidate]
    private let processCandidates: [RunningProcessCaptureCandidate]
    private let routingProfiles: [ProfileMetadata]
    private let mihomoGroupNames: [String]
    private let existingRuleIDs: Set<String>
    private let appliesImmediately: Bool
    private let onCommit: @MainActor (CaptureRule) -> Void

    @State private var submissionError: String?
    @State private var showingApplicationImporter = false
    @State private var showsAdvancedOptions: Bool
    @State private var domainDestinationPage = 0
    @State private var networkDestinationPage = 0
    @State private var applicationToAddID: String?
    @State private var processToAddID: String?

    private static let destinationPageSize = 50

    init(
        isPresented: Binding<Bool>,
        draft: Binding<CaptureRuleDraft>,
        applicationCandidates: [ApplicationCaptureCandidate],
        processCandidates: [RunningProcessCaptureCandidate],
        routingProfiles: [ProfileMetadata] = [],
        mihomoGroupNames: [String] = [],
        existingRuleIDs: Set<String> = [],
        appliesImmediately: Bool = false,
        onCommit: @escaping @MainActor (CaptureRule) -> Void
    ) {
        _isPresented = isPresented
        _draft = draft
        self.applicationCandidates = applicationCandidates
        self.processCandidates = processCandidates
        self.routingProfiles = routingProfiles
        self.mihomoGroupNames = mihomoGroupNames
        self.existingRuleIDs = existingRuleIDs
        self.appliesImmediately = appliesImmediately
        self.onCommit = onCommit
        _showsAdvancedOptions = State(initialValue: Self.usesAdvancedOptions(draft.wrappedValue))
    }

    var body: some View {
        let currentValidationError = visibleError

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("App Routing Rule")
                    .font(.title2.weight(.semibold))
                Text("Add applications, processes, or destinations, then choose how matching traffic should be routed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            Form {
                ruleSection
                sourcesSection
                destinationSection
                actionSection
                advancedSection
                previewSection
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 10) {
                Group {
                    if let currentValidationError {
                        Label(currentValidationError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("capture-rule-validation-error")
                    } else if appliesImmediately {
                        Label(
                            "Existing connections stay online unless this rule needs a new Mihomo route listener.",
                            systemImage: "bolt.horizontal.circle"
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        Text("Changes are saved for the next App Routing activation.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(2)
                .help(currentValidationError ?? "")

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
                    .disabled(currentValidationError != nil)
            }
            .padding(.horizontal, 24)
            .frame(height: 58)
        }
        .frame(
            minWidth: 620,
            idealWidth: 760,
            maxWidth: 860,
            minHeight: 560,
            idealHeight: 680,
            maxHeight: 760
        )
        .onChange(of: draft) { _, _ in
            submissionError = nil
        }
        .onChange(of: draft.destinations.count) { _, _ in
            clampDestinationPages()
        }
        .fileImporter(
            isPresented: $showingApplicationImporter,
            allowedContentTypes: [.applicationBundle],
            allowsMultipleSelection: true,
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

    private var sourcesSection: some View {
        Section("Sources (Optional · Any May Match)") {
            Text("Add applications, running processes, or identifiers. Items in this section use OR matching; destinations below are combined with the source group using AND.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label("Application & Process Identifiers", systemImage: "textformat.abc")
                    .font(.body.weight(.medium))

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField(
                        "chatgpt; codex.app; codex; com.openai.codex",
                        text: $draft.applicationIdentifierInput,
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .lineLimit(1 ... 3)
                    .onSubmit(addApplicationIdentifiers)
                    .accessibilityLabel("Application and process identifiers")

                    Button("Add", action: addApplicationIdentifiers)
                        .disabled(draft.applicationIdentifierInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("Paste several executable names, signing IDs, bundle IDs, or wildcard patterns separated by semicolons, commas, or new lines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(draft.applicationIdentifierPatterns, id: \.self) { pattern in
                    HStack(spacing: 8) {
                        Text(pattern)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Spacer()
                        removeSourceButton(
                            label: "Remove identifier \(pattern)",
                            help: "Remove application or process identifier"
                        ) {
                            draft.removeApplicationIdentifier(pattern)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Choose Applications", systemImage: "app.badge")
                    .font(.body.weight(.medium))

                HStack(spacing: 8) {
                    Picker("Application to add", selection: $applicationToAddID) {
                        Text("Choose a running application").tag(nil as String?)
                        ForEach(availableApplicationCandidates) { candidate in
                            Label {
                                Text(applicationLabel(candidate))
                            } icon: {
                                Image(nsImage: applicationIcon(candidate))
                            }
                            .tag(candidate.id as String?)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Application to add")

                    Button("Add") { addSelectedApplication() }
                        .disabled(applicationToAddID == nil)

                    Button {
                        showingApplicationImporter = true
                    } label: {
                        Label("Choose App…", systemImage: "folder")
                    }
                }

                ForEach(draft.selectedApplications) { application in
                    selectedApplicationSummary(application)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Choose Running Processes", systemImage: "terminal")
                    .font(.body.weight(.medium))

                HStack(spacing: 8) {
                    Picker("Running process to add", selection: $processToAddID) {
                        Text("Choose a running process").tag(nil as String?)
                        ForEach(availableProcessCandidates) { candidate in
                            Text(candidate.displayName).tag(candidate.id as String?)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Running process to add")

                    Button("Add") { addSelectedProcess() }
                        .disabled(processToAddID == nil)
                }

                ForEach(draft.selectedProcesses) { process in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(process.displayName)
                                .font(.callout.weight(.medium))
                            Text("PID \(process.processIdentifier) · \(process.executablePath)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        removeSourceButton(
                            label: "Remove process \(process.displayName)",
                            help: "Remove running process"
                        ) {
                            draft.removeProcess(id: process.id)
                        }
                    }
                }
            }

            if draft.selectedApplications.isEmpty,
               draft.selectedProcesses.isEmpty,
               draft.applicationIdentifierPatterns.isEmpty,
               draft.applicationIdentifierInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No source restriction — this rule applies to all applications and processes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var destinationSection: some View {
        let snapshot = destinationDisplaySnapshot

        return Section("Destinations (Optional)") {
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

                ForEach(snapshot.domains, id: \.self) { destination in
                    destinationRow(destination)
                }
                destinationPageControls(
                    page: snapshot.domainPage,
                    totalCount: snapshot.domainCount,
                    label: "domains",
                    previous: {
                        domainDestinationPage = max(0, snapshot.domainPage - 1)
                    },
                    next: {
                        domainDestinationPage = snapshot.domainPage + 1
                    }
                )
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

                ForEach(snapshot.networks, id: \.self) { destination in
                    destinationRow(destination)
                }
                destinationPageControls(
                    page: snapshot.networkPage,
                    totalCount: snapshot.networkCount,
                    label: "addresses and networks",
                    previous: {
                        networkDestinationPage = max(0, snapshot.networkPage - 1)
                    },
                    next: {
                        networkDestinationPage = snapshot.networkPage + 1
                    }
                )
            }
        }
    }

    private var actionSection: some View {
        Section("Action") {
            Picker("Route traffic", selection: $draft.action) {
                ForEach(CaptureRuleDraftAction.allCases) { action in
                    Text(action.title)
                        .tag(action)
                        .disabled(
                            action == .mihomoGroup
                                && draft.routingProfileID != nil
                        )
                }
            }

            if routesThroughMihomo {
                Picker("Profile", selection: $draft.routingProfileID) {
                    Text("Current default profile").tag(nil as ProfileID?)
                    ForEach(routingProfiles) { profile in
                        Text(profile.name).tag(profile.id as ProfileID?)
                    }
                    if let selected = draft.routingProfileID,
                       !routingProfiles.contains(where: { $0.id == selected }) {
                        Text(
                            AppLocalization.format(
                                "Unavailable profile · %@",
                                selected.description
                            )
                        )
                            .tag(selected as ProfileID?)
                    }
                }

                Text("Each selected profile runs in its own Mihomo session with an independent Mixed port and private App Routing listener.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if draft.routingProfileID != nil {
                    Text("Policy-group routing is currently available only for the default profile. Other profiles support Profile Rules and GLOBAL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .onChange(of: draft.routingProfileID) { _, profileID in
            if profileID != nil, draft.action == .mihomoGroup {
                draft.action = .mihomoProfileRules
                draft.mihomoGroup = ""
            }
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced Matching", isExpanded: $showsAdvancedOptions) {
                VStack(alignment: .leading, spacing: 14) {
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

                    TextField("Ports or ranges (optional)", text: $draft.portRange)
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()

                    Text("Separate multiple ports or ranges with commas or semicolons, for example 80; 443; 8000-9000.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("If Mihomo is unavailable", selection: $draft.unavailableFallback) {
                        Text("Connect directly").tag(UnavailableFallback.direct)
                        Text("Reject the connection").tag(UnavailableFallback.reject)
                    }
                }
                .padding(.top, 8)
            }

            Text("Use advanced matching for an executable path, user, protocol, port range, or fallback behavior.")
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

            removeSourceButton(
                label: "Remove application \(application.displayName)",
                help: "Remove application"
            ) {
                draft.removeApplication(id: application.id)
            }
        }
    }

    private func removeSourceButton(
        label: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label)
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

    @ViewBuilder
    private func destinationPageControls(
        page: Int,
        totalCount: Int,
        label: String,
        previous: @escaping () -> Void,
        next: @escaping () -> Void
    ) -> some View {
        if totalCount > Self.destinationPageSize {
            let first = page * Self.destinationPageSize + 1
            let last = min(totalCount, first + Self.destinationPageSize - 1)
            let lastPage = max(0, (totalCount - 1) / Self.destinationPageSize)

            HStack(spacing: 8) {
                Text("Showing \(first)–\(last) of \(totalCount.formatted()) \(label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button(action: previous) {
                    Image(systemName: "chevron.left")
                }
                .disabled(page == 0)
                .help("Previous \(label)")
                .accessibilityLabel("Previous \(label)")

                Button(action: next) {
                    Image(systemName: "chevron.right")
                }
                .disabled(page >= lastPage)
                .help("Next \(label)")
                .accessibilityLabel("Next \(label)")
            }
            .buttonStyle(.borderless)
        }
    }

    private var destinationDisplaySnapshot: DestinationDisplaySnapshot {
        let domainCount = draft.destinations.count(where: isDomainDestination)
        let networkCount = draft.destinations.count - domainCount
        let domainPage = min(
            domainDestinationPage,
            max(0, (domainCount - 1) / Self.destinationPageSize)
        )
        let networkPage = min(
            networkDestinationPage,
            max(0, (networkCount - 1) / Self.destinationPageSize)
        )
        let domainRange = pageRange(domainPage, count: domainCount)
        let networkRange = pageRange(networkPage, count: networkCount)

        var domains: [DestinationMatcher] = []
        var networks: [DestinationMatcher] = []
        domains.reserveCapacity(min(Self.destinationPageSize, domainCount))
        networks.reserveCapacity(min(Self.destinationPageSize, networkCount))
        var domainIndex = 0
        var networkIndex = 0

        for destination in draft.destinations {
            if isDomainDestination(destination) {
                if domainRange.contains(domainIndex) { domains.append(destination) }
                domainIndex += 1
            } else {
                if networkRange.contains(networkIndex) { networks.append(destination) }
                networkIndex += 1
            }
        }

        return DestinationDisplaySnapshot(
            domains: domains,
            networks: networks,
            domainCount: domainCount,
            networkCount: networkCount,
            domainPage: domainPage,
            networkPage: networkPage
        )
    }

    private func pageRange(_ page: Int, count: Int) -> Range<Int> {
        let lowerBound = min(count, page * Self.destinationPageSize)
        return lowerBound ..< min(count, lowerBound + Self.destinationPageSize)
    }

    private func isDomainDestination(_ destination: DestinationMatcher) -> Bool {
        switch destination {
        case .host, .hostPattern: true
        case .ip, .network: false
        }
    }

    private func clampDestinationPages() {
        let domainCount = draft.destinations.count(where: isDomainDestination)
        let networkCount = draft.destinations.count - domainCount
        domainDestinationPage = min(
            domainDestinationPage,
            max(0, (domainCount - 1) / Self.destinationPageSize)
        )
        networkDestinationPage = min(
            networkDestinationPage,
            max(0, (networkCount - 1) / Self.destinationPageSize)
        )
    }

    private var availableApplicationCandidates: [ApplicationCaptureCandidate] {
        let selectedIDs = Set(draft.selectedApplications.map(\.id))
        return applicationCandidates.filter { !selectedIDs.contains($0.id) }
    }

    private var availableProcessCandidates: [RunningProcessCaptureCandidate] {
        let selectedIDs = Set(draft.selectedProcesses.map(\.id))
        return processCandidates.filter { !selectedIDs.contains($0.id) }
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
        let profileName = routingProfiles.first(where: {
            $0.id == draft.routingProfileID
        })?.name ?? "the current default profile"
        return switch draft.action {
        case .mihomoProfileRules:
            "Send matching traffic to \(profileName) and apply that profile's routing rules."
        case .mihomoGlobal:
            "Send matching traffic to \(profileName)'s GLOBAL target through a dedicated private listener."
        case .mihomoGroup:
            "Send matching traffic to the selected policy group in \(profileName) through its own private listener."
        case .direct:
            "Connect matching traffic directly without using a proxy."
        case .reject:
            "Block matching connections."
        }
    }

    private var routesThroughMihomo: Bool {
        switch draft.action {
        case .mihomoProfileRules, .mihomoGlobal, .mihomoGroup:
            true
        case .direct, .reject:
            false
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
        var sourceNames = draft.selectedApplications.map(\.displayName)
            + draft.selectedProcesses.map { "\($0.displayName) (this run)" }
            + draft.applicationIdentifierPatterns
        let executableName = draft.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !executableName.isEmpty {
            sourceNames.append(URL(fileURLWithPath: executableName).lastPathComponent)
        }
        let hasPendingSource = !draft.applicationIdentifierInput
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if sourceNames.isEmpty, !hasPendingSource {
            source = "All applications"
        } else {
            var parts = Array(sourceNames.prefix(3))
            if sourceNames.count > parts.count {
                parts.append("+\(sourceNames.count - parts.count) more")
            }
            if hasPendingSource { parts.append("+ pending") }
            source = parts.joined(separator: ", ")
        }

        // Keep the preview proportional to what is visible. Imported profiles
        // can contain thousands of destinations; formatting every matcher on
        // each keystroke made the entire sheet stutter even though the preview
        // only displays the first three values.
        let destinationCount = draft.destinations.count
        let destinationLabels = draft.destinations.prefix(3).map(
            CaptureRuleDraft.destinationLabel
        )
        let hasPendingDestinations = !draft.domainInput
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.networkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let target: String
        if destinationCount == 0, !hasPendingDestinations {
            target = "any destination"
        } else {
            var parts: [String] = []
            if !destinationLabels.isEmpty {
                parts.append(destinationLabels.joined(separator: ", "))
            }
            if destinationCount > destinationLabels.count {
                parts.append("+\(destinationCount - destinationLabels.count) more")
            }
            if hasPendingDestinations {
                parts.append("+ pending entries")
            }
            target = parts.joined(separator: " ")
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
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            var failures: [String] = []
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                do {
                    let candidate = try ApplicationCaptureCandidateProvider().candidate(bundleURL: url)
                    draft.selectApplication(candidate)
                    suggestRuleName(for: candidate)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            submissionError = failures.isEmpty
                ? nil
                : "Some applications could not be added: \(failures.joined(separator: "; "))"
        } catch {
            submissionError = error.localizedDescription
        }
    }

    private func addSelectedApplication() {
        guard let id = applicationToAddID,
              let candidate = availableApplicationCandidates.first(where: { $0.id == id }) else {
            return
        }
        draft.selectApplication(candidate)
        applicationToAddID = nil
        suggestRuleName(for: candidate)
    }

    private func addSelectedProcess() {
        guard let id = processToAddID else { return }
        draft.selectProcess(id: id, from: availableProcessCandidates)
        processToAddID = nil
    }

    private func addApplicationIdentifiers() {
        do {
            try draft.commitApplicationIdentifierInput()
            submissionError = nil
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
        !draft.executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.matchesTCP
            || !draft.matchesUDP
            || !draft.portRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || draft.unavailableFallback != .direct
    }
}

private struct DestinationDisplaySnapshot {
    let domains: [DestinationMatcher]
    let networks: [DestinationMatcher]
    let domainCount: Int
    let networkCount: Int
    let domainPage: Int
    let networkPage: Int
}
