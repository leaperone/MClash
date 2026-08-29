import AppKit
import MClashNetworkShared
import SwiftUI
import UniformTypeIdentifiers

struct CaptureRuleEditorSheet: View {
    private enum FocusField: Hashable {
        case identifier
        case applicationIdentifier
        case domain
        case network
        case routingProfile
        case executablePath
        case userID
        case transport
        case portRange
        case policyGroup
    }

    @Bindable private var model: AppModel
    @Binding private var isPresented: Bool
    @Binding private var draft: CaptureRuleDraft
    private let applicationCandidates: [ApplicationCaptureCandidate]
    private let processCandidates: [RunningProcessCaptureCandidate]
    private let mihomoGroupNames: [String]
    private let existingRuleIDs: Set<String>
    private let appliesImmediately: Bool
    private let onCommit: @MainActor (CaptureRule) -> Void

    @State private var submissionError: String?
    @State private var attemptedSubmission = false
    @State private var showingApplicationImporter = false
    @State private var showsSourceOptions = false
    @State private var showsDestinationOptions = false
    @State private var showsAdvancedOptions: Bool
    @State private var domainDestinationPage = 0
    @State private var networkDestinationPage = 0
    @State private var applicationToAddID: String?
    @State private var processToAddID: String?
    @State private var showingProfileManager = false
    @FocusState private var focusedField: FocusField?

    private static let destinationPageSize = 50

    init(
        model: AppModel,
        isPresented: Binding<Bool>,
        draft: Binding<CaptureRuleDraft>,
        applicationCandidates: [ApplicationCaptureCandidate],
        processCandidates: [RunningProcessCaptureCandidate],
        mihomoGroupNames: [String] = [],
        existingRuleIDs: Set<String> = [],
        appliesImmediately: Bool = false,
        onCommit: @escaping @MainActor (CaptureRule) -> Void
    ) {
        self.model = model
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
        let currentValidationError = visibleError

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.string("App Routing Rule"))
                    .font(.title2.weight(.semibold))
                Text(
                    AppLocalization.string(
                        "Add applications, processes, or destinations, then choose how matching traffic should be routed."
                    )
                )
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
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(rulePreview, systemImage: "arrow.triangle.branch")
                        .font(.callout)
                        .lineLimit(2)

