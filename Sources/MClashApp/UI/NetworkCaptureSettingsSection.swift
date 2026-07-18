import MClashNetworkShared
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct AppRoutingView: View {
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
    @State private var activityFilter: AppRoutingActivityFilter = .focused
    @State private var selectedActivityID: UUID?
    @State private var activityInspectorPresented = false
    @State private var activityInspectorPresentation: InspectorPresentation = .popover
    @State private var showingDNSReplacementConfirmation = false
    @State private var showingAppRoutingEnableConfirmation = false
    @State private var advancedDNSExpanded = false
    @State private var showingProxifierImporter = false
    @State private var proxifierImportPlan: ProxifierRuleImportPlan?
    @State private var proxifierImportError: String?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                statusHeader
                    .frame(height: 86)
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
                    .frame(height: 46)
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
        .onAppear {
            model.setAppRoutingActivityViewVisible(workspace == .activity)
        }
        .onDisappear {
            model.setAppRoutingActivityViewVisible(false)
        }
        .onChange(of: workspace) { _, workspace in
            model.setAppRoutingActivityViewVisible(workspace == .activity)
            if workspace != .activity {
                activityInspectorPresented = false
            }
        }
        .sheet(isPresented: $showingEditor) {
            CaptureRuleEditorSheet(
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

                Picker("App Routing workspace", selection: $workspace) {
                    ForEach(Workspace.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                HStack(spacing: 10) {
                    Menu {
                        Toggle("Include DNS with App Routing", isOn: dnsEnabled)
                        Divider()
                        Button("Open Attention") { model.selection = .attention }
                        Button("Open Logs") { model.selection = .logs }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .help("App Routing options")

                    Toggle("Enabled", isOn: enabled)
                        .toggleStyle(.switch)
                        .disabled(
                            model.pendingNetworkCaptureEnabled != nil
                                || !model.canPerform(.changeNetworkCapture)
                        )
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 48)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: compactStatusSymbol)
                    .foregroundStyle(compactStatusColor)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(compactStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(compactStatusHelp)
                Spacer(minLength: 12)
                compactStatusActions
            }
            .frame(height: 37)
        }
        .padding(.horizontal, MClashLayout.pagePadding)
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
            let active = model.appRoutingActivities.count(where: {
                $0.endedAt == nil && $0.relayState != .failed
            })
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
        .frame(width: 190, alignment: .trailing)
    }

    private var dataPlaneStatus: some View {
        HStack(alignment: .top, spacing: 12) {
            dataPlaneCard(
                title: "Application Traffic",
                status: applicationDataPlaneTitle,
                detail: applicationDataPlaneDetail,
                symbol: applicationDataPlaneSymbol,
                color: applicationDataPlaneColor
            ) {
                EmptyView()
            }

            dataPlaneCard(
                title: "DNS Traffic",
                status: dnsDataPlaneTitle,
                detail: dnsDataPlaneDetail,
                symbol: dnsDataPlaneSymbol,
                color: dnsDataPlaneColor
            ) {
                if model.dnsProxyAutomaticallyDisabled
                    || model.dnsProxyRuntimeError != nil {
                    Button("Retry") {
                        Task { await model.retryDNSCaptureActivation() }
                    }
                    .controlSize(.small)
                    .disabled(!model.canPerform(.changeNetworkCapture))
                }
            }
        }
    }

    private var advancedDNSSettings: some View {
        DisclosureGroup("Advanced DNS Routing", isExpanded: $advancedDNSExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Include DNS when App Routing is enabled", isOn: dnsEnabled)
                    .toggleStyle(.switch)
                    .disabled(
                        model.pendingNetworkCaptureEnabled != nil
                            || !model.canPerform(.changeNetworkCapture)
                    )
                Text("Recommended. DNS Routing normally starts and stops with App Routing. Turn this off only when another DNS Proxy must remain responsible for system DNS. App-provided DoH cannot be identified as DNS traffic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }

    private func dataPlaneCard<Actions: View>(
        title: String,
        status: String,
        detail: String,
        symbol: String,
        color: Color,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(status)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(0.18), lineWidth: 1)
        }
    }

    private var applicationDataPlaneTitle: String {
        switch model.networkCaptureState {
        case .on:
            model.appRoutingProviderLastVerifiedAt == nil
                ? "Verifying Provider"
                : "Provider Verified"
        case .enabling: "Starting"
        case .awaitingUserApproval: "Approval Required"
        case .failed: "Needs Attention"
        case .waitingForConnection: "Waiting for Connection"
        case .disabling: "Stopping"
        case .requiresReboot: "Restart Required"
        case .off: "Off"
        }
    }

    private var applicationDataPlaneDetail: String {
        let active = model.appRoutingActivities.filter {
            $0.endedAt == nil && $0.relayState != .failed
        }.count
        let measured = model.appRoutingTrafficRates.measured
        let direct = model.appRoutingTrafficRates.direct
        let rates = model.liveStreamHealth[.appRouting]?.hasCurrentData == true
            ? "measured ↓ \(formattedActivityRate(measured.download)) ↑ \(formattedActivityRate(measured.upload)); Direct ↓ \(formattedActivityRate(direct.download)) ↑ \(formattedActivityRate(direct.upload))"
            : "live rates unavailable; last-known counters are retained"
        if let date = model.appRoutingProviderLastVerifiedAt {
            return "\(formattedCount(active)) active conversations · \(rates) · Provider verified \(date.formatted(.relative(presentation: .named)))."
        }
        return "\(formattedCount(active)) active conversations · \(rates) · waiting for an authenticated Provider response."
    }

    private var applicationDataPlaneSymbol: String {
        switch model.networkCaptureState {
        case .on: "checkmark.shield.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .enabling, .disabling: "arrow.clockwise"
        case .awaitingUserApproval: "lock.shield.fill"
        default: "shield"
        }
    }

    private var applicationDataPlaneColor: Color {
        switch model.networkCaptureState {
        case .on: model.appRoutingProviderLastVerifiedAt == nil ? .orange : .green
        case .failed: .red
        case .enabling, .disabling, .awaitingUserApproval, .requiresReboot: .orange
        default: .secondary
        }
    }

    private var dnsDataPlaneTitle: String {
        guard model.networkCapturePreferences.dnsEnabled else { return "Off" }
        guard model.networkCapturePreferences.enabled else { return "Starts with App Routing" }
        if model.dnsProxyRuntimeError != nil { return "Needs Attention" }
        if model.dnsProxyAutomaticallyDisabled { return "Stopped with App Routing" }
        if let status = model.dnsProxyRuntimeStatus, status.isOperational {
            return status.lastResponseDeliveredAt == nil
                ? "Mihomo Listener Ready"
                : "DNS Responses Observed"
        }
        return "Verifying Provider"
    }

    private var dnsDataPlaneDetail: String {
        if let error = model.dnsProxyRuntimeError { return error }
        guard model.networkCapturePreferences.dnsEnabled else {
            return "DNS is excluded by the Advanced DNS Routing setting; the current macOS resolver remains responsible."
        }
        guard model.networkCapturePreferences.enabled else {
            return "DNS Routing will start with App Routing and stop when App Routing is turned off."
        }
        guard let status = model.dnsProxyRuntimeStatus else {
            return "Waiting for a matching DNS Provider heartbeat and Mihomo backend probe."
        }
        let (totalBytes, overflow) = status.uploadBytes.addingReportingOverflow(
            status.downloadBytes
        )
        let traffic = formattedActivityBytes(overflow ? .max : totalBytes)
        let association = status.lastBackendAssociationAt.map {
            "SOCKS association \($0.formatted(.relative(presentation: .named)))"
        } ?? "SOCKS association not yet verified"
        let query = status.lastQueryForwardedAt.map {
            "query forwarded \($0.formatted(.relative(presentation: .named)))"
        } ?? "no query forwarded yet"
        let response = status.lastResponseDeliveredAt.map {
            "response delivered \($0.formatted(.relative(presentation: .named)))"
        } ?? "no response delivered yet"
        return "\(formattedCount(Int(clamping: status.activeTCPFlows))) TCP + \(formattedCount(Int(clamping: status.activeUDPFlows))) UDP active · \(formattedCount(Int(clamping: status.completedFlows))) completed · \(formattedCount(Int(clamping: status.failedFlows))) failed · \(traffic). \(association); \(query); \(response)."
    }

    private var dnsDataPlaneSymbol: String {
        if model.dnsProxyRuntimeError != nil { return "exclamationmark.triangle.fill" }
        if model.dnsProxyAutomaticallyDisabled { return "arrow.uturn.backward.circle.fill" }
        if model.dnsProxyRuntimeStatus?.isOperational == true { return "checkmark.shield.fill" }
        guard model.networkCapturePreferences.dnsEnabled else { return "network" }
        return model.networkCapturePreferences.enabled ? "arrow.clockwise" : "link.circle"
    }

    private var dnsDataPlaneColor: Color {
        if model.dnsProxyRuntimeError != nil { return .red }
        if model.dnsProxyAutomaticallyDisabled { return .orange }
        if model.dnsProxyRuntimeStatus?.isOperational == true { return .green }
        return model.networkCapturePreferences.dnsEnabled
            && model.networkCapturePreferences.enabled ? .orange : .secondary
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
                title: "App Routing Needs Attention",
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
        case .off, .on:
            networkCaptureReceiptNotice
        case .enabling, .disabling:
            EmptyView()
        }
    }

    @ViewBuilder
    private var networkCaptureReceiptNotice: some View {
        if let receipt = model.networkCaptureChangeReceipt {
            switch receipt.outcome {
            case .savedForNextActivation:
                statusNotice(
                    title: "Settings saved without interrupting Mihomo",
                    message: "App Routing is off, so the rules and advanced DNS preference were saved for the next activation. Completed in \(formattedDuration(receipt.duration)).",
                    symbol: "checkmark.circle.fill",
                    color: .green
                ) { EmptyView() }
            case let .requiresReboot(dnsEnabled):
                statusNotice(
                    title: "Restart required to finish App Routing",
                    message: dnsEnabled
                        ? "macOS saved App Routing and DNS Routing, but the updated Network Extension will not run until this Mac restarts."
                        : "macOS saved App Routing, but the updated Network Extension will not run until this Mac restarts.",
                    symbol: "restart.circle.fill",
                    color: .orange
                ) { EmptyView() }
            case let .appliedAndVerified(enabled, dnsEnabled, systemProxyWasDisabled):
                statusNotice(
                    title: enabled ? "App Routing change verified" : "App Routing turned off",
                    message: networkCaptureReceiptMessage(
                        enabled: enabled,
                        dnsEnabled: dnsEnabled,
                        systemProxyWasDisabled: systemProxyWasDisabled,
                        duration: receipt.duration
                    ),
                    symbol: "checkmark.circle.fill",
                    color: .green
                ) { EmptyView() }
            case let .rejectedAndRolledBack(reason):
                statusNotice(
                    title: "Change rejected; previous network state restored",
                    message: "\(reason) Recovery completed in \(formattedDuration(receipt.duration)).",
                    symbol: "arrow.uturn.backward.circle.fill",
                    color: .orange
                ) { EmptyView() }
            case let .rollbackFailed(reason):
                statusNotice(
                    title: "Previous network state was not fully restored",
                    message: reason,
                    symbol: "exclamationmark.triangle.fill",
                    color: .red
                ) {
                    Button("View Logs") { model.selection = .logs }
                }
            }
        }
    }

    private func networkCaptureReceiptMessage(
        enabled: Bool,
        dnsEnabled: Bool,
        systemProxyWasDisabled: Bool,
        duration: TimeInterval
    ) -> String {
        var facts = [
            enabled ? "App Routing is enabled" : "App Routing is disabled",
            dnsEnabled && enabled
                ? "DNS Routing started with App Routing"
                : dnsEnabled
                    ? "DNS Routing stopped with App Routing"
                    : "DNS Routing is excluded in Advanced settings",
        ]
        if systemProxyWasDisabled {
            facts.append("the previously enabled System Proxy was turned off to avoid double interception")
        }
        facts.append("completed in \(formattedDuration(duration))")
        return facts.joined(separator: "; ") + "."
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        duration < 1
            ? "\(Int((duration * 1_000).rounded())) ms"
            : "\(String(format: "%.1f", duration)) s"
    }

    private var activitySummary: some View {
        let recent = model.appRoutingActivities.filter {
            $0.startedAt >= Date().addingTimeInterval(-60)
        }
        let active = model.appRoutingActivities.filter {
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
                summaryMetric("Via Mihomo · 60s", value: viaMihomo, color: .accentColor)
                summaryMetric("Direct / Handoff · 60s", value: direct, color: .secondary)
                summaryMetric("Rejected · 60s", value: rejected, color: .red)
                summaryMetric("Failed · 60s", value: failed, color: .orange)
                Spacer(minLength: 12)
                providerHeartbeat
            }
            Text("Active includes every retained open conversation. Outcome counts cover flows started in the last minute. Owned TCP and UDP Direct traffic is measured; built-in bypass and fail-open handoffs remain explicitly unmeasured.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label(
                    "Measured now ↓ \(formattedActivityRate(model.appRoutingTrafficRates.measured.download)) ↑ \(formattedActivityRate(model.appRoutingTrafficRates.measured.upload))",
                    systemImage: "speedometer"
                )
                Label(
                    "Retained \(formattedCount(model.appRoutingActivities.count))/2,000",
                    systemImage: "tray.full"
                )
                if model.appRoutingActivityDroppedCount > 0 {
                    Label(
                        "\(formattedActivityCount(model.appRoutingActivityDroppedCount)) records dropped",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
                if let coverage = model.appRoutingActivityCoverageStartedAt {
                    Text("Coverage since \(coverage.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            let pathRates = model.appRoutingTrafficRates.byPath
                .filter { $0.value.total > 0 }
                .sorted { $0.value.total > $1.value.total }
            if !pathRates.isEmpty {
                HStack(spacing: 12) {
                    Text("Paths now")
                        .fontWeight(.semibold)
                    ForEach(Array(pathRates.prefix(4)), id: \.key) { path, rate in
                        Text(
                            "\(appRoutingTrafficPathTitle(path)) ↓ \(formattedActivityRate(rate.download)) ↑ \(formattedActivityRate(rate.upload))"
                        )
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
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
            if let verifiedAt = model.appRoutingProviderLastVerifiedAt {
                Text("Revision verified \(verifiedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let responseAt = model.liveStreamHealth[.appRouting]?.lastReceivedAt {
                Text("Activity response \(responseAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
        let statistics = model.appRoutingRuleStatistics
        return Table(orderedRules, selection: $selectedRuleID) {
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

            TableColumn("Observed") { rule in
                let value = statistics[rule.id] ?? .zero
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(formattedCount(value.matchCount)) matches")
                        .monospacedDigit()
                    if value.activeCount > 0 {
                        Text("\(formattedCount(value.activeCount)) active")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if value.failureCount > 0 {
                        Text("\(formattedCount(value.failureCount)) failed")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .width(min: 88, ideal: 110)

            TableColumn("Traffic") { rule in
                let value = statistics[rule.id] ?? .zero
                let rate = model.appRoutingTrafficRates.byRule[rule.id] ?? AppRoutingByteRate()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formattedRuleTraffic(value.measuredBytes, partial: value.unmeasuredCount > 0))
                    Text("↓ \(formattedActivityRate(rate.download))  ↑ \(formattedActivityRate(rate.upload))")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(value.unmeasuredCount > 0 ? Color.orange : Color.secondary)
                .help(ruleTrafficHelp(value))
            }
            .width(min: 116, ideal: 138)

            TableColumn("Last Match") { rule in
                if let date = statistics[rule.id]?.lastMatchedAt {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(date.formatted(date: .abbreviated, time: .standard))
                } else {
                    Text("Never")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 72, ideal: 96)
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
        let visibleActivities = filteredActivities
        if model.appRoutingActivities.isEmpty {
            ContentUnavailableView(
                "No App Routing Activity",
                systemImage: "waveform.path.ecg",
                description: Text(activityEmptyDescription)
            )
        } else if showsOnlyHiddenDirectActivity(visibleActivities) {
            ContentUnavailableView {
                Label("Only Direct Activity", systemImage: "arrow.right")
            } description: {
                Text("Normal Direct traffic is hidden by default so proxy routes and problems stay easy to see.")
            } actions: {
                Button("Show All Activity") {
                    activityFilter = .all
                }
            }
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
                .help(activity.relayError ?? activity.relayNote ?? activityResult(activity))
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

            Menu {
                Button {
                    proxifierImportError = nil
                    showingProxifierImporter = true
                } label: {
                    Label("Proxifier Profile…", systemImage: "arrow.down.doc")
                }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Import routing rules from a Proxifier .ppx profile")

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
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, MClashLayout.pagePadding)
        .frame(height: 46)
        .disabled(!model.canPerform(.changeNetworkCapture))
    }

    private var activityActionBar: some View {
        HStack(spacing: 10) {
            Picker("Outcome", selection: $activityFilter) {
                ForEach(AppRoutingActivityFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)
            .help("Proxy & Issues hides normal Direct traffic while keeping failures and fallback routes visible.")

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
                switch model.liveStreamHealth[.appRouting]?.phase ?? .inactive {
                case .live:
                    Text("Live · updates automatically")
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
        .onChange(of: activityFilter) { _, _ in
            discardHiddenActivitySelection()
        }
        .onChange(of: activitySearchText) { _, _ in
            discardHiddenActivitySelection()
        }
    }

    private var headerCount: String {
        switch workspace {
        case .rules:
            "· \(orderedRules.count) \(orderedRules.count == 1 ? "rule" : "rules")"
        case .activity:
            if filteredActivities.count == model.appRoutingActivities.count {
                "· \(filteredActivities.count) flows"
            } else {
                "· \(filteredActivities.count) shown · \(model.appRoutingActivities.count) retained"
            }
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

    private func showsOnlyHiddenDirectActivity(_ visibleActivities: [AppRoutingActivity]) -> Bool {
        activityFilter == .focused
            && activitySearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.appRoutingActivities.isEmpty
            && visibleActivities.isEmpty
    }

    private var selectedActivity: AppRoutingActivity? {
        guard let selectedActivityID else { return nil }
        return model.appRoutingActivities.first { $0.flowIdentifier == selectedActivityID }
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

    private func activityMatchesFilter(_ activity: AppRoutingActivity) -> Bool {
        activityFilter.includes(activity)
    }

    private func discardHiddenActivitySelection() {
        guard let selectedActivityID,
              !filteredActivities.contains(where: { $0.flowIdentifier == selectedActivityID }) else {
            return
        }
        self.selectedActivityID = nil
        activityInspectorPresented = false
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
        return orderedRules.first(where: { $0.id == selectedRuleID })
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
                                "App Routing owned this Direct flow and counted bytes only after upstream acceptance and application delivery.",
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
