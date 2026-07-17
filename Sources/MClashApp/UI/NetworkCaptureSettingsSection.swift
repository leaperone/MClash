import MClashNetworkShared
import ServiceManagement
import SwiftUI

struct AppRoutingView: View {
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

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                statusHeader
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Divider()

                ZStack {
                    if orderedRules.isEmpty {
                        emptyState
                    } else {
                        rulesTable
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                actionBar
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
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label(statusTitle, systemImage: statusSymbol)
                            .font(.headline)
                            .foregroundStyle(statusColor)
                        Text("· \(orderedRules.count) \(orderedRules.count == 1 ? "rule" : "rules")")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Text("Rules are evaluated from top to bottom. The first matching rule decides whether traffic uses Mihomo, connects directly, or is rejected.")
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