                    Group {
                        if let currentValidationError {
                            Label(currentValidationError, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("capture-rule-validation-error")
                        } else if appliesImmediately {
                            Text(
                                AppLocalization.string(
                                    "Existing connections stay online unless this rule needs a new route listener."
                                )
                            )
                                .foregroundStyle(.secondary)
                        } else {
                            Text(
                                AppLocalization.string(
                                    "Changes are saved for the next App Routing activation."
                                )
                            )
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .lineLimit(2)
                    .help(currentValidationError ?? "")
                }

                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button(AppLocalization.string("Save Rule")) {
                    commit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .frame(minHeight: 58)
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
        Section(AppLocalization.string("Rule")) {
            TextField(AppLocalization.string("Name"), text: $draft.identifier)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .identifier)

            Toggle(AppLocalization.string("Enabled"), isOn: $draft.enabled)
        }
    }

    private var sourcesSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsSourceOptions) {
                Text(
                    AppLocalization.string(
                        "Add applications, running processes, or identifiers. Items in this section use OR matching; destinations below are combined with the source group using AND."
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        AppLocalization.string("Application & Process Identifiers"),
                        systemImage: "textformat.abc"
                    )
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
                        .accessibilityLabel(
                            AppLocalization.string("Application and process identifiers")
                        )
                        .focused($focusedField, equals: .applicationIdentifier)

                        Button(AppLocalization.string("Add"), action: addApplicationIdentifiers)
                            .disabled(draft.applicationIdentifierInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Text(
                        AppLocalization.string(
                            "Paste several executable names, signing IDs, bundle IDs, or wildcard patterns separated by semicolons, commas, or new lines."
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(draft.applicationIdentifierPatterns, id: \.self) { pattern in
                        HStack(spacing: 8) {
                            Text(pattern)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            removeSourceButton(
                                label: AppLocalization.format("Remove identifier %@", pattern),
                                help: AppLocalization.string(
                                    "Remove application or process identifier"
                                )
                            ) {
                                draft.removeApplicationIdentifier(pattern)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        AppLocalization.string("Choose Applications"),
                        systemImage: "app.badge"
                    )
                        .font(.body.weight(.medium))

                    HStack(spacing: 8) {
                        Picker(
                            AppLocalization.string("Application to add"),
                            selection: $applicationToAddID
                        ) {
                            Text(AppLocalization.string("Choose a running application"))
                                .tag(nil as String?)
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
                        .accessibilityLabel(AppLocalization.string("Application to add"))

                        Button(AppLocalization.string("Add")) { addSelectedApplication() }
                            .disabled(applicationToAddID == nil)

                        Button {
                            showingApplicationImporter = true
                        } label: {
                            Label(AppLocalization.string("Choose App…"), systemImage: "folder")
                        }
                    }

                    ForEach(draft.selectedApplications) { application in
                        selectedApplicationSummary(application)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        AppLocalization.string("Choose Running Processes"),
                        systemImage: "terminal"
                    )
                        .font(.body.weight(.medium))

                    HStack(spacing: 8) {
                        Picker(
                            AppLocalization.string("Running process to add"),
                            selection: $processToAddID
                        ) {
                            Text(AppLocalization.string("Choose a running process"))
                                .tag(nil as String?)
                            ForEach(availableProcessCandidates) { candidate in
                                Text(candidate.displayName).tag(candidate.id as String?)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel(AppLocalization.string("Running process to add"))

                        Button(AppLocalization.string("Add")) { addSelectedProcess() }
                            .disabled(processToAddID == nil)
                    }

                    ForEach(draft.selectedProcesses) { process in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(process.displayName)
                                    .font(.callout.weight(.medium))
                                Text(
                                    AppLocalization.format(
                                        "PID %@ · %@",
                                        String(process.processIdentifier),
                                        process.executablePath
                                    )
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            removeSourceButton(
                                label: AppLocalization.format(
                                    "Remove process %@",
                                    process.displayName
                                ),
                                help: AppLocalization.string("Remove running process")
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
                    Text(
                        AppLocalization.string(
                            "No source restriction — this rule applies to all applications and processes."
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                LabeledContent(AppLocalization.string("Sources"), value: sourceSelectionSummary)
            }
        }
    }

    private var destinationSection: some View {
        let snapshot = destinationDisplaySnapshot

        return Section {
            DisclosureGroup(isExpanded: $showsDestinationOptions) {
                Text(
                    AppLocalization.string(
                        "A flow may match any destination below. If an application is selected, both the application and one of these destinations must match."
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Label(AppLocalization.string("Domains"), systemImage: "globe")
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
                        .focused($focusedField, equals: .domain)

                        Button(AppLocalization.string("Add"), action: addDomains)
                            .disabled(draft.domainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Text(
                        AppLocalization.string(
                            "Bare domains include their subdomains. Prefix = for an exact hostname. Paste several values separated by commas, spaces, or new lines."
                        )
                    )
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
                    Label(
                        AppLocalization.string("IP Addresses & Networks"),
                        systemImage: "network"
                    )
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
                        .focused($focusedField, equals: .network)

                        Button(AppLocalization.string("Add"), action: addNetworks)
                            .disabled(draft.networkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Text(
                        AppLocalization.string(
                            "Accepts IPv4, IPv6, and CIDR networks. Domain matching uses the hostname macOS provides; if an app connects directly by IP, add that IP or CIDR here too."
                        )
                    )
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
            } label: {
                LabeledContent(
                    AppLocalization.string("Destinations"),
                    value: destinationSelectionSummary
                )
            }
        }
    }

    private var actionSection: some View {
        Section(AppLocalization.string("Action")) {
            Picker(AppLocalization.string("Route traffic"), selection: $draft.action) {
                ForEach(CaptureRuleDraftAction.allCases) { action in
                    Text(AppLocalization.string(action.title))
                        .tag(action)
                        .disabled(
                            action == .mihomoGroup
                                && draft.routingProfileID != nil
                        )
                }
            }

            if routesThroughMihomo {
                LabeledContent(AppLocalization.string("Profile")) {
                    HStack(spacing: 8) {
                        Picker(AppLocalization.string("Profile"), selection: $draft.routingProfileID) {
                            Text(defaultProfilePickerTitle)
                                .tag(nil as ProfileID?)
                            ForEach(selectableRoutingProfiles) { profile in
                                Text(profilePickerTitle(profile))
                                    .tag(profile.id as ProfileID?)
                            }
                            if let selected = draft.routingProfileID,
                               !selectableRoutingProfiles.contains(where: {
                                   $0.id == selected
                               }) {
                                Text(unavailableProfilePickerTitle(selected))
                                    .tag(selected as ProfileID?)
                            }
                        }
                        .labelsHidden()
                        .focused($focusedField, equals: .routingProfile)

                        Button {
                            showingProfileManager.toggle()
                        } label: {
                            Label(
                                AppLocalization.string("Manage Profiles…"),
                                systemImage: "slider.horizontal.3"
                            )
                        }
                        .popover(isPresented: $showingProfileManager, arrowEdge: .trailing) {
                            AppRoutingProfileQuickManager(
                                model: model,
                                selectedProfileID: $draft.routingProfileID
                            )
                        }
                    }
                }

                Text(
                    AppLocalization.string(
                        "Default Profile is a stable virtual target. Real Profiles can be selected when their own Mixed port is open."
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if draft.routingProfileID != nil {
                    Text(
                        AppLocalization.string(
                            "Policy-group routing is currently available only for the default profile. Other profiles support Profile Rules and GLOBAL."
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if draft.action == .mihomoGroup {
                if availableMihomoGroups.isEmpty {
                    TextField(AppLocalization.string("Policy group"), text: $draft.mihomoGroup)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .policyGroup)
                } else {
                    Picker(AppLocalization.string("Policy group"), selection: $draft.mihomoGroup) {
                        Text(AppLocalization.string("Choose a group")).tag("")
                        ForEach(availableMihomoGroups, id: \.self) { group in
                            Text(group).tag(group)
                        }
                    }
                    .focused($focusedField, equals: .policyGroup)
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
            DisclosureGroup(
                AppLocalization.string("Advanced Matching"),
                isExpanded: $showsAdvancedOptions
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    TextField(
                        AppLocalization.string("Executable path (optional)"),
                        text: $draft.executablePath
                    )
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .textContentType(.none)
                        .focused($focusedField, equals: .executablePath)

                    TextField(
                        AppLocalization.string("User ID (optional)"),
                        text: $draft.userID
                    )
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                        .focused($focusedField, equals: .userID)

                    Divider()

                    LabeledContent(AppLocalization.string("Transport")) {
                        HStack(spacing: 18) {
                            Toggle(AppLocalization.string("TCP"), isOn: $draft.matchesTCP)
                                .toggleStyle(.checkbox)
                                .focused($focusedField, equals: .transport)
                            Toggle(AppLocalization.string("UDP"), isOn: $draft.matchesUDP)
                                .toggleStyle(.checkbox)
                        }
                    }

                    TextField(
                        AppLocalization.string("Ports or ranges (optional)"),
                        text: $draft.portRange
                    )
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                        .focused($focusedField, equals: .portRange)

                    Text(
                        AppLocalization.string(
                            "Separate multiple ports or ranges with commas or semicolons, for example 80; 443; 8000-9000."
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker(
                        AppLocalization.string("If Mihomo is unavailable"),
                        selection: $draft.unavailableFallback
                    ) {
                        Text(AppLocalization.string("Connect directly"))
                            .tag(UnavailableFallback.direct)
                        Text(AppLocalization.string("Reject the connection"))
                            .tag(UnavailableFallback.reject)
                    }
                }
                .padding(.top, 8)
            }

            Text(
                AppLocalization.string(
                    "Use advanced matching for an executable path, user, protocol, port range, or fallback behavior."
                )
            )
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Text(AppLocalization.string("Running"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.green.opacity(0.12), in: Capsule())
            }

            removeSourceButton(
                label: AppLocalization.format(
                    "Remove application %@",
                    application.displayName
                ),
                help: AppLocalization.string("Remove application")
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
            .help(AppLocalization.string("Remove destination"))
            .accessibilityLabel(
                AppLocalization.format(
                    "Remove %@",
                    CaptureRuleDraft.destinationLabel(destination)
                )
            )
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
            let localizedLabel = AppLocalization.string(label)

            HStack(spacing: 8) {
                Text(
                    AppLocalization.format(
                        "Showing %@–%@ of %@ %@",
                        String(first),
                        String(last),
                        totalCount.formatted(),
                        localizedLabel
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button(action: previous) {
                    Image(systemName: "chevron.left")
                }
                .disabled(page == 0)
                .help(AppLocalization.format("Previous %@", localizedLabel))
                .accessibilityLabel(AppLocalization.format("Previous %@", localizedLabel))

                Button(action: next) {
                    Image(systemName: "chevron.right")
                }
                .disabled(page >= lastPage)
                .help(AppLocalization.format("Next %@", localizedLabel))
                .accessibilityLabel(AppLocalization.format("Next %@", localizedLabel))
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

    private var sourceSelectionSummary: String {
        let count = draft.selectedApplications.count
            + draft.selectedProcesses.count
            + draft.applicationIdentifierPatterns.count
        return count == 0
            ? AppLocalization.string("All applications")
            : AppLocalization.format("%d selected", count)
    }

    private var destinationSelectionSummary: String {
        draft.destinations.isEmpty
            ? AppLocalization.string("Any destination")
            : AppLocalization.format("%d selected", draft.destinations.count)
    }

    private var visibleError: String? {
        if let submissionError { return submissionError }
        guard attemptedSubmission else { return nil }
        if existingRuleIDs.contains(normalizedRuleName) {
            return AppLocalization.format(
                "A rule named %@ already exists.",
                normalizedRuleName
            )
        }
        if routesThroughMihomo,
           let selected = draft.routingProfileID,
           !selectableRoutingProfiles.contains(where: { $0.id == selected }) {
            return AppLocalization.string(
                "Open this profile's Mixed port or choose another profile."
            )
        }
        return draft.validationMessage
    }

    private var actionHelp: String {
        let profileName = model.profiles.first(where: {
            $0.id == draft.routingProfileID
        })?.name ?? model.profiles.first(where: {
            $0.id == model.activeProfileID
        })?.name ?? AppLocalization.string("the current default profile")
        return switch draft.action {
        case .mihomoProfileRules:
            AppLocalization.format(
                "Send matching traffic to %@ and apply that profile's routing rules.",
                profileName
            )
        case .mihomoGlobal:
            AppLocalization.format(
                "Send matching traffic to %@'s GLOBAL target through a dedicated private listener.",
                profileName
            )
        case .mihomoGroup:
            AppLocalization.format(
                "Send matching traffic to the selected policy group in %@ through its own private listener.",
                profileName
            )
        case .direct:
            AppLocalization.string("Connect matching traffic directly without using a proxy.")
        case .reject:
            AppLocalization.string("Block matching connections.")
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

    private var selectableRoutingProfiles: [ProfileMetadata] {
        model.profiles.filter { profile in
            model.profileSessionSpec(for: profile.id)?.enabled == true
        }
    }

    private var defaultProfilePickerTitle: String {
        guard let profile = model.profiles.first(where: {
            $0.id == model.activeProfileID
        }) else {
            return AppLocalization.string("Default profile")
        }
        return AppLocalization.format("Default Profile — uses %@", profile.name)
    }

    private func profilePickerTitle(_ profile: ProfileMetadata) -> String {
        guard let port = model.profileSessionSpec(for: profile.id)?.mixedPort else {
            return profile.name
        }
        return AppLocalization.format("%@ — Mixed %@", profile.name, String(port))
    }

    private func unavailableProfilePickerTitle(_ profileID: ProfileID) -> String {
        let name = model.profiles.first(where: { $0.id == profileID })?.name
            ?? profileID.description
        return AppLocalization.format("%@ — Mixed port off", name)
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
            + draft.selectedProcesses.map {
                AppLocalization.format("%@ (this run)", $0.displayName)
            }
            + draft.applicationIdentifierPatterns
        let executableName = draft.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !executableName.isEmpty {
            sourceNames.append(URL(fileURLWithPath: executableName).lastPathComponent)
        }
        let hasPendingSource = !draft.applicationIdentifierInput
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if sourceNames.isEmpty, !hasPendingSource {
            source = AppLocalization.string("All applications")
        } else {
            var parts = Array(sourceNames.prefix(3))
            if sourceNames.count > parts.count {
                parts.append(
                    AppLocalization.format(
                        "+%d more",
                        sourceNames.count - parts.count
                    )
                )
            }
            if hasPendingSource { parts.append(AppLocalization.string("+ pending")) }
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
            target = AppLocalization.string("any destination")
        } else {
            var parts: [String] = []
            if !destinationLabels.isEmpty {
                parts.append(destinationLabels.joined(separator: ", "))
            }
            if destinationCount > destinationLabels.count {
                parts.append(
                    AppLocalization.format(
                        "+%d more",
                        destinationCount - destinationLabels.count
                    )
                )
            }
            if hasPendingDestinations {
                parts.append(AppLocalization.string("+ pending entries"))
            }
            target = parts.joined(separator: " ")
        }

        let port = draft.portRange.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetWithPort = port.isEmpty ? target : "\(target):\(port)"
        let action = draft.action == .mihomoGroup
            && !draft.mihomoGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppLocalization.format(
                "Mihomo · %@",
                draft.mihomoGroup.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            : AppLocalization.string(draft.action.title)
        return AppLocalization.format("%@ → %@ → %@", source, targetWithPort, action)
    }

    private func applicationLabel(_ candidate: ApplicationCaptureCandidate) -> String {
        guard !candidate.runningProcessIdentifiers.isEmpty else {
            return candidate.displayName
        }
        let processes = candidate.runningProcessIdentifiers.count
        return AppLocalization.format(
            "%@ · %d running",
            candidate.displayName,
            processes
        )
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
                : AppLocalization.format(
                    "Some applications could not be added: %@",
                    failures.joined(separator: "; ")
                )
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
        attemptedSubmission = true
        do {
            guard !existingRuleIDs.contains(normalizedRuleName) else {
                let message = AppLocalization.format(
                    "A rule named %@ already exists.",
                    normalizedRuleName
                )
                submissionError = message
                focusedField = .identifier
                announceValidationError(message)
                return
            }
            guard !routesThroughMihomo
                || draft.routingProfileID == nil
                || selectableRoutingProfiles.contains(where: { $0.id == draft.routingProfileID })
            else {
                let message = AppLocalization.string(
                    "Open this profile's Mixed port or choose another profile."
                )
                submissionError = message
                focusedField = .routingProfile
                announceValidationError(message)
                return
            }
            let rule = try draft.makeRule()
            onCommit(rule)
            isPresented = false
        } catch {
            submissionError = error.localizedDescription
            focus(for: error)
            announceValidationError(error.localizedDescription)
        }
    }

    private func announceValidationError(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func focus(for error: Error) {
        guard let draftError = error as? CaptureRuleDraftError else {
            focusedField = .identifier
            return
        }

        switch draftError {
        case .invalidIdentifier,
             .unsupportedExistingRule,
             .invalidCaptureRule:
            focusedField = .identifier
        case .invalidApplicationPattern:
            revealSourceOptionsAndFocus(.applicationIdentifier)
        case .invalidExecutablePath:
            revealAdvancedOptionsAndFocus(.executablePath)
        case .invalidUserID:
            revealAdvancedOptionsAndFocus(.userID)
        case .invalidIPAddress, .invalidNetwork:
            revealDestinationOptionsAndFocus(.network)
        case .invalidDomain:
            revealDestinationOptionsAndFocus(.domain)
        case .noTransportProtocol:
            revealAdvancedOptionsAndFocus(.transport)
        case .invalidPortRange:
            revealAdvancedOptionsAndFocus(.portRange)
        case .noMatchCriteria:
            revealSourceOptionsAndFocus(.applicationIdentifier)
        case .missingMihomoGroup:
            focusedField = .policyGroup
        }
    }

    private func revealAdvancedOptionsAndFocus(_ field: FocusField) {
        showsAdvancedOptions = true
        Task { @MainActor in
            await Task.yield()
            focusedField = field
        }
    }

    private func revealSourceOptionsAndFocus(_ field: FocusField) {
        showsSourceOptions = true
        Task { @MainActor in
            await Task.yield()
            focusedField = field
        }
    }

    private func revealDestinationOptionsAndFocus(_ field: FocusField) {
        showsDestinationOptions = true
        Task { @MainActor in
            await Task.yield()
            focusedField = field
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

private struct AppRoutingProfileQuickManager: View {
    @Bindable var model: AppModel
    @Binding var selectedProfileID: ProfileID?
    @State private var showingDefaultPortSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AppLocalization.string("Profiles"))
                    .font(.headline)
                Text(
                    AppLocalization.format(
                        "Default Profile is always available on Mixed %@. Open a real Profile's own port to target it explicitly.",
                        String(model.profileRuntimePlan.defaultMixedPort)
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppLocalization.string("Default Profile"))
                        .fontWeight(.medium)
                    Text(defaultSourceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(
                    AppLocalization.format(
                        "Mixed %@",
                        String(model.profileRuntimePlan.defaultMixedPort)
                    )
                )
                    .font(.caption.monospacedDigit())
                Button(AppLocalization.string("Edit…")) {
                    showingDefaultPortSettings = true
                }
                .controlSize(.small)
                .disabled(!model.canPerform(.changeRuntimeSettings))
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.profiles) { profile in
                        AppRoutingProfileQuickRow(
                            model: model,
                            profile: profile,
                            isSelected: selectedProfileID == profile.id
                        )
                        if profile.id != model.profiles.last?.id {
                            Divider()
                                .padding(.leading, 42)
                        }
                    }
                }
            }

            Divider()

            Text(
                AppLocalization.string(
                    "Changes apply immediately; this rule draft stays open."
                )
            )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
        .frame(minWidth: 360, idealWidth: 460, maxWidth: 640)
        .frame(
            minHeight: 250,
            idealHeight: min(520, CGFloat(model.profiles.count * 76 + 230)),
            maxHeight: 520
        )
        .sheet(isPresented: $showingDefaultPortSettings) {
            ListenerPortSettingsEditor(
                model: model,
                isPresented: $showingDefaultPortSettings
            )
        }
    }

    private var defaultSourceTitle: String {
        guard let activeProfileID = model.activeProfileID,
              let profile = model.profiles.first(where: { $0.id == activeProfileID })
        else { return AppLocalization.string("No backing Profile selected") }
        return AppLocalization.format("Uses %@", profile.name)
    }
}

private struct AppRoutingProfileQuickRow: View {
    @Bindable var model: AppModel
    let profile: ProfileMetadata
    let isSelected: Bool

    @State private var mixedPort: Int
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(model: AppModel, profile: ProfileMetadata, isSelected: Bool) {
        self.model = model
        self.profile = profile
        self.isSelected = isSelected
        _mixedPort = State(
            initialValue: model.profileSessionSpec(for: profile.id)?.mixedPort ?? 7_890
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Button {
                    makeDefault()
                } label: {
                    Image(systemName: isDefault ? "star.circle.fill" : "circle")
                        .foregroundStyle(isDefault ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(isDefault || isSaving || !model.canPerform(.activateProfile(profile.id)))
                .help(
                    isDefault
                        ? AppLocalization.string("Default profile")
                        : AppLocalization.format("Make %@ the default", profile.name)
                )
                .accessibilityLabel(
                    isDefault
                        ? AppLocalization.format("%@, default profile", profile.name)
                        : AppLocalization.format(
                            "Make %@ the default profile",
                            profile.name
                        )
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if isSelected {
                            Text(AppLocalization.string("Selected"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(
                        isDefault
                            ? AppLocalization.format(
                                "Backs Default Profile · %@",
                                runtimeStatusTitle
                            )
                            : runtimeStatusTitle
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Toggle(AppLocalization.string("Mixed port"), isOn: runtimeEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(isSaving || !model.canPerform(.updateProfile(profile.id)))
                    .help(
                        isRuntimeEnabled
                            ? AppLocalization.string("Close this Profile's Mixed port")
                            : AppLocalization.string("Open this Profile's Mixed port")
                    )

                TextField(
                    AppLocalization.string("Port"),
                    value: $mixedPort,
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 74)
                .disabled(!isRuntimeEnabled || isSaving)
                .onSubmit { savePort() }

                Button {
                    savePort()
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "checkmark")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!portNeedsSaving || portValidationMessage != nil || isSaving)
                .help(AppLocalization.string("Apply Mixed port"))
                .accessibilityLabel(AppLocalization.string("Apply Mixed port"))
            }

            if let message = errorMessage ?? portValidationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.leading, 33)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .onChange(of: currentPort) { _, port in
            if !portNeedsSaving, let port {
                mixedPort = port
            }
        }
    }

    private var isDefault: Bool {
        model.activeProfileID == profile.id
    }

    private var isRuntimeEnabled: Bool {
        model.profileSessionSpec(for: profile.id)?.enabled == true
    }

    private var currentPort: Int? {
        model.profileSessionSpec(for: profile.id)?.mixedPort
    }

    private var runtimeStatusTitle: String {
        guard let session = model.profileSessionSpec(for: profile.id) else {
            return AppLocalization.string("Mixed port off")
        }
        return session.enabled
            ? AppLocalization.format("Mixed %@ on", String(session.mixedPort))
            : AppLocalization.format(
                "Mixed port off · %@ reserved",
                String(session.mixedPort)
            )
    }

    private var runtimeEnabled: Binding<Bool> {
        Binding(
            get: { isRuntimeEnabled },
            set: { enabled in
                errorMessage = nil
                isSaving = true
                Task {
                    do {
                        try await model.setProfileMixedPortEnabled(
                            profileID: profile.id,
                            enabled: enabled
                        )
                        if let port = model.profileSessionSpec(for: profile.id)?.mixedPort {
                            mixedPort = port
                        }
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isSaving = false
                }
            }
        )
    }

    private var portNeedsSaving: Bool {
        guard let currentPort else { return false }
        return currentPort != mixedPort
    }

    private var portValidationMessage: String? {
        (1...65_535).contains(mixedPort)
            ? nil
            : AppLocalization.string("Use a port from 1 to 65535.")
    }

    private func makeDefault() {
        errorMessage = nil
        isSaving = true
        Task {
            do {
                try await model.activateProfile(profile.id)
                if let port = model.profileSessionSpec(for: profile.id)?.mixedPort {
                    mixedPort = port
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func savePort() {
        guard portValidationMessage == nil, isRuntimeEnabled else { return }
        errorMessage = nil
        isSaving = true
        Task {
            do {
                try await model.updateProfileRuntime(
                    profileID: profile.id,
                    enabled: true,
                    mixedPort: mixedPort
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
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
