import AppKit
import SwiftUI

struct ProfilesView: View {
    @Bindable var model: AppModel
    @State private var showingSubscriptionSheet = false
    @State private var showingDefaultPortSettings = false
    @State private var layout: ProfilesLayout = .wide

    var body: some View {
        Group {
            if let failure = profileStorageFailure {
                ContentUnavailableView {
                    Label("Profiles unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text(
                        AppLocalization.format(
                            "MClash could not read its profile storage. An empty list here does not mean your profiles were deleted.\n\n%@",
                            failure.reason
                        )
                    )
                } actions: {
                    Button("Review Recovery") { model.selection = .attention }
                        .buttonStyle(.borderedProminent)
                }
            } else if model.profiles.isEmpty {
                emptyState
            } else {
                List {
                    Section("Default Profile") {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.triangle.branch")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Default Profile")
                                    .fontWeight(.semibold)
                                Text(defaultProfileDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(
                                AppLocalization.format(
                                    "Mixed %d",
                                    model.profileRuntimePlan.defaultMixedPort
                                )
                            )
                            .font(.callout.monospacedDigit())
                            Button("Port…") {
                                showingDefaultPortSettings = true
                            }
                            .disabled(!model.canPerform(.changeRuntimeSettings))
                        }
                        .padding(.vertical, 5)
                    }

                    Section {
                        ForEach(model.profiles) { profile in
                            ProfileRow(
                                model: model,
                                profile: profile,
                                compact: layout == .compact
                            )
                        }
                    } header: {
                        Text("Profiles")
                    }
                }
                .listStyle(.inset)
                .mclashListSurface()
            }
        }
        .navigationTitle("Profiles")
        .mclashPageSurface()
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { updateLayout(geometry.size.width) }
                    .onChange(of: geometry.size.width) { _, width in
                        updateLayout(width)
                    }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let receipt = model.profileBatchUpdateReceipt,
               !model.isPerforming(.refreshAllProfiles) {
                HStack(spacing: 8) {
                    Image(systemName: receipt.failedCount == 0
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill")
                        .foregroundStyle(receipt.failedCount == 0 ? Color.green : Color.orange)
                        .accessibilityHidden(true)
                    Text(
                        AppLocalization.format(
                            "Subscription refresh completed: %@ updated, %@ unchanged, %@ failed.",
                            formattedCount(receipt.updatedCount),
                            formattedCount(receipt.unchangedCount),
                            formattedCount(receipt.failedCount)
                        )
                    )
                    .font(.callout)
                    Spacer()
                    Text(AppLocalization.relativeDate(receipt.completedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingSubscriptionSheet = true
                } label: {
                    Label("Add Subscription", systemImage: "link.badge.plus")
                }
                .disabled(!model.canPerform(.addRemoteProfile))

                Menu {
                    Button {
                        Task { await model.importProfile() }
                    } label: {
                        Label("Import YAML Profile…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!model.canPerform(.importProfile))

                    if model.profiles.contains(where: { profile in
                        if case .remote = profile.origin { return true }
                        return false
                    }) {
                        Button {
                            Task { await model.refreshAllProfiles() }
                        } label: {
                            Label("Update All Subscriptions", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(!model.canPerform(.refreshAllProfiles))
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
            }
        }
        .sheet(isPresented: $showingSubscriptionSheet) {
            AddSubscriptionView(model: model, isPresented: $showingSubscriptionSheet)
        }
        .sheet(isPresented: $showingDefaultPortSettings) {
            ListenerPortSettingsEditor(
                model: model,
                isPresented: $showingDefaultPortSettings
            )
        }
    }

    private var profileStorageFailure: AppModel.StorageInitializationFailure? {
        model.storageInitializationFailures.first { $0.component == .profiles }
    }

    private func updateLayout(_ width: CGFloat) {
        let next = ProfilesLayout(width: width)
        if layout != next { layout = next }
    }

    private var defaultProfileDescription: String {
        guard let activeProfileID = model.activeProfileID,
              let profile = model.profiles.first(where: { $0.id == activeProfileID })
        else {
            return AppLocalization.string(
                "Choose a real Profile to back this stable entry point."
            )
        }
        return AppLocalization.format(
            "Uses %@ for the stable default entry point.",
            profile.name
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Profiles", systemImage: "doc.badge.plus")
        } description: {
            Text("Import a local YAML configuration or add a subscription to get started.")
        } actions: {
            HStack(spacing: 10) {
                Button {
                    Task { await model.importProfile() }
                } label: {
                    if model.isPerforming(.importProfile) {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Importing…")
                        }
                    } else {
                        Label("Import…", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(!model.canPerform(.importProfile))

                Button {
                    showingSubscriptionSheet = true
                } label: {
                    Label("Add Subscription…", systemImage: "link.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPerform(.addRemoteProfile))
            }
        }
    }
}

private enum ProfilesLayout: Equatable {
    case compact
    case wide

    init(width: CGFloat) {
        self = width < 720 ? .compact : .wide
    }
}

enum SubscriptionRefreshStatusText {
    static func failure(
        _ remote: RemoteSubscriptionMetadata,
        relativeDate: (Date) -> String
    ) -> String? {
        guard remote.consecutiveFailureCount > 0,
              let lastFailureAt = remote.lastFailureAt else { return nil }

        var parts = [
            AppLocalization.format(
                "Last refresh failed %@",
                relativeDate(lastFailureAt)
            ),
        ]
        if remote.consecutiveFailureCount > 1 {
            parts.append(
                AppLocalization.format(
                    "%d consecutive failures",
                    remote.consecutiveFailureCount
                )
            )
        }
        if remote.automaticUpdatesEnabled, let nextRetryAt = remote.nextRetryAt {
            parts.append(
                AppLocalization.format(
                    "Automatic retry %@",
                    relativeDate(nextRetryAt)
                )
            )
        } else if !remote.automaticUpdatesEnabled {
            parts.append(AppLocalization.string("Automatic retry off"))
        }
        return parts.joined(separator: " · ")
    }
}

private struct ProfileRow: View {
    @Bindable var model: AppModel
    let profile: ProfileMetadata
    let compact: Bool
    @State private var confirmingDelete = false
    @State private var showingEditSheet = false
    @State private var operationError: String?

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        activeIndicator
                        profileDetails
                        Spacer(minLength: 0)
                    }
                    profileActions
                        .padding(.leading, 36)
                }
            } else {
                HStack(alignment: .center, spacing: 14) {
                    activeIndicator
                    profileDetails
                    Spacer(minLength: 18)
                    profileActions
                }
            }
        }
        .padding(.vertical, compact ? 9 : 7)
        .accessibilityElement(children: .contain)
        .confirmationDialog(
            AppLocalization.format("Delete %@?", profile.name),
            isPresented: $confirmingDelete
        ) {
            Button("Delete Profile", role: .destructive) {
                remove()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the stored profile from MClash. The subscription itself is not changed.")
        }
        .sheet(isPresented: $showingEditSheet) {
            EditProfileView(
                model: model,
                profile: profile,
                isPresented: $showingEditSheet
            )
        }
        .contextMenu {
            if case let .remote(remote) = profile.origin {
                Button("Copy Subscription URL", systemImage: "doc.on.doc") {
                    copyToPasteboard(remote.url.absoluteString)
                }
                Divider()
            }
            Button("Edit Profile…", systemImage: "pencil") {
                showingEditSheet = true
            }
            .disabled(!model.canPerform(.updateProfile(profile.id)))
            if !isActive {
                Button("Make Default", systemImage: "checkmark.circle") { activate() }
                    .disabled(!model.canPerform(.activateProfile(profile.id)))
            }
            if isRemote {
                Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                    .disabled(!model.canPerform(.refreshProfile(profile.id)))
            }
        }
    }

    private var profileDetails: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(profile.name)
                    .font(.body.weight(isActive ? .semibold : .regular))
                    .lineLimit(compact ? 2 : 1)
                    .help(profile.name)

            }

            if compact {
                VStack(alignment: .leading, spacing: 3) {
                    Label(originTitle, systemImage: originSymbol)
                    Text(lastUpdatedTitle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Label(originTitle, systemImage: originSymbol)
                    Text("•")
                        .accessibilityHidden(true)
                    Text(lastUpdatedTitle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let operationTitle {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text(operationTitle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            } else if let operationError {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(operationError)
                        .lineLimit(2)
                    Button("Dismiss") { self.operationError = nil }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .contain)
            }

            if case let .remote(remote) = profile.origin,
               let refreshFailure = SubscriptionRefreshStatusText.failure(
                   remote,
                   relativeDate: AppLocalization.relativeDate
               ) {
                Label(refreshFailure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(compact ? 3 : 2)
                    .accessibilityLabel(refreshFailure)
            }
        }
    }

    private var profileActions: some View {
        HStack(spacing: 8) {
            primaryProfileAction
            profileMoreMenu
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var primaryProfileAction: some View {
        if isActive {
            Label("Default Source", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(Color.accentColor)
                .frame(minWidth: 104)
                .accessibilityLabel(
                    AppLocalization.format(
                        "%@ backs the Default Profile",
                        profile.name
                    )
                )
        } else {
            Button("Make Default") {
                activate()
            }
            .buttonStyle(.bordered)
            .disabled(!model.canPerform(.activateProfile(profile.id)))
            .help(
                AppLocalization.format(
                    "Use %@ as the default profile",
                    profile.name
                )
            )
        }
    }

    private var profileMoreMenu: some View {
        Menu {
            Button("Edit…", systemImage: "pencil") {
                showingEditSheet = true
            }
            .disabled(!model.canPerform(.updateProfile(profile.id)))

            if isRemote {
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!model.canPerform(.refreshProfile(profile.id)))
            }

            if case let .remote(remote) = profile.origin {
                Button("Copy Subscription URL", systemImage: "doc.on.doc") {
                    copyToPasteboard(remote.url.absoluteString)
                }
            }

            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                confirmingDelete = true
            }
            .disabled(removalBlockReason != nil
                || !model.canPerform(.removeProfile(profile.id)))
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel(AppLocalization.format("More actions for %@", profile.name))
        .help(AppLocalization.format("More actions for %@", profile.name))
    }

    private var activeIndicator: some View {
        Image(systemName: isActive ? "star.circle.fill" : originSymbol)
            .font(.title3)
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
            .frame(width: 24)
            .accessibilityHidden(true)
    }

    private var isActive: Bool {
        model.activeProfileID == profile.id
    }

    private var isRemote: Bool {
        if case .remote = profile.origin { return true }
        return false
    }

    private var removalBlockReason: String? {
        model.profileRemovalBlockReason(for: profile.id)
    }

    private var originTitle: String {
        switch profile.origin {
        case .local:
            AppLocalization.string("Local")
        case let .imported(fileName):
            AppLocalization.format("Imported from %@", fileName)
        case .remote:
            AppLocalization.string("Subscription")
        }
    }

    private var originSymbol: String {
        switch profile.origin {
        case .local: "doc"
        case .imported: "square.and.arrow.down"
        case .remote: "link"
        }
    }

    private var lastUpdatedTitle: String {
        switch profile.origin {
        case let .remote(remote):
            if let updatedAt = remote.lastSuccessfulUpdateAt {
                return AppLocalization.format(
                    "Updated %@",
                    AppLocalization.relativeDate(updatedAt)
                )
            }
            if let checkedAt = remote.lastCheckedAt {
                return AppLocalization.format(
                    "Checked %@ · No update yet",
                    AppLocalization.relativeDate(checkedAt)
                )
            }
            return AppLocalization.string("Not updated yet")
        case .local, .imported:
            return AppLocalization.format(
                "Updated %@",
                AppLocalization.relativeDate(profile.updatedAt)
            )
        }
    }

    private var operationTitle: String? {
        if model.isPerforming(.refreshAllProfiles) {
            return AppLocalization.string("Updating subscriptions…")
        }
        if model.isPerforming(.updateProfile(profile.id)) {
            return AppLocalization.string("Saving settings…")
        }
        if model.isPerforming(.refreshProfile(profile.id)) {
            return AppLocalization.string("Refreshing and validating…")
        }
        if model.isPerforming(.activateProfile(profile.id)) {
            return AppLocalization.string("Changing default profile…")
        }
        if model.isPerforming(.removeProfile(profile.id)) {
            return AppLocalization.string("Deleting…")
        }
        return nil
    }

    private func activate() {
        operationError = nil
        Task {
            do {
                try await model.activateProfile(profile.id)
            } catch {
                let message = sanitizedError(error.localizedDescription)
                operationError = message
                model.errorMessage = message
            }
        }
    }

    private func refresh() {
        operationError = nil
        let previousError = model.errorMessage
        Task {
            await model.refreshProfile(profile.id)
            if let message = model.errorMessage, message != previousError {
                let sanitized = sanitizedError(message)
                operationError = sanitized
                model.errorMessage = sanitized
            }
        }
    }

    private func remove() {
        operationError = nil
        let previousError = model.errorMessage
        Task {
            await model.removeProfile(profile.id)
            if let message = model.errorMessage, message != previousError {
                let sanitized = sanitizedError(message)
                operationError = sanitized
                model.errorMessage = sanitized
            }
        }
    }

    private func sanitizedError(_ message: String) -> String {
        guard case let .remote(remote) = profile.origin else { return message }
        return redact(remote.url, from: message)
    }

    private func redact(_ url: URL, from message: String) -> String {
        var sanitized = message.replacingOccurrences(
            of: url.absoluteString,
            with: AppLocalization.string("the subscription endpoint"),
            options: .caseInsensitive
        )
        if let host = url.host, !host.isEmpty {
            sanitized = sanitized.replacingOccurrences(
                of: host,
                with: AppLocalization.string("the subscription host"),
                options: .caseInsensitive
            )
        }
        return sanitized
    }
}

private struct EditProfileView: View {
    private enum Field: Hashable {
        case name
        case address
        case mixedPort
    }

    @Bindable var model: AppModel
    let profile: ProfileMetadata
    @Binding var isPresented: Bool
    @State private var name: String
    @State private var address: String
    @State private var automaticUpdatesEnabled: Bool
    @State private var overridesUpdateInterval: Bool
    @State private var updateIntervalHours: Int
    @State private var runtimeEnabled: Bool
    @State private var mixedPort: Int
    @State private var submissionError: String?
    @State private var submissionTask: Task<Void, Never>?
    @State private var attemptedSubmission = false
    @State private var advancedExpanded = false
    @FocusState private var focusedField: Field?

    init(model: AppModel, profile: ProfileMetadata, isPresented: Binding<Bool>) {
        self.model = model
        self.profile = profile
        _isPresented = isPresented
        _name = State(initialValue: profile.name)
        let runtime = model.profileSessionSpec(for: profile.id)
        _runtimeEnabled = State(
            initialValue: runtime?.enabled == true
        )
        _mixedPort = State(initialValue: runtime?.mixedPort ?? 7_890)
        if case let .remote(remote) = profile.origin {
            _address = State(initialValue: remote.url.absoluteString)
            _automaticUpdatesEnabled = State(initialValue: remote.automaticUpdatesEnabled)
            _overridesUpdateInterval = State(initialValue: remote.updateIntervalHours != nil)
            _updateIntervalHours = State(
                initialValue: remote.updateIntervalHours ?? remote.effectiveUpdateIntervalHours
            )
            _advancedExpanded = State(
                initialValue: runtime?.enabled == true || remote.updateIntervalHours != nil
            )
        } else {
            _address = State(initialValue: "")
            _automaticUpdatesEnabled = State(initialValue: false)
            _overridesUpdateInterval = State(initialValue: false)
            _updateIntervalHours = State(initialValue: 24)
            _advancedExpanded = State(initialValue: runtime?.enabled == true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit Profile")
                .font(.title2.weight(.semibold))

            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                        .focused($focusedField, equals: .name)
                        .disabled(isSubmitting)

                    if isRemote {
                        TextField("Subscription URL", text: $address)
                            .textContentType(.URL)
                            .privacySensitive()
                            .focused($focusedField, equals: .address)
                            .disabled(isSubmitting)
                    }
                }

                if isRemote {
                    Section("Updates") {
                        Toggle("Update automatically", isOn: $automaticUpdatesEnabled)
                            .disabled(isSubmitting)

                        if let subscriptionDetails {
                            DisclosureGroup("Subscription Details") {
                                Text(subscriptionDetails)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Section {
                    DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                        if isRemote {
                            Toggle("Use a custom update interval", isOn: $overridesUpdateInterval)
                                .disabled(isSubmitting || !automaticUpdatesEnabled)

                            if automaticUpdatesEnabled, overridesUpdateInterval {
                                Stepper(
                                    AppLocalization.format(
                                        "Update every %d hours",
                                        updateIntervalHours
                                    ),
                                    value: $updateIntervalHours,
                                    in: 1...8_760
                                )
                                .disabled(isSubmitting)
                            } else if automaticUpdatesEnabled,
                                      let suggestedInterval = remoteMetadata?.providerSuggestedUpdateIntervalHours {
                                Text(
                                    AppLocalization.format(
                                        "The subscription provider suggests every %d hours.",
                                        suggestedInterval
                                    )
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Toggle("Open Mixed port", isOn: $runtimeEnabled)
                            .disabled(isSubmitting)

                        LabeledContent("Mixed port") {
                            TextField(
                                "Port",
                                value: $mixedPort,
                                format: .number.grouping(.never)
                            )
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 92)
                            .disabled(isSubmitting || !runtimeEnabled)
                            .focused($focusedField, equals: .mixedPort)
                        }

                        Text(
                            AppLocalization.string(
                                profile.id == model.activeProfileID
                                    ? "This port is independent from the stable Default Profile port."
                                    : "Open this port only when App Routing or a local tool needs this Profile directly."
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            if attemptedSubmission, let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if let submissionError {
                Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving profile settings…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting)
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 520, maxWidth: 680)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear { focusedField = .name }
        .onDisappear { submissionTask?.cancel() }
    }

    private var isRemote: Bool {
        remoteMetadata != nil
    }

    private var remoteMetadata: RemoteSubscriptionMetadata? {
        guard case let .remote(remote) = profile.origin else { return nil }
        return remote
    }

    private var subscriptionDetails: String? {
        guard let usage = remoteMetadata?.usage else { return nil }
        var details: [String] = []
        if let used = usage.used, let total = usage.total, total > 0 {
            details.append(
                AppLocalization.format(
                    "Used %@ of %@",
                    formattedByteCount(used, style: .binary),
                    formattedByteCount(total, style: .binary)
                )
            )
        }
        if let expiresAt = usage.expiresAt {
            details.append(
                AppLocalization.format(
                    "Expires %@",
                    expiresAt.formatted(
                        .dateTime
                            .year()
                            .month(.abbreviated)
                            .day()
                            .locale(.autoupdatingCurrent)
                    )
                )
            )
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validatedURL: URL? {
        guard let url = URL(string: normalizedAddress),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    private var validationMessage: String? {
        if normalizedName.isEmpty {
            return AppLocalization.string("Enter a profile name.")
        }
        if isRemote, validatedURL == nil {
            return AppLocalization.string(
                "Use a complete HTTP or HTTPS subscription address."
            )
        }
        if (model.profileSessionSpec(for: profile.id) != nil || runtimeEnabled)
            && !(1...65_535).contains(mixedPort) {
            return AppLocalization.string("Use a Mixed port from 1 to 65535.")
        }
        return nil
    }

    private var isSubmitting: Bool {
        submissionTask != nil
    }

    private func submit() {
        attemptedSubmission = true
        submissionError = nil
        if let validationMessage {
            focusValidationError()
            announceValidationError(validationMessage)
            return
        }

        submissionTask = Task {
            do {
                if model.profileSessionSpec(for: profile.id) != nil || runtimeEnabled {
                    try await model.updateProfileRuntime(
                        profileID: profile.id,
                        enabled: runtimeEnabled,
                        mixedPort: mixedPort
                    )
                }
                try await model.updateProfile(
                    profile.id,
                    name: normalizedName,
                    subscriptionURL: isRemote ? validatedURL : nil,
                    automaticUpdatesEnabled: automaticUpdatesEnabled,
                    updateIntervalHours: overridesUpdateInterval ? updateIntervalHours : nil
                )
                if !Task.isCancelled {
                    await MainActor.run { isPresented = false }
                }
            } catch is CancellationError {
                // Closing the sheet cancels its in-flight work.
            } catch {
                if !Task.isCancelled {
                    await MainActor.run { submissionError = error.localizedDescription }
                }
            }
            await MainActor.run { submissionTask = nil }
        }
    }

    private func cancel() {
        submissionTask?.cancel()
        isPresented = false
    }

    private func focusValidationError() {
        if normalizedName.isEmpty {
            focusedField = .name
        } else if isRemote, validatedURL == nil {
            focusedField = .address
        } else {
            advancedExpanded = true
            Task { @MainActor in
                await Task.yield()
                focusedField = .mixedPort
            }
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
}

private struct AddSubscriptionView: View {
    private enum Field: Hashable {
        case name
        case address
    }

    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var address = ""
    @State private var submissionError: String?
    @State private var submissionTask: Task<Void, Never>?
    @State private var attemptedSubmission = false
    @State private var showsNameField = false
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Add Subscription", systemImage: "link.badge.plus")
                    .font(.title2.weight(.semibold))
                Text("MClash will download and validate the profile before adding it. Your current default profile will not change.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        TextField("Subscription URL", text: $address)
                            .textContentType(.URL)
                            .privacySensitive()
                            .focused($focusedField, equals: .address)
                            .submitLabel(.done)
                            .onSubmit { submit() }
                            .disabled(isSubmitting)
                            .accessibilityIdentifier("subscription.url")

                        if let addressValidationMessage {
                            validationLabel(addressValidationMessage)
                                .accessibilityIdentifier("subscription.url.error")
                        }
                    }

                    DisclosureGroup(
                        "Profile Name (Optional)",
                        isExpanded: $showsNameField
                    ) {
                        TextField("Name", text: $name)
                            .focused($focusedField, equals: .name)
                            .submitLabel(.done)
                            .onSubmit { submit() }
                            .disabled(isSubmitting)
                            .accessibilityIdentifier("subscription.name")
                    }
                }
            }
            .formStyle(.grouped)

            if let submissionError {
                Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("subscription.error")
            } else if !isSubmitting, !model.canPerform(.addRemoteProfile) {
                Label(
                    "Finish the current network or profile operation before adding this subscription.",
                    systemImage: "clock"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading and validating profile…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("subscription.progress")
                }

                Spacer()

                Button("Cancel", role: .cancel) {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("subscription.cancel")

                Button("Add Subscription") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || !model.canPerform(.addRemoteProfile))
                .accessibilityIdentifier("subscription.submit")
            }
        }
        .padding(24)
        .frame(minWidth: 420, idealWidth: 520, maxWidth: 680)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear { focusedField = .address }
        .onChange(of: name) { _, _ in
            submissionError = nil
        }
        .onChange(of: address) { _, _ in
            submissionError = nil
        }
        .onDisappear {
            submissionTask?.cancel()
        }
    }

    @ViewBuilder
    private func validationLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isSubmitting: Bool {
        submissionTask != nil
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validatedURL: URL? {
        guard let url = URL(string: normalizedAddress),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private var addressValidationMessage: String? {
        guard attemptedSubmission || !normalizedAddress.isEmpty else { return nil }
        if normalizedAddress.isEmpty {
            return AppLocalization.string("Enter the subscription address.")
        }
        if validatedURL == nil {
            return AppLocalization.string("Use a complete HTTP or HTTPS address.")
        }
        return nil
    }

    private func submit() {
        attemptedSubmission = true
        submissionError = nil

        guard let url = validatedURL else {
            focusedField = .address
            if let addressValidationMessage {
                announceValidationError(addressValidationMessage)
            }
            return
        }
        guard model.canPerform(.addRemoteProfile), submissionTask == nil else {
            submissionError = AppLocalization.string(
                "Another network or profile operation is still finishing. Try again in a moment."
            )
            return
        }

        focusedField = nil
        submissionTask = Task {
            do {
                try await model.addRemoteProfile(
                    name: normalizedName.isEmpty ? suggestedName(for: url) : normalizedName,
                    url: url,
                    activate: model.activeProfileID == nil
                )
                if !Task.isCancelled {
                    await MainActor.run {
                        isPresented = false
                    }
                }
            } catch is CancellationError {
                // The sheet is normally already dismissed by the cancel action.
            } catch {
                if !Task.isCancelled {
                    let message = sanitizedError(error.localizedDescription, url: url)
                    await MainActor.run {
                        submissionError = message
                    }
                }
            }
            await MainActor.run { submissionTask = nil }
        }
    }

    private func cancel() {
        submissionTask?.cancel()
        isPresented = false
    }

    private func suggestedName(for url: URL) -> String {
        url.host ?? url.absoluteString
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

    private func sanitizedError(_ message: String, url: URL) -> String {
        var sanitized = message.replacingOccurrences(
            of: url.absoluteString,
            with: AppLocalization.string("the subscription endpoint"),
            options: .caseInsensitive
        )
        if let host = url.host, !host.isEmpty {
            sanitized = sanitized.replacingOccurrences(
                of: host,
                with: AppLocalization.string("the subscription host"),
                options: .caseInsensitive
            )
        }
        return sanitized
    }
}
