import MClashNetworkShared
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

private struct AppRoutingActivityPresentationSnapshot: Sendable {
    static let empty = AppRoutingActivityPresentationSnapshot(
        activities: [],
        flowEntries: [:],
        target: nil,
        searchText: ""
    )

    let visibleActivities: [AppRoutingActivity]
    let visibleIdentifiers: Set<UUID>
    let activitiesByIdentifier: [UUID: AppRoutingActivity]
    let activeCount: Int

    init(
        activities: [AppRoutingActivity],
        flowEntries: [UUID: FlowLedgerEntry],
        target: ProfileTrafficTarget?,
        searchText: String
    ) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var visibleActivities: [AppRoutingActivity] = []
        visibleActivities.reserveCapacity(activities.count)
        for (index, activity) in activities.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { break }
            guard activity.isLiveManagedFlow else { continue }
            guard target == nil || activity.mclashTrafficTarget == target
            else { continue }
            if query.isEmpty
                || Self.searchText(for: activity, entry: flowEntries[activity.flowIdentifier])
                    .contains(query) {
                visibleActivities.append(activity)
            }
        }
        self.visibleActivities = visibleActivities
        visibleIdentifiers = Set(visibleActivities.map(\.flowIdentifier))
        activitiesByIdentifier = Task.isCancelled ? [:] : Dictionary(
            uniqueKeysWithValues: visibleActivities.map { ($0.flowIdentifier, $0) }
        )
        activeCount = activities.count {
            $0.isLiveManagedFlow
                && (target == nil || $0.mclashTrafficTarget == target)
        }
    }

    private static func searchText(
        for activity: AppRoutingActivity,
        entry: FlowLedgerEntry?
    ) -> String {
        let disposition = switch activity.effectiveAction {
        case .direct: "direct pass-through"
        case .reject: "rejected"
        case .failOpen: "fail-open"
        case .mihomo: "mihomo proxy"
        }
        let route = entry?.mihomoRoute
        return [
            activity.source.executablePath,
            activity.source.bundleIdentifier,
            activity.source.signingIdentifier,
            activity.source.teamIdentifier,
            activity.destination.hostname,
            activity.destination.ipAddress,
            String(activity.destination.port),
            destinationText(activity),
            activity.matchedRuleIdentifier,
            causeText(activity),
            disposition,
            resultText(activity, entry: entry),
            activity.relayState.rawValue,
            activity.relayError,
            activity.relayNote,
            route?.rule,
            route?.rulePayload,
            route?.chain.joined(separator: " "),
            pathText(activity, entry: entry),
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
        .lowercased()
    }

    private static func causeText(_ activity: AppRoutingActivity) -> String {
        switch activity.cause {
        case .captureDisabled: "Capture disabled"
        case .configurationUnavailable: "Configuration unavailable"
        case .contextUnavailable: "Identity unavailable"
        case let .rule(cause), let .mihomoUnavailable(cause, _):
            switch cause {
            case let .matchedRule(identifier): identifier
            case let .builtInBypass(reason): "Built-in: \(reason.rawValue)"
            case .defaultDirect: "Default direct"
            }
        }
    }

    private static func destinationText(_ activity: AppRoutingActivity) -> String {
        let host = activity.destination.hostname
            ?? activity.destination.ipAddress
            ?? "Unknown destination"
        return activity.destination.port > 0
            ? "\(host):\(activity.destination.port)"
            : host
    }

    private static func resultText(
        _ activity: AppRoutingActivity,
        entry: FlowLedgerEntry?
    ) -> String {
        if activity.relayState == .failed { return "Relay failed" }
        return switch activity.effectiveAction {
        case .direct where activity.payloadBytesAreMeasured == true:
            "Direct \(activity.relayState.rawValue)"
        case .direct: "Direct pass-through"
        case .reject: "Rejected"
        case .failOpen: "Fail-open"
        case .mihomo:
            if FlowLedgerAssociationPresentation.isConfirmed(entry?.association) {
                "Route confirmed"
            } else if FlowLedgerAssociationPresentation.isProbable(entry?.association) {
                "Probable Mihomo match"
            } else if (activity.downloadDatagrams ?? 0) > 0 {
                "Response observed"
            } else {
                "Sent to Mihomo \(activity.relayState.rawValue)"
            }
        }
    }

    private static func pathText(
        _ activity: AppRoutingActivity,
        entry: FlowLedgerEntry?
    ) -> String {
        guard case .mihomo = activity.effectiveAction else { return "" }
        guard let route = entry?.mihomoRoute else {
            if activity.relayState == .failed { return "Relay failed" }
            if (activity.downloadDatagrams ?? 0) > 0 {
                return "Response observed node path not yet matched"
            }
            if (activity.uploadDatagrams ?? 0) > 0 || activity.uploadBytes > 0 {
                return "Sent to Mihomo awaiting connections confirmation"
            }
            return "Waiting for Mihomo metadata"
        }
        return [route.rule, route.rulePayload, route.chain.joined(separator: " ")]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

struct AppRoutingView: View {
    private enum ProfileScope: Hashable {
        case all
        case defaultProfile
        case profile(ProfileID)
        case system

        var trafficTarget: ProfileTrafficTarget? {
            switch self {
            case .all: nil
            case .defaultProfile: .defaultProfile
            case let .profile(profileID): .profile(profileID)
            case .system: .system
            }
        }
    }

    private enum Workspace: String, CaseIterable, Identifiable {
        case rules = "Rules"
        case activity = "Activity"

        var id: Self { self }
    }

    private enum InspectorPresentation: Equatable {
        case popover
        case attached

        func presentation(forFullWidth width: CGFloat) -> Self {
            let attachWidth: CGFloat = 1_100
            let detachWidth: CGFloat = 980
            switch self {
            case .popover:
                return width >= attachWidth ? .attached : .popover
            case .attached:
                return width < detachWidth ? .popover : .attached
            }
        }
    }

    @Bindable var model: AppModel

    @State private var applicationCandidates: [ApplicationCaptureCandidate] = []
    @State private var processCandidates: [RunningProcessCaptureCandidate] = []
    @State private var selectedRuleID: String?
    @State private var draft = CaptureRuleDraft()
    @State private var editingRuleID: String?
    @State private var showingEditor = false
    @State private var editorError: String?
    @State private var candidateRefreshRequest = 0
    @State private var workspace: Workspace = .rules
    @State private var activitySearchText = ""
    @State private var debouncedActivitySearchText = ""
    @State private var activityPresentation = AppRoutingActivityPresentationSnapshot.empty
    @State private var activityPresentationTask: Task<Void, Never>?
    @State private var activityPresentationGeneration: UInt64 = 0
    @State private var selectedActivityID: UUID?
    @State private var activityInspectorPresented = false
    @State private var activityInspectorPresentation: InspectorPresentation = .popover
    @State private var showingDNSReplacementConfirmation = false
    @State private var showingAppRoutingEnableConfirmation = false
    @State private var showingProxifierImporter = false
    @State private var proxifierImportPlan: ProxifierRuleImportPlan?
    @State private var proxifierImportError: String?
    @State private var profileScope: ProfileScope = .all

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                statusHeader
                    .fixedSize(horizontal: false, vertical: true)
                Divider()

                ZStack {
                    switch workspace {
                    case .rules:
                        rulesWorkspace
                    case .activity:
                        activityWorkspace
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if workspace == .rules, !visibleRules.isEmpty {
                    Divider()
                    actionBar
                        .frame(minHeight: 46)
                } else if workspace == .activity {
                    Divider()
                    activityActionBar
                        .frame(minHeight: 46)
                }
            }
            // GeometryReader supplies the finite detail-column dimensions.
            // Without this clamp, the empty state's flexible height can make
            // NavigationSplitView adopt an oversized ideal height and clip
            // both the sidebar rows and this page's fixed controls offscreen.
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear { updateActivityInspectorPresentation(for: geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in
                updateActivityInspectorPresentation(for: width)
            }
        }
        .navigationTitle("App Routing")
        .mclashPageSurface()
        .task(id: candidateRefreshRequest) {
            await refreshApplications(request: candidateRefreshRequest)
        }
        .task(id: activitySearchText) {
            do {
                try await Task.sleep(for: .milliseconds(180))
                debouncedActivitySearchText = activitySearchText
            } catch {
                return
            }
        }
        .onAppear {
            model.setAppRoutingActivityViewVisible(workspace == .activity)
            if workspace == .activity {
                scheduleActivityPresentationRefresh()
            }
        }
        .onDisappear {
            model.setAppRoutingActivityViewVisible(false)
            activityPresentationTask?.cancel()
            activityPresentationTask = nil
            activityPresentationGeneration &+= 1
        }
        .onChange(of: workspace) { _, workspace in
            model.setAppRoutingActivityViewVisible(workspace == .activity)
            if workspace != .activity {
                activityInspectorPresented = false
                activityPresentationTask?.cancel()
                activityPresentationTask = nil
                activityPresentationGeneration &+= 1
            } else {
                scheduleActivityPresentationRefresh()
            }
        }
        .onChange(of: model.appRoutingActivityPresentationRevision) { _, _ in
            scheduleActivityPresentationRefresh()
        }
        .onChange(of: debouncedActivitySearchText) { _, _ in
            scheduleActivityPresentationRefresh()
        }
        .onChange(of: profileScope) { _, _ in
            selectedActivityID = nil
            activityInspectorPresented = false
            scheduleActivityPresentationRefresh()
        }
        .sheet(isPresented: $showingEditor) {
            CaptureRuleEditorSheet(
                model: model,
                isPresented: $showingEditor,
                draft: $draft,
                applicationCandidates: applicationCandidates,
                processCandidates: processCandidates,
                mihomoGroupNames: model.proxyTopology.groupOrder,
                existingRuleIDs: Set(rules.map(\.id).filter { $0 != editingRuleID }),
                appliesImmediately: model.networkCapturePreferences.enabled
            ) { rule in
                save(rule)
            }
        }
        .sheet(item: $proxifierImportPlan) { plan in
            ProxifierRuleImportSheet(plan: plan) { importedRules in
                proxifierImportPlan = nil
                apply(rules + importedRules)
            }
        }
        .fileImporter(
            isPresented: $showingProxifierImporter,
            allowedContentTypes: [.proxifierProfile, .xml],
            allowsMultipleSelection: false,
            onCompletion: importProxifierProfile
        )
        .inspector(isPresented: attachedActivityInspectorBinding) {
            activityInspectorContent
                .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
        }
        .confirmationDialog(
            "Enable App Routing?",
            isPresented: $showingAppRoutingEnableConfirmation,
            titleVisibility: .visible
        ) {
            Button("Enable App Routing") {
                Task { await model.setNetworkCaptureEnabled(true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(appRoutingEnableConfirmationMessage)
        }
        .confirmationDialog(
            "Replace the current macOS DNS Proxy?",
            isPresented: $showingDNSReplacementConfirmation,
            titleVisibility: .visible
        ) {
            Button("Enable MClash DNS Routing") {
                Task { await model.setDNSCaptureEnabled(true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS allows one active DNS Proxy. Enabling MClash DNS Routing can replace Proxifier DNS or another DNS Proxy. MClash restores normal system DNS if its Provider fails, but it cannot recreate another app's private DNS configuration for you.")
        }
    }

    private var statusHeader: some View {
        ViewThatFits(in: .horizontal) {
            expandedStatusHeader
            compactStatusHeader
        }
    }

    private var expandedStatusHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Label(statusTitle, systemImage: statusSymbol)
                        .font(.headline)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                    Text(headerCount)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                workspacePicker

                statusHeaderControls
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, 8)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: compactStatusSymbol)
                    .foregroundStyle(compactStatusColor)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(compactStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(compactStatusHelp)
                Spacer(minLength: 12)
                compactStatusActions
            }
            .padding(.vertical, 7)
        }
        .padding(.horizontal, MClashLayout.pagePadding)
    }

    private var compactStatusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Label(statusTitle, systemImage: statusSymbol)
                    .font(.headline)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                statusHeaderControls
            }

            workspacePicker
                .frame(maxWidth: .infinity)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: compactStatusSymbol)
                    .foregroundStyle(compactStatusColor)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(compactStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(compactStatusHelp)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                compactStatusActions
            }
        }
        .padding(.horizontal, MClashLayout.pagePadding)
        .padding(.vertical, 8)
    }

    private var workspacePicker: some View {
        Picker("App Routing workspace", selection: $workspace) {
            ForEach(Workspace.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
    }

    private var statusHeaderControls: some View {
        HStack(spacing: 10) {
            Menu {
                Toggle("Include DNS with App Routing", isOn: dnsEnabled)
                Picker("Profile Scope", selection: $profileScope) {
                    Text("All Profiles").tag(ProfileScope.all)
                    Text("Default Profile").tag(ProfileScope.defaultProfile)
                    ForEach(model.profiles) { profile in
                        Text(profile.name)
                            .tag(ProfileScope.profile(profile.id))
                    }
                    Text("Direct / System").tag(ProfileScope.system)
                }
                Divider()
                if !model.operationalIssues.isEmpty {
                    Button("Open Attention") { model.selection = .attention }
                }
                Button("Open Logs") { model.selection = .logs }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("App Routing options")
            .accessibilityLabel(AppLocalization.string("App Routing options"))

            Toggle("Enabled", isOn: enabled)
                .toggleStyle(.switch)
                .disabled(
                    model.pendingNetworkCaptureEnabled != nil
                        || !model.canPerform(.changeNetworkCapture)
                )
        }
    }

    private var compactStatusMessage: String {
        if proxifierImportError != nil { return "The Proxifier profile could not be opened." }
        if editorError != nil { return "The last rule change could not be applied." }

        switch model.networkCaptureState {
        case .waitingForConnection:
            return "Rules are saved. Connect MClash to start routing."
        case .awaitingUserApproval:
            return "macOS approval is required before application traffic can be captured."
        case .requiresReboot:
            return "Restart this Mac to finish enabling the Network Extension."
        case .failed:
            return "App Routing could not start. Review Attention or retry."
        case .enabling:
            return "Starting application and DNS routing…"
        case .disabling:
            return "Stopping App Routing and restoring normal network handling…"
        case .off:
            return model.networkCapturePreferences.dnsEnabled
                ? "Rules are saved. DNS will start together with App Routing."
                : "Rules are saved. DNS is excluded in App Routing options."
        case .on:
            break
        }

        if model.dnsProxyRuntimeError != nil || model.dnsProxyAutomaticallyDisabled {
            return "Application traffic is active; DNS routing needs attention."
        }
        if model.appRoutingProviderLastVerifiedAt == nil {
            return "Traffic capture is starting; waiting for Provider verification."
        }
        if workspace == .activity {
            let active = model.appRoutingActiveCount
            return "\(formattedCount(active)) active · ↓ \(formattedActivityRate(model.appRoutingTrafficRates.measured.download)) · ↑ \(formattedActivityRate(model.appRoutingTrafficRates.measured.upload))"
        }
        return model.networkCapturePreferences.dnsEnabled
            ? "Application traffic and DNS are active through MClash."
            : "Application traffic is active; DNS remains with the system resolver."
    }

    private var compactStatusHelp: String {
        if let proxifierImportError { return proxifierImportError }
        if let editorError { return editorError }
        if case let .failed(message) = model.networkCaptureState { return message }
        if let dnsError = model.dnsProxyRuntimeError { return dnsError }
        return compactStatusMessage
    }

    private var compactStatusSymbol: String {
        if proxifierImportError != nil || editorError != nil { return "exclamationmark.triangle.fill" }
        if model.dnsProxyRuntimeError != nil || model.dnsProxyAutomaticallyDisabled {
            return "exclamationmark.triangle.fill"
        }
        return switch model.networkCaptureState {
        case .on: "checkmark.circle.fill"
        case .waitingForConnection: "pause.circle.fill"
        case .enabling, .disabling: "arrow.clockwise"
        case .awaitingUserApproval: "lock.shield.fill"
        case .requiresReboot: "restart.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .off: "circle"
        }
    }

    private var compactStatusColor: Color {
        if proxifierImportError != nil || editorError != nil { return .red }
        if model.dnsProxyRuntimeError != nil || model.dnsProxyAutomaticallyDisabled {
            return .orange
        }
        return statusColor
    }

    @ViewBuilder
    private var compactStatusActions: some View {
        Group {
            if proxifierImportError != nil {
                Button("Dismiss") { proxifierImportError = nil }
            } else if editorError != nil {
                Button("Dismiss") { editorError = nil }
            } else if model.dnsProxyRuntimeError != nil || model.dnsProxyAutomaticallyDisabled {
                HStack(spacing: 6) {
                    Button("Retry DNS") {
                        Task { await model.retryDNSCaptureActivation() }
                    }
                    Button("Attention") { model.selection = .attention }
                }
            } else {
                switch model.networkCaptureState {
                case .waitingForConnection:
                    Button("Connect") { Task { await model.connect() } }
                        .disabled(!model.canPerform(.connection))
                case .awaitingUserApproval:
                    Button("Open Settings") { SMAppService.openSystemSettingsLoginItems() }
                case .failed:
                    HStack(spacing: 6) {
                        Button("Retry") {
                            Task { await model.retryNetworkCaptureActivation() }
                        }
                        Button("Attention") { model.selection = .attention }
                    }
                case .requiresReboot:
                    Button("Attention") { model.selection = .attention }
                case .off, .enabling, .on, .disabling:
                    Color.clear
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var dnsEnabled: Binding<Bool> {
        Binding(
            get: {
                model.networkCapturePreferences.dnsEnabled
            },
            set: { value in
                if value && model.networkCapturePreferences.enabled {
                    showingDNSReplacementConfirmation = true
                } else {
                    Task { await model.setDNSCaptureEnabled(value) }
                }
            }
        )
    }

    private var rulesTable: some View {
        return Table(visibleRules, selection: $selectedRuleID) {
            TableColumn("") { rule in
                Button {
                    setEnabled(!rule.enabled, for: rule)
                } label: {
                    Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(rule.enabled ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
                .help(rule.enabled ? "Disable rule" : "Enable rule")
                .accessibilityLabel(rule.enabled ? "Disable \(rule.id)" : "Enable \(rule.id)")
            }
            .width(30)

            TableColumn("Rule") { rule in
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.id)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(sourceSummary(rule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .onTapGesture(count: 2) { edit(rule) }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { edit(rule) }
            }
            .width(min: 190, ideal: 300)

            TableColumn("Match") { rule in
                VStack(alignment: .leading, spacing: 2) {
                    Text(destinationSummary(rule))
                        .lineLimit(1)
                    Text(transportSummary(rule))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .foregroundStyle(rule.enabled ? Color.primary : Color.secondary)
            }
            .width(min: 170, ideal: 260)

            TableColumn("Route") { rule in
                Text(actionSummary(rule.action))
                    .lineLimit(1)
                    .foregroundStyle(actionColor(rule.action))
            }
            .width(min: 100, ideal: 150)
        }
        .contextMenu(forSelectionType: String.self) { selection in
            if let id = selection.first,
               let rule = visibleRules.first(where: { $0.id == id }) {
                Button("Edit…") { edit(rule) }
                Button("Duplicate") { clone(rule) }
                Divider()
                Button("Delete", role: .destructive) { remove(rule) }
            }
        } primaryAction: { selection in
            if let id = selection.first,
               let rule = visibleRules.first(where: { $0.id == id }) {
                edit(rule)
            }
        }
        .onDeleteCommand { removeSelectedRule() }
        .onKeyPress(.return) {
            guard let selectedRule else { return .ignored }
            edit(selectedRule)
            return .handled
        }
    }

    private var rulesWorkspace: some View {
        VStack(spacing: 0) {
            effectivePolicyBar
            Divider()
            if visibleRules.isEmpty {
                emptyState
            } else {
                rulesTable
            }
        }
    }

    private var effectivePolicyBar: some View {
        HStack(spacing: 8) {
            Text("Effective Policy")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if enabledRuleCount == 0 {
                Label("Applications Direct", systemImage: "arrow.right.circle")
                    .font(.callout.weight(.medium))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(dnsPolicyTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(enabledRuleCount) enabled \(enabledRuleCount == 1 ? "rule" : "rules")")
                    .font(.callout.weight(.medium))
                Text("· First match wins · \(dnsPolicyTitle)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
        }
        .frame(height: 44)
        .padding(.horizontal, MClashLayout.pagePadding)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var activityWorkspace: some View {
        let visibleActivities = activityPresentation.visibleActivities
        if activityPresentation.activeCount == 0 {
            ContentUnavailableView(
                "No Active App Routing Connections",
                systemImage: "network.slash",
                description: Text(activityEmptyDescription)
            )
        } else if visibleActivities.isEmpty {
            ContentUnavailableView.search(text: activitySearchText)
        } else {
            activityTable(visibleActivities)
        }
    }

    private func activityTable(_ activities: [AppRoutingActivity]) -> some View {
        Table(activities, selection: $selectedActivityID) {
            TableColumn("Application / Process") { activity in
                VStack(alignment: .leading, spacing: 2) {
                    Text(activityApplicationName(activity))
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            inspectActivity(activity)
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { inspectActivity(activity) }
                    Text("PID \(activity.source.processIdentifier)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help(activity.source.executablePath ?? activityApplicationName(activity))
            }
            .width(min: 145, ideal: 200)

            TableColumn("Target") { activity in
                VStack(alignment: .leading, spacing: 2) {
                    Text(activityDestination(activity))
                        .lineLimit(1)
                    Text(activityDestinationDetail(activity))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help(activityDestination(activity))
            }
            .width(min: 145, ideal: 210)

            TableColumn("Route") { activity in
                VStack(alignment: .leading, spacing: 2) {
                    Text(activityRoute(activity))
                        .lineLimit(1)
                    Label(
                        activityResult(activity),
                        systemImage: activityResultSymbol(activity)
                    )
                        .font(.caption)
                        .foregroundStyle(activityResultColor(activity))
                        .lineLimit(1)
                }
                .help(activity.relayError ?? activity.relayNote ?? activityCause(activity))
            }
            .width(min: 150, ideal: 220)

            TableColumn("Current Speed") { activity in
                activitySpeed(activity)
            }
            .width(min: 104, ideal: 122)
        }
        .contextMenu(forSelectionType: UUID.self) { selection in
            if let id = selection.first,
               let activity = activities.first(where: { $0.flowIdentifier == id }) {
                Button("Inspect") { inspectActivity(activity) }
            }
        } primaryAction: { selection in
            if let id = selection.first,
               let activity = activities.first(where: { $0.flowIdentifier == id }) {
                inspectActivity(activity)
            }
        }
        .onChange(of: selectedActivityID) { _, identifier in
            if identifier == nil { activityInspectorPresented = false }
        }
        .onKeyPress(.return) {
            guard let selectedActivity else { return .ignored }
            inspectActivity(selectedActivity)
            return .handled
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "app.badge")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.secondary)
            Text("No App Routing Rules")
                .font(.title3.weight(.semibold))
            Text("Add an application, process, domain, IP, or port rule to choose how its traffic is handled.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Add First Rule…") { addRule() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPerform(.changeNetworkCapture))
            Button {
                proxifierImportError = nil
                showingProxifierImporter = true
            } label: {
                Label("Import Proxifier Profile…", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.bordered)
            .disabled(!model.canPerform(.changeNetworkCapture))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button(action: addRule) {
                Label("Add Rule…", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)

            if selectedRule != nil {
                Button("Edit…", action: editSelectedRule)
            }

            Spacer()

            Menu {
                Button {
                    proxifierImportError = nil
                    showingProxifierImporter = true
                } label: {
                    Label("Import Proxifier Profile…", systemImage: "arrow.down.doc")
                }

                if selectedRule != nil {
                    Divider()
                    Button("Duplicate", action: cloneSelectedRule)
                    Button("Move Up", action: { moveSelectedRule(by: -1) })
                        .disabled(!canMoveSelectedRule(by: -1))
                    Button("Move Down", action: { moveSelectedRule(by: 1) })
                        .disabled(!canMoveSelectedRule(by: 1))
                    Divider()
                    Button("Delete Rule", role: .destructive, action: removeSelectedRule)
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .help("More App Routing rule actions")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, MClashLayout.pagePadding)
        .frame(minHeight: 46)
        .disabled(!model.canPerform(.changeNetworkCapture))
    }

    private var activityActionBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter app, target, rule, or route", text: $activitySearchText)
                .textFieldStyle(.plain)
                .frame(maxWidth: 360)

            Spacer()

            if let error = model.appRoutingActivityError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
            } else {
                switch model.liveStreamHealth[.appRouting]?.phase ?? .inactive {
                case .live:
                    Text("Live connections · updates automatically")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .connecting:
                    Text("Waiting for the first provider response…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .reconnecting:
                    Text("Provider reconnecting…")
                        .font(.caption)
                        .foregroundStyle(.orange)
                case .stale:
                    Text("Provider data is stale")
                        .font(.caption)
                        .foregroundStyle(.red)
                case .inactive:
                    Text("Provider inactive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                activityInspectorPresented.toggle()
            } label: {
                Label("Inspect", systemImage: "sidebar.right")
            }
            .disabled(selectedActivity == nil)
            .help(activityInspectorPresented ? "Hide activity details" : "Show activity details")
            .popover(isPresented: popoverActivityInspectorBinding, arrowEdge: .top) {
                activityInspectorContent
                    .frame(width: 380, height: 520)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, MClashLayout.pagePadding)
        .padding(.vertical, 12)
    }

    private var headerCount: String {
        switch workspace {
        case .rules:
            "· \(enabledRuleCount) enabled"
        case .activity:
            if activityPresentation.visibleActivities.count == activityPresentation.activeCount {
                "· \(activityPresentation.activeCount) active"
            } else {
                "· \(activityPresentation.visibleActivities.count) shown · \(activityPresentation.activeCount) active"
            }
        }
    }

    private var activityEmptyDescription: String {
        switch model.networkCaptureState {
        case .on:
            "Start using an application routed through Mihomo. Provider-owned TCP and UDP connections stay here until they close. Ordinary Direct traffic returns to macOS immediately, so its lifetime and speed cannot be observed."
        default:
            "Enable App Routing and connect MClash to see live provider-owned connections."
        }
    }

    private var selectedActivity: AppRoutingActivity? {
        guard let selectedActivityID else { return nil }
        return activityPresentation.activitiesByIdentifier[selectedActivityID]
    }

    private func inspectActivity(_ activity: AppRoutingActivity) {
        selectedActivityID = activity.flowIdentifier
        activityInspectorPresented = true
    }

    @ViewBuilder
    private var activityInspectorContent: some View {
        if let activity = selectedActivity {
            AppRoutingFlowInspector(
                activity: activity,
                ledgerEntry: model.appRoutingFlowEntries[activity.flowIdentifier]
            )
        } else {
            ContentUnavailableView(
                "Select an activity",
                systemImage: "sidebar.right",
                description: Text("Choose a flow to inspect every routing stage.")
            )
        }
    }

    private var attachedActivityInspectorBinding: Binding<Bool> {
        Binding(
            get: {
                activityInspectorPresented && activityInspectorPresentation == .attached
            },
            set: { presented in
                guard activityInspectorPresentation == .attached else { return }
                activityInspectorPresented = presented
            }
        )
    }

    private var popoverActivityInspectorBinding: Binding<Bool> {
        Binding(
            get: {
                activityInspectorPresented && activityInspectorPresentation == .popover
            },
            set: { presented in
                guard activityInspectorPresentation == .popover else { return }
                activityInspectorPresented = presented
            }
        )
    }

    private func updateActivityInspectorPresentation(for width: CGFloat) {
        guard width > 0 else { return }
        let reconstructedFullWidth = width
            + (activityInspectorPresented && activityInspectorPresentation == .attached ? 360 : 0)
        let next = activityInspectorPresentation.presentation(
            forFullWidth: reconstructedFullWidth
        )
        if next != activityInspectorPresentation {
            activityInspectorPresentation = next
        }
    }

    private func scheduleActivityPresentationRefresh() {
        guard workspace == .activity else { return }
        activityPresentationTask?.cancel()
        activityPresentationGeneration &+= 1
        let generation = activityPresentationGeneration
        let activities = model.appRoutingActivities
        let flowEntries = model.appRoutingFlowEntries
        let target = profileScope.trafficTarget
        let searchText = debouncedActivitySearchText

        activityPresentationTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                AppRoutingActivityPresentationSnapshot(
                    activities: activities,
                    flowEntries: flowEntries,
                    target: target,
                    searchText: searchText
                )
            }
            let next = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  activityPresentationGeneration == generation else { return }
            activityPresentation = next
            activityPresentationTask = nil
            if let selectedActivityID,
               !next.visibleIdentifiers.contains(selectedActivityID) {
                self.selectedActivityID = nil
                activityInspectorPresented = false
            }
        }
    }

    private func activityApplicationName(_ activity: AppRoutingActivity) -> String {
        if let path = activity.source.executablePath, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        if let bundle = activity.source.bundleIdentifier, !bundle.isEmpty { return bundle }
        if let signing = activity.source.signingIdentifier, !signing.isEmpty { return signing }
        return activity.source.processIdentifier > 0
            ? "Process \(activity.source.processIdentifier)"
            : "Unknown process"
    }

    private func activityDestination(_ activity: AppRoutingActivity) -> String {
        let host = activity.destination.hostname
            ?? activity.destination.ipAddress
            ?? "Unknown destination"
        return activity.destination.port > 0 ? "\(host):\(activity.destination.port)" : host
    }

    private func activityDestinationDetail(_ activity: AppRoutingActivity) -> String {
        let transport = activity.transportProtocol.rawValue.uppercased()
        guard let address = activity.destination.ipAddress,
              address.caseInsensitiveCompare(activity.destination.hostname ?? "") != .orderedSame
        else { return transport }
        return "\(transport) · \(address)"
    }

    private func activityCause(_ activity: AppRoutingActivity) -> String {
        switch activity.cause {
        case .captureDisabled: "Capture disabled"
        case .configurationUnavailable: "Configuration unavailable"
        case .contextUnavailable: "Identity unavailable"
        case let .rule(cause), let .mihomoUnavailable(cause, _):
            switch cause {
            case let .matchedRule(identifier): identifier
            case let .builtInBypass(reason): "Built-in: \(reason.rawValue)"
            case .defaultDirect: "Default direct"
            }
        }
    }

    private func activityRoute(_ activity: AppRoutingActivity) -> String {
        switch activity.effectiveAction {
        case .direct:
            return activity.configuredAction == .direct ? "Direct" : "Direct fallback"
        case .reject:
            return "Rejected"
        case .failOpen:
            return "Fail-open"
        case let .mihomo(route):
            let target = switch route.profileRoute {
            case .rules: "Rules"
            case .global: "Global"
            case let .group(group): group
            }
            guard let profileID = route.routingProfileID else {
                return "Mihomo \(target)"
            }
            let name = model.profiles.first {
                $0.id.rawValue == profileID.uuid
            }?.name ?? AppLocalization.string("Unavailable profile")
            return "\(name) · \(target)"
        }
    }

    private var scopedAppRoutingActivities: [AppRoutingActivity] {
        guard let target = profileScope.trafficTarget else {
            return model.appRoutingActivities
        }
        return model.appRoutingActivities.filter {
            $0.mclashTrafficTarget == target
        }
    }

    private var scopedRuleStatistics: [String: AppModel.AppRoutingRuleStatistics] {
        guard profileScope != .all else {
            return model.appRoutingRuleStatistics
        }
        return scopedAppRoutingActivities.reduce(into: [:]) { result, activity in
            guard let identifier = activity.matchedRuleIdentifier else { return }
            var value = result[identifier] ?? .zero
            value.matchCount += 1
            if activity.isLiveManagedFlow { value.activeCount += 1 }
            if activity.relayState == .failed { value.failureCount += 1 }
            value.lastMatchedAt = max(
                value.lastMatchedAt ?? .distantPast,
                activity.startedAt
            )

            let isMeasured: Bool = switch activity.effectiveAction {
            case .mihomo, .reject: true
            case .direct: activity.payloadBytesAreMeasured == true
            case .failOpen: false
            }
            if isMeasured {
                value.measuredBytes = addingWithoutOverflow(
                    value.measuredBytes,
                    activity.uploadBytes
                )
                value.measuredBytes = addingWithoutOverflow(
                    value.measuredBytes,
                    activity.downloadBytes
                )
            } else {
                value.unmeasuredCount += 1
            }
            result[identifier] = value
        }
    }

    private func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private var scopedTrafficRate: AppRoutingByteRate {
        switch profileScope {
        case .all:
            return model.appRoutingTrafficRates.measured
        case .defaultProfile:
            return model.appRoutingTrafficRates.defaultProfile
        case let .profile(profileID):
            return model.appRoutingTrafficRates.byProfile[profileID]
                ?? AppRoutingByteRate()
        case .system:
            return model.appRoutingTrafficRates.direct
        }
    }

    private func pathBelongsToSelectedProfile(_ path: AppRoutingTrafficPath) -> Bool {
        switch profileScope {
        case .all:
            true
        case .defaultProfile:
            if case let .mihomo(route) = path {
                route.mclashTrafficTarget == .defaultProfile
            } else {
                false
            }
        case let .profile(profileID):
            if case let .mihomo(route) = path {
                route.mclashTrafficTarget == .profile(profileID)
            } else {
                false
            }
        case .system:
            if case .mihomo = path { false } else { true }
        }
    }

    private func activityProfileTitle(_ activity: AppRoutingActivity) -> String {
        switch activity.mclashTrafficTarget {
        case .defaultProfile:
            "Default Profile"
        case let .profile(profileID):
            model.profiles.first(where: { $0.id == profileID })?.name
                ?? "Unavailable"
        case .system:
            "Direct / System"
        }
    }

    private func activityResult(_ activity: AppRoutingActivity) -> String {
        if activity.relayState == .failed { return "Relay failed" }
        return switch activity.effectiveAction {
        case .direct where activity.payloadBytesAreMeasured == true:
            switch activity.relayState {
            case .pending, .connecting: "Direct connecting"
            case .ready: "Direct ready"
            case .relaying: "Direct relaying"
            case .completed: "Direct complete"
            case .notApplicable: "Direct"
            case .failed: "Relay failed"
            }
        case .direct: "Direct pass-through"
        case .reject: "Rejected"
        case .failOpen: "Fail-open"
        case .mihomo: switch activity.relayState {
            case .pending, .connecting: "Connecting"
            case .ready: "Mihomo ready"
            case .relaying:
                if routeIsConfirmed(activity) {
                    "Route confirmed"
                } else if routeIsProbable(activity) {
                    "Probable Mihomo match"
                } else if (activity.downloadDatagrams ?? 0) > 0 {
                    "Response observed"
                } else {
                    "Sent to Mihomo"
                }
            case .completed:
                if routeIsConfirmed(activity) {
                    "Route confirmed"
                } else if routeIsProbable(activity) {
                    "Probable Mihomo match"
                } else {
                    "Mihomo complete"
                }
            case .failed: "Relay failed"
            case .notApplicable: "Mihomo"
            }
        }
    }

    private func activityResultSymbol(_ activity: AppRoutingActivity) -> String {
        if activity.relayState == .failed { return "exclamationmark.triangle.fill" }
        return switch activity.effectiveAction {
        case .direct: "arrow.right"
        case .reject: "xmark.octagon.fill"
        case .failOpen: "arrow.uturn.right"
        case .mihomo: "point.3.connected.trianglepath.dotted"
        }
    }

    private func activityResultColor(_ activity: AppRoutingActivity) -> Color {
        if activity.relayState == .failed { return .red }
        return switch activity.effectiveAction {
        case .direct: .secondary
        case .reject: .red
        case .failOpen: .orange
        case .mihomo: .accentColor
        }
    }

    private func mihomoPath(_ activity: AppRoutingActivity) -> String {
        guard case .mihomo = activity.effectiveAction else { return "—" }
        guard let entry = model.appRoutingFlowEntries[activity.flowIdentifier],
              let route = entry.mihomoRoute else {
            if activity.relayState == .failed { return "Relay failed" }
            if (activity.downloadDatagrams ?? 0) > 0 {
                return "Response observed · node path not yet matched"
            }
            if (activity.uploadDatagrams ?? 0) > 0 || activity.uploadBytes > 0 {
                return "Sent to Mihomo · awaiting /connections confirmation"
            }
            return "Waiting for Mihomo metadata"
        }
        let rule = [route.rule, route.rulePayload]
            .compactMap { $0 }
            .joined(separator: " · ")
        let chain = route.chain.joined(separator: " → ")
        var components = [rule, chain].filter { !$0.isEmpty }
        if case let .destinationAndStartTime(_, difference) = entry.association {
            components.insert(
                "Probable · destination/time Δ\(difference.formatted(.number.precision(.fractionLength(2))))s",
                at: 0
            )
        }
        return components.joined(separator: " · ")
    }

    private func routeIsConfirmed(_ activity: AppRoutingActivity) -> Bool {
        FlowLedgerAssociationPresentation.isConfirmed(
            model.appRoutingFlowEntries[activity.flowIdentifier]?.association
        )
    }

    private func routeIsProbable(_ activity: AppRoutingActivity) -> Bool {
        FlowLedgerAssociationPresentation.isProbable(
            model.appRoutingFlowEntries[activity.flowIdentifier]?.association
        )
    }

    @ViewBuilder
    private func activitySpeed(_ activity: AppRoutingActivity) -> some View {
        let rate = model.appRoutingTrafficRates.byFlow[activity.flowIdentifier]
            ?? AppRoutingByteRate()
        VStack(alignment: .trailing, spacing: 2) {
            Text("↓ \(formattedActivityRate(rate.download))")
            Text("↑ \(formattedActivityRate(rate.upload))")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(rate.total > 0 ? Color.primary : Color.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Download \(formattedActivityRate(rate.download)), upload \(formattedActivityRate(rate.upload))"
        )
    }

    @ViewBuilder
    private func activityTraffic(_ activity: AppRoutingActivity) -> some View {
        let entry = model.appRoutingFlowEntries[activity.flowIdentifier]
        switch entry?.upload ?? fallbackUploadMeasurement(activity) {
        case .notMeasuredAfterHandoff:
            Label("Not measured", systemImage: "arrow.uturn.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("MClash recorded the decision, then handed the flow back to macOS. Payload bytes are not observable after handoff.")
        case .notApplicable:
            Text("No payload")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("The flow was rejected before application payload was relayed.")
        case .exact:
            VStack(alignment: .trailing, spacing: 2) {
                Text("↓ \(formattedActivityBytes(activity.downloadBytes))")
                Text("↑ \(formattedActivityBytes(activity.uploadBytes))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func fallbackUploadMeasurement(
        _ activity: AppRoutingActivity
    ) -> FlowLedgerByteMeasurement {
        switch activity.effectiveAction {
        case .direct where activity.payloadBytesAreMeasured == true:
            .exact(activity.uploadBytes)
        case .direct, .failOpen: .notMeasuredAfterHandoff
        case .reject: .notApplicable
        case .mihomo: .exact(activity.uploadBytes)
        }
    }

    private func formattedActivityBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private func formattedActivityRate(_ bytesPerSecond: UInt64) -> String {
        "\(formattedActivityBytes(bytesPerSecond))/s"
    }

    private func formattedActivityCount(_ value: UInt64) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func appRoutingTrafficPathTitle(_ path: AppRoutingTrafficPath) -> String {
        switch path {
        case .direct: "Direct"
        case .failOpen: "Fail Open"
        case .rejected: "Rejected"
        case .mihomo(.profileRules): "Mihomo Rules"
        case .mihomo(.global): "Mihomo GLOBAL"
        case let .mihomo(.group(group)): group
        case let .mihomo(.profile(profileID, target)):
            "\(routingProfileName(profileID)) · \(profileRouteTitle(target))"
        }
    }

    private var rules: [CaptureRule] {
        model.networkCapturePreferences.snapshot.rules
    }

    private var orderedRules: [CaptureRule] {
        rules.enumerated().sorted { lhs, rhs in
            if lhs.element.priority != rhs.element.priority {
                return lhs.element.priority < rhs.element.priority
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private var visibleRules: [CaptureRule] {
        guard let target = profileScope.trafficTarget else { return orderedRules }
        return orderedRules.filter {
            $0.action.mclashTrafficTarget == target
        }
    }

    private var enabledRuleCount: Int {
        visibleRules.lazy.filter(\.enabled).count
    }

    private var dnsPolicyTitle: String {
        model.networkCapturePreferences.dnsEnabled ? "DNS On" : "DNS Off"
    }

    private func formattedRuleTraffic(_ bytes: UInt64, partial: Bool) -> String {
        let value = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .file
        )
        return partial ? "\(value)+" : value
    }

    private func ruleTrafficHelp(_ statistics: AppModel.AppRoutingRuleStatistics) -> String {
        guard statistics.unmeasuredCount > 0 else {
            return "Exact payload bytes observed for this rule in the current app session."
        }
        return "\(formattedRuleTraffic(statistics.measuredBytes, partial: false)) measured, plus \(formattedCount(statistics.unmeasuredCount)) pass-through flows whose payload was not observable."
    }

    private var selectedRule: CaptureRule? {
        guard let selectedRuleID else { return nil }
        return visibleRules.first(where: { $0.id == selectedRuleID })
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: {
                model.pendingNetworkCaptureEnabled
                    ?? model.networkCapturePreferences.enabled
            },
            set: { value in
                if value {
                    showingAppRoutingEnableConfirmation = true
                } else {
                    Task { await model.setNetworkCaptureEnabled(false) }
                }
            }
        )
    }

    private var appRoutingEnableConfirmationMessage: String {
        var effects = [
            "MClash will restart the Mihomo core, which can close current connections.",
            "macOS may ask you to approve the MClash Network Filter."
        ]
        if model.networkCapturePreferences.dnsEnabled {
            effects.append(
                "DNS Routing will start at the same time and can replace Proxifier DNS or another active macOS DNS Proxy."
            )
        } else {
            effects.append(
                "DNS Routing is excluded by the Advanced DNS Routing setting."
            )
        }
        if model.systemProxyEnabled {
            effects.insert(
                "The currently enabled MClash System Proxy will be turned off because the two capture modes are mutually exclusive.",
                at: 0
            )
        }
        return effects.joined(separator: " ")
    }

    private var statusTitle: String {
        switch model.networkCaptureState {
        case .waitingForConnection:
            return "App Routing Waiting for Connection"
        case .awaitingUserApproval:
            return "System Approval Required"
        case .requiresReboot:
            return "Restart Required"
        case .failed:
            return "App Routing Needs Attention"
        case .off, .enabling, .on, .disabling:
            break
        }
        if let pending = model.pendingNetworkCaptureEnabled {
            return pending ? "Starting App Routing" : "Stopping App Routing"
        }
        return switch model.networkCaptureState {
        case .off: "App Routing Off"
        case .waitingForConnection: "App Routing Waiting for Connection"
        case .enabling: "Starting App Routing"
        case .awaitingUserApproval: "System Approval Required"
        case let .on(revision): "App Routing On · revision \(revision)"
        case .disabling: "Stopping App Routing"
        case .requiresReboot: "Restart Required"
        case .failed: "App Routing Needs Attention"
        }
    }

    private var statusSymbol: String {
        switch model.networkCaptureState {
        case .on: "checkmark.circle.fill"
        case .waitingForConnection: "pause.circle.fill"
        case .enabling, .disabling: "clock.arrow.circlepath"
        case .awaitingUserApproval: "lock.shield.fill"
        case .requiresReboot: "restart.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .off: "circle"
        }
    }

    private var statusColor: Color {
        switch model.networkCaptureState {
        case .on: .green
        case .waitingForConnection: .secondary
        case .enabling, .disabling: .accentColor
        case .awaitingUserApproval: .orange
        case .requiresReboot: .orange
        case .failed: .red
        case .off: .secondary
        }
    }

    private var nextPriority: Int {
        let maximum = rules.map(\.priority).max() ?? 0
        let (candidate, overflow) = maximum.addingReportingOverflow(10)
        return overflow ? Int.max : candidate
    }

    private func addRule() {
        requestApplicationRefresh()
        editingRuleID = nil
        selectedRuleID = nil
        draft = CaptureRuleDraft(
            identifier: uniqueRuleName("New Rule"),
            priority: nextPriority,
            action: profileScope == .system ? .direct : .mihomoProfileRules,
            routingProfileID: {
                guard case let .profile(profileID) = profileScope else {
                    return nil
                }
                return profileID
            }()
        )
        editorError = nil
        showingEditor = true
    }

    private func editSelectedRule() {
        guard let selectedRule else { return }
        edit(selectedRule)
    }

    private func edit(_ rule: CaptureRule) {
        requestApplicationRefresh()
        do {
            draft = try CaptureRuleDraft(
                rule: rule,
                applicationCandidates: applicationCandidates,
                processCandidates: processCandidates
            )
            editingRuleID = rule.id
            selectedRuleID = rule.id
            editorError = nil
            showingEditor = true
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func cloneSelectedRule() {
        guard let selectedRule else { return }
        clone(selectedRule)
    }

    private func clone(_ rule: CaptureRule) {
        requestApplicationRefresh()
        do {
            var copy = try CaptureRuleDraft(
                rule: rule,
                applicationCandidates: applicationCandidates,
                processCandidates: processCandidates
            )
            copy.identifier = uniqueRuleName("\(rule.id) Copy")
            copy.priority = nextPriority
            copy.enabled = true
            draft = copy
            editingRuleID = nil
            selectedRuleID = nil
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
        selectedRuleID = rule.id
        apply(updated)
    }

    private func removeSelectedRule() {
        guard let selectedRule else { return }
        remove(selectedRule)
    }

    private func remove(_ rule: CaptureRule) {
        selectedRuleID = nil
        apply(rules.filter { $0.id != rule.id })
    }

    private func setEnabled(_ enabled: Bool, for rule: CaptureRule) {
        do {
            let replacement = try copy(rule, enabled: enabled)
            apply(rules.map { $0.id == rule.id ? replacement : $0 })
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func canMoveSelectedRule(by offset: Int) -> Bool {
        guard profileScope == .all else { return false }
        guard let selectedRuleID,
              let index = orderedRules.firstIndex(where: { $0.id == selectedRuleID }) else {
            return false
        }
        return orderedRules.indices.contains(index + offset)
    }

    private func moveSelectedRule(by offset: Int) {
        guard profileScope == .all else { return }
        guard let selectedRuleID,
              let index = orderedRules.firstIndex(where: { $0.id == selectedRuleID }),
              orderedRules.indices.contains(index + offset) else {
            return
        }
        var reordered = orderedRules
        let rule = reordered.remove(at: index)
        reordered.insert(rule, at: index + offset)
        do {
            let renumbered = try reordered.enumerated().map { position, rule in
                try copy(rule, priority: (position + 1) * 10)
            }
            apply(renumbered)
        } catch {
            editorError = error.localizedDescription
        }
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

    private func copy(
        _ rule: CaptureRule,
        enabled: Bool? = nil,
        priority: Int? = nil
    ) throws -> CaptureRule {
        try CaptureRule(
            id: rule.id,
            enabled: enabled ?? rule.enabled,
            priority: priority ?? rule.priority,
            sources: rule.sources,
            destinations: rule.destinations,
            protocols: rule.protocols,
            portRanges: rule.portRanges,
            action: rule.action,
            unavailableFallback: rule.unavailableFallback
        )
    }

    private func uniqueRuleName(_ base: String) -> String {
        let existingNames = Set(rules.map(\.id))
        if !existingNames.contains(base) { return base }
        var suffix = 2
        while existingNames.contains("\(base) \(suffix)") {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private func requestApplicationRefresh() {
        candidateRefreshRequest &+= 1
    }

    private func importProxifierProfile(_ result: Result<[URL], Error>) {
        switch result {
        case let .failure(error):
            proxifierImportError = error.localizedDescription
        case let .success(urls):
            guard let url = urls.first else { return }
            let canAccess = url.startAccessingSecurityScopedResource()
            defer {
                if canAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                let sourceName = url.lastPathComponent
                let existingRules = rules
                Task {
                    do {
                        let plan = try await Task.detached(priority: .userInitiated) {
                            try ProxifierRuleImporter().makePlan(
                                data: data,
                                sourceName: sourceName,
                                existingRules: existingRules
                            )
                        }.value
                        proxifierImportError = nil
                        proxifierImportPlan = plan
                    } catch {
                        proxifierImportError = error.localizedDescription
                    }
                }
            } catch {
                proxifierImportError = error.localizedDescription
            }
        }
    }

    private func refreshApplications(request: Int) async {
        let candidates = await ApplicationCaptureCandidateProvider().loadRunningCandidates()
        guard !Task.isCancelled, request == candidateRefreshRequest else { return }
        applicationCandidates = candidates.applications
        processCandidates = candidates.processes
    }

    private func sourceSummary(_ rule: CaptureRule) -> String {
        guard !rule.sources.isEmpty else { return "Any application" }
        return rule.sources.map { source in
            switch source {
            case let .application(application):
                application.bundleIdentifier
                    ?? application.signingIdentifier
                    ?? "Signed application"
            case let .applicationIdentifierPattern(application):
                application.pattern
            case let .executable(executable):
                URL(fileURLWithPath: executable.canonicalPath).lastPathComponent
            case let .processInstance(process):
                "PID \(process.processIdentifier) · this run"
            case let .userID(userID):
                "User \(userID)"
            }
        }.joined(separator: ", ")
    }

    private func destinationSummary(_ rule: CaptureRule) -> String {
        guard !rule.destinations.isEmpty else { return "Any target" }
        return rule.destinations.map { destination in
            switch destination {
            case let .ip(address): address.presentation
            case let .network(network): network.presentation
            case let .host(host):
                host.kind == .suffix ? "*.\(host.value)" : host.value
            case let .hostPattern(pattern):
                pattern.pattern
            }
        }.joined(separator: ", ")
    }

    private func transportSummary(_ rule: CaptureRule) -> String {
        let protocols = rule.protocols.isEmpty
            ? "TCP + UDP"
            : rule.protocols.map { $0.rawValue.uppercased() }.sorted().joined(separator: " + ")
        guard !rule.portRanges.isEmpty else { return "\(protocols) · Any" }
        let ports = rule.portRanges.map { range in
            range.lowerBound == range.upperBound
                ? String(range.lowerBound)
                : "\(range.lowerBound)-\(range.upperBound)"
        }.joined(separator: ", ")
        return "\(protocols) · \(ports)"
    }

    private func actionSummary(_ action: CaptureAction) -> String {
        switch action {
        case .direct: "Direct"
        case .reject: "Reject"
        case .mihomo(.profileRules): "Mihomo Rules"
        case .mihomo(.global): "Mihomo Global"
        case let .mihomo(.group(group)): group
        case let .mihomo(.profile(profileID, target)):
            "\(routingProfileName(profileID)) · \(profileRouteTitle(target))"
        }
    }

    private func routingProfileName(_ profileID: RoutingProfileID) -> String {
        model.profiles.first {
            $0.id.rawValue == profileID.uuid
        }?.name ?? AppLocalization.string("Unavailable profile")
    }

    private func profileRouteTitle(_ route: MihomoProfileRoute) -> String {
        switch route {
        case .rules: "Rules"
        case .global: "Global"
        case let .group(group): group
        }
    }

    private func actionColor(_ action: CaptureAction) -> Color {
        switch action {
        case .direct: .secondary
        case .reject: .red
        case .mihomo: .accentColor
        }
    }
}

private struct AppRoutingFlowInspector: View {
    let activity: AppRoutingActivity
    let ledgerEntry: FlowLedgerEntry?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(applicationName)
                    .font(.headline)
                    .lineLimit(1)
                Text(destination)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    inspectorSection("Route Pipeline") {
                        pipelineStage("Application", value: applicationName, symbol: "app")
                        pipelineStage(
                            "Capture",
                            value: activity.effectiveCaptureOrigin == .dnsProxy
                                ? "DNS Proxy"
                                : "App Routing",
                            symbol: "network.badge.shield.half.filled"
                        )
                        pipelineStage(
                            "App Rule",
                            value: activity.matchedRuleIdentifier ?? "Built-in / default decision",
                            symbol: "list.number"
                        )
                        pipelineStage(
                            "App Decision",
                            value: outcomeTitle,
                            symbol: outcomeSymbol
                        )
                        if let route = ledgerEntry?.mihomoRoute {
                            pipelineStage(
                                "Mihomo Match",
                                value: mihomoAssociationTitle,
                                symbol: routeIsConfirmed
                                    ? "checkmark.seal.fill"
                                    : "questionmark.diamond.fill"
                            )
                            pipelineStage(
                                "Mihomo Rule",
                                value: [route.rule, route.rulePayload]
                                    .compactMap { $0 }
                                    .joined(separator: " · "),
                                symbol: "list.bullet.rectangle"
                            )
                            pipelineStage(
                                "Proxy Path",
                                value: route.chain.isEmpty
                                    ? "No proxy chain reported"
                                    : route.chain.joined(separator: " → "),
                                symbol: "point.3.connected.trianglepath.dotted"
                            )
                        } else if case .mihomo = activity.effectiveAction {
                            pipelineStage(
                                "Mihomo Metadata",
                                value: mihomoEvidenceTitle,
                                symbol: mihomoEvidenceSymbol
                            )
                        }
                        pipelineStage("Destination", value: destination, symbol: "scope")
                    }

                    let ruleEvidence = AppRoutingRuleEvidencePresentation.make(for: activity)
                    inspectorSection("Why this rule matched") {
                        Label(ruleEvidence.summary, systemImage: ruleEvidence.symbol)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(ruleEvidence.rows) { row in
                            detailRow(row.title, value: row.value)
                        }
                        if let consequence = ruleEvidence.consequence {
                            Text(consequence)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    inspectorSection("Traffic") {
                        detailRow("Download", value: measurementTitle(downloadMeasurement))
                        detailRow("Upload", value: measurementTitle(uploadMeasurement))
                        if let uploadDatagrams = activity.uploadDatagrams,
                           let downloadDatagrams = activity.downloadDatagrams {
                            detailRow(
                                "Datagrams",
                                value: "↑ \(uploadDatagrams.formatted()) · ↓ \(downloadDatagrams.formatted())"
                            )
                        }
                        if let dropped = activity.droppedDatagrams, dropped > 0 {
                            detailRow("Dropped datagrams", value: dropped.formatted())
                        }
                        if isUnmeasuredAfterHandoff {
                            Label(
                                "MClash recorded the routing decision, then returned this flow to macOS. Payload bytes after that handoff are not observable.",
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        } else if activity.effectiveAction == .direct,
                                  activity.payloadBytesAreMeasured == true {
                            Label(
                                "This flow had already been intercepted before switching to Direct fallback, so App Routing counted bytes after upstream acceptance and application delivery.",
                                systemImage: "checkmark.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    inspectorSection("Lifecycle") {
                        detailRow("Protocol", value: activity.transportProtocol.rawValue.uppercased())
                        detailRow("Relay", value: relayStateTitle)
                        detailRow(
                            "Started",
                            value: activity.startedAt.formatted(date: .abbreviated, time: .standard)
                        )
                        if let endedAt = activity.endedAt {
                            detailRow(
                                "Ended",
                                value: endedAt.formatted(date: .abbreviated, time: .standard)
                            )
                            detailRow(
                                "Duration",
                                value: Duration.seconds(endedAt.timeIntervalSince(activity.startedAt)).formatted()
                            )
                        }
                        if let lastPayloadAt = activity.lastPayloadAt {
                            detailRow(
                                "Last payload",
                                value: lastPayloadAt.formatted(date: .abbreviated, time: .standard)
                            )
                        }
                        detailRow("PID", value: String(activity.source.processIdentifier))
                        if let path = activity.source.executablePath {
                            detailRow("Executable", value: path)
                        }
                        if let identifier = activity.source.bundleIdentifier {
                            detailRow("Bundle ID", value: identifier)
                        }
                    }

                    if let note = activity.relayNote, !note.isEmpty {
                        inspectorSection("Routing Note") {
                            Text(note)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let error = activity.relayError, !error.isEmpty {
                        inspectorSection("Failure") {
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App Routing flow from \(applicationName) to \(destination)")
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 9) {
                content()
            }
        }
    }

    private func pipelineStage(_ title: String, value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value.isEmpty ? "Unavailable" : value)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private var applicationName: String {
        if let name = ledgerEntry?.application.displayName { return name }
        if let path = activity.source.executablePath {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return activity.source.bundleIdentifier
            ?? activity.source.signingIdentifier
            ?? "Process \(activity.source.processIdentifier)"
    }

    private var destination: String {
        let host = activity.destination.hostname
            ?? activity.destination.ipAddress
            ?? "Unknown destination"
        return activity.destination.port > 0 ? "\(host):\(activity.destination.port)" : host
    }

    private var outcomeTitle: String {
        switch ledgerEntry?.outcome {
        case .viaMihomo:
            routeIsConfirmed ? "Mihomo route confirmed" : mihomoEvidenceTitle
        case .direct:
            activity.payloadBytesAreMeasured == true
                ? "Direct · relayed and measured"
                : "Direct · handed back to macOS"
        case .rejected: "Rejected"
        case .failOpen: "Fail-open · handed back to macOS"
        case .relayFailed: "Relay failed"
        case nil:
            switch activity.effectiveAction {
            case .direct: "Direct"
            case .reject: "Rejected"
            case .failOpen: "Fail-open"
            case .mihomo: mihomoEvidenceTitle
            }
        }
    }

    private var outcomeSymbol: String {
        switch ledgerEntry?.outcome {
        case .viaMihomo: "point.3.connected.trianglepath.dotted"
        case .direct: "arrow.right"
        case .rejected: "xmark.octagon.fill"
        case .failOpen: "arrow.uturn.right"
        case .relayFailed: "exclamationmark.triangle.fill"
        case nil: "questionmark.circle"
        }
    }

    private var routeIsConfirmed: Bool {
        FlowLedgerAssociationPresentation.isConfirmed(ledgerEntry?.association)
    }

    private var routeIsProbable: Bool {
        FlowLedgerAssociationPresentation.isProbable(ledgerEntry?.association)
    }

    private var mihomoAssociationTitle: String {
        FlowLedgerAssociationPresentation.title(ledgerEntry?.association)
    }

    private var mihomoEvidenceTitle: String {
        if routeIsConfirmed { return "Route confirmed by Mihomo /connections" }
        if routeIsProbable { return mihomoAssociationTitle }
        if (activity.downloadDatagrams ?? 0) > 0 {
            return "Response observed; node path not yet matched"
        }
        if (activity.uploadDatagrams ?? 0) > 0 || activity.uploadBytes > 0 {
            return "Sent to Mihomo; awaiting /connections confirmation"
        }
        return "Waiting for an associated Mihomo connection"
    }

    private var mihomoEvidenceSymbol: String {
        if routeIsConfirmed { return "checkmark.seal.fill" }
        if (activity.downloadDatagrams ?? 0) > 0 { return "arrow.down.circle.fill" }
        if (activity.uploadDatagrams ?? 0) > 0 || activity.uploadBytes > 0 {
            return "arrow.up.circle.fill"
        }
        return "clock"
    }

    private var uploadMeasurement: FlowLedgerByteMeasurement {
        ledgerEntry?.upload ?? fallbackMeasurement(activity.uploadBytes)
    }

    private var downloadMeasurement: FlowLedgerByteMeasurement {
        ledgerEntry?.download ?? fallbackMeasurement(activity.downloadBytes)
    }

    private func fallbackMeasurement(_ bytes: UInt64) -> FlowLedgerByteMeasurement {
        switch activity.effectiveAction {
        case .direct where activity.payloadBytesAreMeasured == true:
            .exact(bytes)
        case .direct, .failOpen: .notMeasuredAfterHandoff
        case .reject: .notApplicable
        case .mihomo: .exact(bytes)
        }
    }

    private func measurementTitle(_ measurement: FlowLedgerByteMeasurement) -> String {
        switch measurement {
        case let .exact(bytes):
            ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
        case .notMeasuredAfterHandoff:
            "Not measured after handoff"
        case .notApplicable:
            "No payload relayed"
        }
    }

    private var isUnmeasuredAfterHandoff: Bool {
        uploadMeasurement == .notMeasuredAfterHandoff
            || downloadMeasurement == .notMeasuredAfterHandoff
    }

    private var relayStateTitle: String {
        switch activity.relayState {
        case .notApplicable: "Not applicable"
        case .pending: "Pending"
        case .connecting: "Connecting"
        case .ready: "Ready"
        case .relaying: "Relaying"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }
}
