import SwiftUI

struct ProfilesView: View {
    @Bindable var model: AppModel
    @State private var showingSubscriptionSheet = false
    @State private var layout: ProfilesLayout = .wide

    var body: some View {
        Group {
            if let failure = profileStorageFailure {
                ContentUnavailableView {
                    Label("Profiles unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("MClash could not read its profile storage. An empty list here does not mean your profiles were deleted.\n\n\(failure.reason)")
                } actions: {
                    Button("Review Recovery") { model.selection = .attention }
                        .buttonStyle(.borderedProminent)
                }
            } else if model.profiles.isEmpty {
                emptyState
            } else {
                List(model.profiles) { profile in
                    ProfileRow(
                        model: model,
                        profile: profile,
                        compact: layout == .compact
                    )
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
                        "Subscription refresh completed: \(formattedCount(receipt.updatedCount)) updated, \(formattedCount(receipt.unchangedCount)) unchanged, \(formattedCount(receipt.failedCount)) failed."
                    )
                    .font(.callout)
                    Spacer()
                    Text(receipt.completedAt, style: .relative)
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
                if model.profiles.contains(where: { profile in
                    if case .remote = profile.origin { return true }
                    return false
                }) {
                    Button {
                        Task { await model.refreshAllProfiles() }
                    } label: {
                        if model.isPerforming(.refreshAllProfiles) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Update All", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(!model.canPerform(.refreshAllProfiles))
                    .help("Refresh all subscriptions")
                }

                Button {
                    Task { await model.importProfile() }
                } label: {
                    if model.isPerforming(.importProfile) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Import & Activate", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(!model.canPerform(.importProfile))
                .help("Import a local YAML profile and make it active")
                .accessibilityLabel(
                    model.isPerforming(.importProfile)
                        ? "Importing and activating YAML profile"
                        : "Import and activate YAML profile"
                )

                Button {
                    showingSubscriptionSheet = true
                } label: {
                    Label("Add Subscription", systemImage: "link.badge.plus")
                }
                .disabled(!model.canPerform(.addRemoteProfile))
                .help("Add a profile subscription")
            }
        }
        .sheet(isPresented: $showingSubscriptionSheet) {
            AddSubscriptionView(model: model, isPresented: $showingSubscriptionSheet)
        }
    }

    private var profileStorageFailure: AppModel.StorageInitializationFailure? {
        model.storageInitializationFailures.first { $0.component == .profiles }
    }

    private func updateLayout(_ width: CGFloat) {
        let next = ProfilesLayout(width: width)
        if layout != next { layout = next }
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
                        Label("Import & Activate…", systemImage: "square.and.arrow.down")
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
            "Delete \(profile.name)?",
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
                Button("Activate", systemImage: "checkmark.circle") { activate() }
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
               let subscriptionDetails = subscriptionDetails(remote) {
                Text(subscriptionDetails)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var profileActions: some View {
        if compact {
            HStack(spacing: 8) {
                primaryProfileAction
                profileMoreMenu
            }
            .controlSize(.small)
        } else {
            HStack(spacing: 8) {
                Button {
                    showingEditSheet = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canPerform(.updateProfile(profile.id)))
                .help("Edit \(profile.name)")

                if isRemote {
                    Button {
                        refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.canPerform(.refreshProfile(profile.id)))
                    .help("Refresh \(profile.name) subscription")
                }

                primaryProfileAction

                Button("Delete", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
                .buttonStyle(.borderless)
                .disabled(isActive || !model.canPerform(.removeProfile(profile.id)))
                .help(isActive ? "Activate another profile before deleting this one" : "Delete \(profile.name)")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var primaryProfileAction: some View {
        if isActive {
            Text("In Use")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minWidth: 64)
                .accessibilityLabel("\(profile.name) is the active profile")
        } else {
            Button("Activate") {
                activate()
            }
            .buttonStyle(.bordered)
            .disabled(!model.canPerform(.activateProfile(profile.id)))
            .help("Activate \(profile.name)")
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
            .disabled(isActive || !model.canPerform(.removeProfile(profile.id)))
        } label: {
            Label("More", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .help("More actions for \(profile.name)")
    }

    private var activeIndicator: some View {
        Image(systemName: isActive ? "checkmark.circle.fill" : originSymbol)
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

    private var originTitle: String {
        switch profile.origin {
        case .local:
            "Local"
        case let .imported(fileName):
            "Imported from \(fileName)"
        case .remote:
            "Subscription"
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
                return "Updated \(relativeDate(updatedAt))"
            }
            if let checkedAt = remote.lastCheckedAt {
                return "Checked \(relativeDate(checkedAt)) · No update yet"
            }
            return "Not updated yet"
        case .local, .imported:
            return "Updated \(relativeDate(profile.updatedAt))"
        }
    }

    private var operationTitle: String? {
        if model.isPerforming(.refreshAllProfiles) { return "Updating subscriptions…" }
        if model.isPerforming(.updateProfile(profile.id)) { return "Saving settings…" }
        if model.isPerforming(.refreshProfile(profile.id)) { return "Refreshing and validating…" }
        if model.isPerforming(.activateProfile(profile.id)) { return "Activating and checking…" }
        if model.isPerforming(.removeProfile(profile.id)) { return "Deleting…" }
        return nil
    }

    private func relativeDate(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    private func subscriptionDetails(_ remote: RemoteSubscriptionMetadata) -> String? {
        var details: [String] = []
        if let usage = remote.usage,
           let used = usage.used,
           let total = usage.total,
           total > 0 {
            details.append(
                "Used \(ByteCountFormatter.string(fromByteCount: used, countStyle: .binary)) of "
                    + ByteCountFormatter.string(fromByteCount: total, countStyle: .binary)
            )
        }
        if let expiresAt = remote.usage?.expiresAt {
            details.append("Expires \(expiresAt.formatted(date: .abbreviated, time: .omitted))")
        }
        if remote.automaticUpdatesEnabled {
            details.append("Every \(remote.effectiveUpdateIntervalHours)h")
        } else {
            details.append("Automatic updates off")
        }
        return details.isEmpty ? nil : details.joined(separator: " · ")
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
            with: "the subscription endpoint",
            options: .caseInsensitive
        )
        if let host = url.host, !host.isEmpty {
            sanitized = sanitized.replacingOccurrences(
                of: host,
                with: "the subscription host",
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
    }

    @Bindable var model: AppModel
    let profile: ProfileMetadata
    @Binding var isPresented: Bool
    @State private var name: String
    @State private var address: String
    @State private var automaticUpdatesEnabled: Bool
    @State private var overridesUpdateInterval: Bool
    @State private var updateIntervalHours: Int
    @State private var submissionError: String?
    @State private var submissionTask: Task<Void, Never>?
    @State private var attemptedSubmission = false
    @FocusState private var focusedField: Field?

    init(model: AppModel, profile: ProfileMetadata, isPresented: Binding<Bool>) {
        self.model = model
        self.profile = profile
        _isPresented = isPresented
        _name = State(initialValue: profile.name)
        if case let .remote(remote) = profile.origin {
            _address = State(initialValue: remote.url.absoluteString)
            _automaticUpdatesEnabled = State(initialValue: remote.automaticUpdatesEnabled)
            _overridesUpdateInterval = State(initialValue: remote.updateIntervalHours != nil)
            _updateIntervalHours = State(
                initialValue: remote.updateIntervalHours ?? remote.effectiveUpdateIntervalHours
            )
        } else {
            _address = State(initialValue: "")
            _automaticUpdatesEnabled = State(initialValue: false)
            _overridesUpdateInterval = State(initialValue: false)
            _updateIntervalHours = State(initialValue: 24)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit Profile")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Name", text: $name)
                    .focused($focusedField, equals: .name)
                    .disabled(isSubmitting)

                if isRemote {
                    TextField("Subscription URL", text: $address)
                        .textContentType(.URL)
                        .privacySensitive()
                        .focused($focusedField, equals: .address)
                        .disabled(isSubmitting)

                    Toggle("Update automatically", isOn: $automaticUpdatesEnabled)
                        .disabled(isSubmitting)

                    Toggle("Use a custom update interval", isOn: $overridesUpdateInterval)
                        .disabled(isSubmitting || !automaticUpdatesEnabled)

                    if automaticUpdatesEnabled, overridesUpdateInterval {
                        Stepper(
                            "Update every \(updateIntervalHours) hours",
                            value: $updateIntervalHours,
                            in: 1...8_760
                        )
                        .disabled(isSubmitting)
                    } else if automaticUpdatesEnabled,
                              let suggestedInterval = remoteMetadata?.providerSuggestedUpdateIntervalHours {
                        Text("The subscription provider suggests every \(suggestedInterval) hours.")
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
                    .disabled(isSubmitting || validationMessage != nil)
            }
        }
        .padding(24)
        .frame(width: 520)
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
        if normalizedName.isEmpty { return "Enter a profile name." }
        if isRemote, validatedURL == nil { return "Use a complete HTTP or HTTPS subscription address." }
        return nil
    }

    private var isSubmitting: Bool {
        submissionTask != nil
    }

    private func submit() {
        attemptedSubmission = true
        submissionError = nil
        guard validationMessage == nil else { return }

        submissionTask = Task {
            do {
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
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Add Subscription", systemImage: "link.badge.plus")
                    .font(.title2.weight(.semibold))
                Text("MClash will download, validate, and activate the profile before adding it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        TextField("Name", text: $name)
                            .focused($focusedField, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .address }
                            .disabled(isSubmitting)
                            .accessibilityIdentifier("subscription.name")

                        if let nameValidationMessage {
                            validationLabel(nameValidationMessage)
                                .accessibilityIdentifier("subscription.name.error")
                        }
                    }

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

                Button("Add") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
                .accessibilityIdentifier("subscription.submit")
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(isSubmitting)
        .onAppear { focusedField = .name }
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

    private var nameValidationMessage: String? {
        guard attemptedSubmission, normalizedName.isEmpty else { return nil }
        return "Enter a name for this profile."
    }

    private var addressValidationMessage: String? {
        guard attemptedSubmission || !normalizedAddress.isEmpty else { return nil }
        if normalizedAddress.isEmpty { return "Enter the subscription address." }
        if validatedURL == nil { return "Use a complete HTTP or HTTPS address." }
        return nil
    }

    private var canSubmit: Bool {
        !isSubmitting
            && !normalizedName.isEmpty
            && validatedURL != nil
            && model.canPerform(.addRemoteProfile)
    }

    private func submit() {
        attemptedSubmission = true
        submissionError = nil

        guard !normalizedName.isEmpty else {
            focusedField = .name
            return
        }
        guard let url = validatedURL else {
            focusedField = .address
            return
        }
        guard model.canPerform(.addRemoteProfile), submissionTask == nil else {
            submissionError = "Another network or profile operation is still finishing. Try again in a moment."
            return
        }

        focusedField = nil
        submissionTask = Task {
            do {
                try await model.addRemoteProfile(name: normalizedName, url: url)
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

    private func sanitizedError(_ message: String, url: URL) -> String {
        var sanitized = message.replacingOccurrences(
            of: url.absoluteString,
            with: "the subscription endpoint",
            options: .caseInsensitive
        )
        if let host = url.host, !host.isEmpty {
            sanitized = sanitized.replacingOccurrences(
                of: host,
                with: "the subscription host",
                options: .caseInsensitive
            )
        }
        return sanitized
    }
}
