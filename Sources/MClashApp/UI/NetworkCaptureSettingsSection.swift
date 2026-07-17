import MClashNetworkShared
import ServiceManagement
import SwiftUI

struct AppRoutingView: View {
    private enum Workspace: String, CaseIterable, Identifiable {
        case rules = "Rules"
        case activity = "Activity"

        var id: Self { self }
    }

    private enum ActivityFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Active"
        case viaMihomo = "Via Mihomo"
        case direct = "Direct"
        case rejected = "Rejected"
        case failed = "Failed"

        var id: Self { self }
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
    @State private var isRefreshingApplications = false
    @State private var workspace: Workspace = .rules
    @State private var activitySearchText = ""
    @State private var activityFilter: ActivityFilter = .all
    @State private var selectedActivityID: UUID?
    @State private var activityInspectorPresented = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                statusHeader
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Divider()

                ZStack {
                    switch workspace {
                    case .rules:
                        if orderedRules.isEmpty {
                            emptyState
                        } else {
                            rulesTable
                        }
                    case .activity:
                        activityWorkspace
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                Group {
                    if workspace == .rules {
                        actionBar
                    } else {
                        activityActionBar
                    }
                }
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            // GeometryReader supplies the finite detail-column dimensions.
            // Without this clamp, the empty state's flexible height can make
            // NavigationSplitView adopt an oversized ideal height and clip
            // both the sidebar rows and this page's fixed controls offscreen.
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .navigationTitle("App Routing")
        .mclashPageSurface()
        .task(id: candidateRefreshRequest) {
            await refreshApplications(request: candidateRefreshRequest)
        }
        .sheet(isPresented: $showingEditor) {
            CaptureRuleEditorSheet(
                isPresented: $showingEditor,
                draft: $draft,
                applicationCandidates: applicationCandidates,
                processCandidates: processCandidates,
                existingRuleIDs: Set(rules.map(\.id).filter { $0 != editingRuleID })
            ) { rule in
                save(rule)
            }
        }
        .inspector(isPresented: $activityInspectorPresented) {
            if let activity = selectedActivity {
                AppRoutingFlowInspector(
                    activity: activity,
                    ledgerEntry: model.appRoutingFlowEntries[activity.flowIdentifier]
                )
                .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
            } else {
                ContentUnavailableView(
                    "Select an activity",
                    systemImage: "sidebar.right",
                    description: Text("Choose a flow to inspect every routing stage.")
                )
            }
        }
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label(statusTitle, systemImage: statusSymbol)
                            .font(.headline)
                            .foregroundStyle(statusColor)
                        Text(headerCount)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Text(headerDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 24)

                Toggle("Enable App Routing", isOn: enabled)
                    .toggleStyle(.switch)
                    .disabled(
                        model.pendingNetworkCaptureEnabled != nil
                            || !model.canPerform(.changeNetworkCapture)
                    )
            }

            Picker("App Routing workspace", selection: $workspace) {
                ForEach(Workspace.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            if workspace == .activity {
                activitySummary
            }

            statusNotice
        }
        .padding(.horizontal, MClashLayout.pagePadding)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private var statusNotice: some View {
        switch model.networkCaptureState {
        case .waitingForConnection:
            statusNotice(
                title: "Connect MClash to start App Routing",
                message: "The rules are saved. App Routing will start after the active profile connects.",
                symbol: "pause.circle.fill",
                color: .secondary
            ) {
                Button("Connect Now") {
                    Task { await model.connect() }
                }
                .disabled(!model.canPerform(.connection))
            }
        case .awaitingUserApproval:
            statusNotice(
                title: "Approve the MClash Network Extension",
                message: "In System Settings, open General → Login Items & Extensions → Network Extensions, then enable MClash.",
                symbol: "lock.shield.fill",
                color: .orange
            ) {
                Button("Open System Settings") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        case .requiresReboot:
            statusNotice(
                title: "Restart your Mac to finish enabling App Routing",
                message: "macOS accepted the Network Extension update and will activate it after the next restart.",
                symbol: "restart.circle.fill",
                color: .orange
            ) { EmptyView() }
        case let .failed(message):
            statusNotice(
                title: "App Routing couldn’t start",
                message: message,
                symbol: "exclamationmark.triangle.fill",
                color: .red
            ) {
                HStack(spacing: 8) {
                    Button("Retry") {
                        Task { await model.retryNetworkCaptureActivation() }
                    }
                    .disabled(!model.canPerform(.changeNetworkCapture))
                    Button("View Logs") {
                        model.selection = .logs
                    }
                }
            }
        case .off, .enabling, .on, .disabling:
            EmptyView()
        }
    }

    private var activitySummary: some View {
        let recent = model.appRoutingActivities.filter {
            $0.startedAt >= Date().addingTimeInterval(-60)
        }
        let active = recent.filter {
            $0.endedAt == nil
                && $0.relayState != .completed
                && $0.relayState != .failed
                && $0.relayState != .notApplicable
        }.count
        let viaMihomo = recent.filter {
            if case .mihomo = $0.effectiveAction { return $0.relayState != .failed }
            return false
        }.count
        let direct = recent.filter {
            $0.effectiveAction == .direct || $0.effectiveAction == .failOpen
        }.count
        let rejected = recent.filter { $0.effectiveAction == .reject }.count
        let failed = recent.filter { $0.relayState == .failed }.count

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                summaryMetric("Active", value: active, color: .green)
                summaryMetric("Via Mihomo", value: viaMihomo, color: .accentColor)
                summaryMetric("Direct / Handoff", value: direct, color: .secondary)
                summaryMetric("Rejected", value: rejected, color: .red)
                summaryMetric("Failed", value: failed, color: .orange)
                Spacer(minLength: 12)
                providerHeartbeat
            }
            Text("Flow outcomes started in the last minute. Direct and fail-open payload is not measured after macOS takes the flow back.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func summaryMetric(_ title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(formattedCount(value))
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var providerHeartbeat: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Label(providerHeartbeatTitle, systemImage: providerHeartbeatSymbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(providerHeartbeatColor)
            if let date = model.liveStreamHealth[.appRouting]?.lastReceivedAt {
                Text("Verified \(date.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var providerHeartbeatTitle: String {
        switch model.liveStreamHealth[.appRouting]?.phase ?? .inactive {
        case .live: "Provider verified"
        case .connecting: "Verifying provider"
        case .reconnecting: "Provider reconnecting"
        case .stale: "Provider unverified"
        case .inactive: "Provider inactive"
        }
    }

    private var providerHeartbeatSymbol: String {
        switch model.liveStreamHealth[.appRouting]?.phase ?? .inactive {
        case .live: "checkmark.circle.fill"
        case .connecting, .reconnecting: "arrow.clockwise"
        case .stale: "exclamationmark.triangle.fill"
        case .inactive: "circle"
        }
    }

    private var providerHeartbeatColor: Color {
        switch model.liveStreamHealth[.appRouting]?.phase ?? .inactive {
        case .live: .green
        case .connecting, .reconnecting: .orange
        case .stale: .red
        case .inactive: .secondary
        }
    }

    private func statusNotice<Actions: View>(
        title: String,
        message: String,
        symbol: String,
        color: Color,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 16)
            actions()
        }
        .padding(12)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(color.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var rulesTable: some View {
        Table(orderedRules, selection: $selectedRuleID) {
            TableColumn("") { rule in
                Button {
                    setEnabled(!rule.enabled, for: rule)
                } label: {
                    Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(rule.enabled ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(rule.enabled ? "Disable rule" : "Enable rule")
                .accessibilityLabel(rule.enabled ? "Disable \(rule.id)" : "Enable \(rule.id)")
            }
            .width(26)

            TableColumn("Name") { rule in
                Text(rule.id)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { edit(rule) }
            }
            .width(min: 110, ideal: 170)

            TableColumn("Application / Process") { rule in
                Text(sourceSummary(rule))
                    .lineLimit(2)
                    .foregroundStyle(rule.enabled ? Color.primary : Color.secondary)
            }
            .width(min: 150, ideal: 230)

            TableColumn("Target") { rule in
                Text(destinationSummary(rule))
                    .lineLimit(2)
                    .foregroundStyle(rule.enabled ? Color.primary : Color.secondary)
            }
            .width(min: 130, ideal: 210)

            TableColumn("Protocol / Ports") { rule in
                Text(transportSummary(rule))
                    .lineLimit(1)
                    .foregroundStyle(rule.enabled ? Color.primary : Color.secondary)
            }
            .width(min: 105, ideal: 140)

            TableColumn("Action") { rule in
                Text(actionSummary(rule.action))
                    .lineLimit(1)
                    .foregroundStyle(actionColor(rule.action))
            }
            .width(min: 90, ideal: 130)
        }
        .contextMenu(forSelectionType: String.self) { selection in
            if let id = selection.first,
               let rule = orderedRules.first(where: { $0.id == id }) {
                Button("Edit…") { edit(rule) }
                Button("Duplicate") { clone(rule) }
                Divider()
                Button("Delete", role: .destructive) { remove(rule) }
            }
        } primaryAction: { selection in
            if let id = selection.first,
               let rule = orderedRules.first(where: { $0.id == id }) {
                edit(rule)
            }
        }
        .onDeleteCommand { removeSelectedRule() }
    }

    @ViewBuilder
    private var activityWorkspace: some View {
        if model.appRoutingActivities.isEmpty {
            ContentUnavailableView(
                "No App Routing Activity",
                systemImage: "waveform.path.ecg",
                description: Text(activityEmptyDescription)
            )
        } else if filteredActivities.isEmpty {
            ContentUnavailableView.search(text: activitySearchText)
        } else {
            activityTable
        }
    }

    private var activityTable: some View {
        Table(filteredActivities, selection: $selectedActivityID) {
            TableColumn("Application / Process") { activity in
                VStack(alignment: .leading, spacing: 2) {
                    Text(activityApplicationName(activity))
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            selectedActivityID = activity.flowIdentifier
                            activityInspectorPresented = true
                        }
                    Text("PID \(activity.source.processIdentifier)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help(activity.source.executablePath ?? activityApplicationName(activity))
            }
            .width(min: 145, ideal: 200)

            TableColumn("Destination") { activity in
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

            TableColumn("App Rule") { activity in
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.matchedRuleIdentifier ?? activityCause(activity))
                        .lineLimit(1)
                    Text("Requested: \(actionSummary(activity.configuredAction))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 100, ideal: 145)

            TableColumn("Result") { activity in
                Label(
                    activityResult(activity),
                    systemImage: activityResultSymbol(activity)
                )
                .foregroundStyle(activityResultColor(activity))
                .lineLimit(1)
                .help(activity.relayError ?? activityResult(activity))
            }
            .width(min: 100, ideal: 130)

            TableColumn("Mihomo Rule / Path") { activity in
                Text(mihomoPath(activity))
                    .lineLimit(1)
                    .help(mihomoPath(activity))
            }
            .width(min: 145, ideal: 220)

            TableColumn("Traffic") { activity in
                activityTraffic(activity)
            }
            .width(min: 88, ideal: 105)

            TableColumn("Started") { activity in
                Text(activity.startedAt, style: .time)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 72, ideal: 86)
        }
        .onChange(of: selectedActivityID) { _, identifier in
            if identifier == nil { activityInspectorPresented = false }
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

            Button("Duplicate", action: cloneSelectedRule)
                .disabled(selectedRule == nil)
            Button("Edit…", action: editSelectedRule)
                .disabled(selectedRule == nil)
            Button("Delete", role: .destructive, action: removeSelectedRule)
                .disabled(selectedRule == nil)

            Divider()
                .frame(height: 18)

            Button(action: { moveSelectedRule(by: -1) }) {
                Image(systemName: "chevron.up")
            }
            .help("Move rule up")
            .disabled(!canMoveSelectedRule(by: -1))

            Button(action: { moveSelectedRule(by: 1) }) {
                Image(systemName: "chevron.down")
            }
            .help("Move rule down")
            .disabled(!canMoveSelectedRule(by: 1))

            Spacer()

            if let editorError {
                Label(editorError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(editorError)
            }

            Button(action: requestApplicationRefresh) {
                if isRefreshingApplications {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing…")
                    }
                } else {
                    Text("Refresh Applications")
                }
            }
            .disabled(isRefreshingApplications)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, MClashLayout.pagePadding)
        .padding(.vertical, 12)
        .disabled(!model.canPerform(.changeNetworkCapture))
    }

    private var activityActionBar: some View {
        HStack(spacing: 10) {
            Picker("Outcome", selection: $activityFilter) {
                ForEach(ActivityFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)

            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter app, destination, rule, or path", text: $activitySearchText)
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
                Text("Live · updates automatically")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Clear") {
                Task { await model.clearAppRoutingActivity() }
            }
            .disabled(model.appRoutingActivities.isEmpty)

            Button {
                activityInspectorPresented.toggle()
            } label: {
                Label("Inspect", systemImage: "sidebar.right")
            }
            .disabled(selectedActivity == nil)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, MClashLayout.pagePadding)
        .padding(.vertical, 12)
    }

    private var headerCount: String {
        switch workspace {
        case .rules:
            "· \(orderedRules.count) \(orderedRules.count == 1 ? "rule" : "rules")"
        case .activity:
            "· \(model.appRoutingActivities.count) flows"
        }
    }

    private var headerDescription: String {
        switch workspace {
        case .rules:
            "Rules are evaluated from top to bottom. The first matching rule decides whether traffic uses Mihomo, connects directly, or is rejected."
        case .activity:
            "Live decisions from the Network Extension show which process matched which App Routing rule, the effective route, relay state, traffic, and the corresponding Mihomo path when available."
        }
    }

    private var activityEmptyDescription: String {
        switch model.networkCaptureState {
        case .on:
            "Start using an application covered by a rule. Its next TCP or UDP flow will appear here."
        default:
            "Enable App Routing and connect MClash to inspect flow decisions."
        }
    }

    private var filteredActivities: [AppRoutingActivity] {
        let query = activitySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return model.appRoutingActivities.filter { activity in
            guard activityMatchesFilter(activity) else { return false }
            guard !query.isEmpty else { return true }
            let fields = [
                activityApplicationName(activity),
                activity.source.executablePath,
                activityDestination(activity),
                activity.matchedRuleIdentifier,
                activityCause(activity),
                activityResult(activity),
                mihomoPath(activity),
            ].compactMap { $0?.lowercased() }
            return fields.contains { $0.contains(query) }
        }
    }

    private var selectedActivity: AppRoutingActivity? {
        guard let selectedActivityID else { return nil }
        return model.appRoutingActivities.first { $0.flowIdentifier == selectedActivityID }
    }

    private func activityMatchesFilter(_ activity: AppRoutingActivity) -> Bool {
        switch activityFilter {
        case .all:
            return true
        case .active:
            return activity.endedAt == nil
                && activity.relayState != .completed
                && activity.relayState != .failed
        case .viaMihomo:
            if case .mihomo = activity.effectiveAction {
                return activity.relayState != .failed
            }
            return false
        case .direct:
            return activity.effectiveAction == .direct
                || activity.effectiveAction == .failOpen
        case .rejected:
            return activity.effectiveAction == .reject
        case .failed:
            return activity.relayState == .failed
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

    private func activityResult(_ activity: AppRoutingActivity) -> String {
        if activity.relayState == .failed { return "Relay failed" }
        return switch activity.effectiveAction {
        case .direct: "Direct"
        case .reject: "Rejected"
        case .failOpen: "Fail-open"
        case .mihomo: switch activity.relayState {
            case .pending, .connecting: "Connecting"
            case .ready: "Mihomo ready"
            case .relaying: "Via Mihomo"
            case .completed: "Mihomo complete"
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
            return activity.relayState == .failed ? "Relay failed" : "Waiting for Mihomo metadata"
        }
        let rule = [route.rule, route.rulePayload]
            .compactMap { $0 }
            .joined(separator: " · ")
        let chain = route.chain.joined(separator: " → ")
        return [rule, chain].filter { !$0.isEmpty }.joined(separator: " · ")
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
        case .direct, .failOpen: .notMeasuredAfterHandoff
        case .reject: .notApplicable
        case .mihomo: .exact(activity.uploadBytes)
        }
    }

    private func formattedActivityBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
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

    private var selectedRule: CaptureRule? {
        guard let selectedRuleID else { return nil }
        return orderedRules.first(where: { $0.id == selectedRuleID })
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
        (rules.map(\.priority).max() ?? 0) + 10
    }

    private func addRule() {
        requestApplicationRefresh()
        editingRuleID = nil
        selectedRuleID = nil
        draft = CaptureRuleDraft(
            identifier: uniqueRuleName("New Rule"),
            priority: nextPriority
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
        guard let selectedRuleID,
              let index = orderedRules.firstIndex(where: { $0.id == selectedRuleID }) else {
            return false
        }
        return orderedRules.indices.contains(index + offset)
    }

    private func moveSelectedRule(by offset: Int) {
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

    private func refreshApplications(request: Int) async {
        isRefreshingApplications = true
        defer {
            if request == candidateRefreshRequest {
                isRefreshingApplications = false
            }
        }

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
                        pipelineStage("Capture", value: "App Routing", symbol: "network.badge.shield.half.filled")
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
                                value: "Waiting for an associated Mihomo connection",
                                symbol: "clock"
                            )
                        }
                        pipelineStage("Destination", value: destination, symbol: "scope")
                    }

                    inspectorSection("Traffic") {
                        detailRow("Download", value: measurementTitle(downloadMeasurement))
                        detailRow("Upload", value: measurementTitle(uploadMeasurement))
                        if isUnmeasuredAfterHandoff {
                            Label(
                                "MClash recorded the routing decision, then returned this flow to macOS. Payload bytes after that handoff are not observable.",
                                systemImage: "info.circle"
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
                        detailRow("PID", value: String(activity.source.processIdentifier))
                        if let path = activity.source.executablePath {
                            detailRow("Executable", value: path)
                        }
                        if let identifier = activity.source.bundleIdentifier {
                            detailRow("Bundle ID", value: identifier)
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
        case .viaMihomo: "Via Mihomo"
        case .direct: "Direct · handed back to macOS"
        case .rejected: "Rejected"
        case .failOpen: "Fail-open · handed back to macOS"
        case .relayFailed: "Relay failed"
        case nil:
            switch activity.effectiveAction {
            case .direct: "Direct"
            case .reject: "Rejected"
            case .failOpen: "Fail-open"
            case .mihomo: "Via Mihomo"
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

    private var uploadMeasurement: FlowLedgerByteMeasurement {
        ledgerEntry?.upload ?? fallbackMeasurement
    }

    private var downloadMeasurement: FlowLedgerByteMeasurement {
        ledgerEntry?.download ?? fallbackMeasurement
    }

    private var fallbackMeasurement: FlowLedgerByteMeasurement {
        switch activity.effectiveAction {
        case .direct, .failOpen: .notMeasuredAfterHandoff
        case .reject: .notApplicable
        case .mihomo: .exact(0)
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
