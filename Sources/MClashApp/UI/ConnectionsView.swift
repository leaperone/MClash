import SwiftUI

struct ConnectionsView: View {
    private enum Workspace: String, CaseIterable, Identifiable {
        case live = "Live"
        case apps = "Apps"
        case routes = "Routes"
        case history = "History"

        var id: Self { self }
    }

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

    @ViewBuilder
    private func liveWorkspace(presentation: ConnectionPresentationSnapshot) -> some View {
        if !model.isConnected {
            DisconnectedUnavailableView(
                model: model,
                title: "Connect to inspect traffic",
                systemImage: "arrow.left.arrow.right",
                description: "Live connections are streamed from the local Mihomo controller."
            )
        } else if !presentation.hasSnapshot,
                  let health = model.liveStreamHealth[.connections],
                  health.phase == .stale {
            ContentUnavailableView {
                Label("Connections unavailable", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            } description: {
                Text(liveStreamDetail(health, source: "Mihomo connections"))
            } actions: {
                Button("Reconnect MClash") {
                    Task { await model.restartConnection() }
                }
                .disabled(!model.canPerform(.connection))
            }
        } else if !presentation.hasSnapshot {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading active connections…")
                    .foregroundStyle(.secondary)
            }
        } else if !presentation.hasConnections {
            ContentUnavailableView(
                "No active connections",
                systemImage: "checkmark.circle",
                description: Text("New network connections will appear here automatically.")
            )
        } else if presentation.rows.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            connectionTable(rows: presentation.rows)
        }
    }

    @ViewBuilder
    private var applicationWorkspace: some View {
        if model.flowLedger.entries.isEmpty {
            ContentUnavailableView(
                "No observed application traffic",
                systemImage: "square.stack.3d.up",
                description: Text("Applications appear after Mihomo or App Routing observes a flow.")
            )
        } else if filteredApplications.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            Table(filteredApplications) {
                TableColumn("Application") { aggregate in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(aggregate.application.displayName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if let identifier = aggregate.application.bundleIdentifier {
                            Text(identifier)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .help(aggregate.application.executablePath ?? aggregate.application.displayName)
                }
                .width(min: 180, ideal: 260)

                TableColumn("Active") { aggregate in
                    Text(formattedCount(aggregate.activeCount))
                        .monospacedDigit()
                }
                .width(70)

                TableColumn("Traffic") { aggregate in
                    Text(formattedLedgerBytes(aggregate.traffic.exactTotalBytes))
                        .monospacedDigit()
                        .foregroundStyle(
                            aggregate.traffic.notMeasuredAfterHandoffCount > 0
                                ? Color.orange
                                : Color.primary
                        )
                        .help(trafficCoverageHelp(aggregate.traffic))
                }
                .width(min: 100, ideal: 130)
            }
        }
    }

    @ViewBuilder
    private var routeWorkspace: some View {
        if model.flowLedger.routeAggregates.isEmpty {
            ContentUnavailableView(
                "No observed routes",
                systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("Routes appear as traffic decisions and Mihomo connections are observed.")
            )
        } else if filteredRoutes.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            Table(filteredRoutes) {
                TableColumn("Route") { aggregate in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(routeTitle(aggregate.route))
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(routeSubtitle(aggregate.route, traffic: aggregate.traffic))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .help(routeHelp(aggregate.route, traffic: aggregate.traffic))
                }
                .width(min: 240, ideal: 380)

                TableColumn("Active") { aggregate in
                    Text(formattedCount(aggregate.activeCount))
                        .monospacedDigit()
                }
                .width(70)

                TableColumn("Traffic") { aggregate in
                    Text(formattedLedgerBytes(aggregate.traffic.exactTotalBytes))
                        .monospacedDigit()
                        .foregroundStyle(
                            aggregate.traffic.notMeasuredAfterHandoffCount > 0
                                ? Color.orange
                                : Color.primary
                        )
                        .help(trafficCoverageHelp(aggregate.traffic))
                }
                .width(min: 110, ideal: 140)
            }
        }
    }

    @ViewBuilder
    private func historyWorkspace(compact: Bool) -> some View {
        VStack(spacing: 0) {
            historyConfiguration(compact: compact)
            Divider()

            if historicalEntries.isEmpty {
                ContentUnavailableView(
                    "No session traffic history",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Completed connection details appear here for this app session. Persistent totals, when enabled, remain available above without storing destinations.")
                )
            } else if filteredHistory.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                historyTable
            }
        }
    }

    @ViewBuilder
    private func historyConfiguration(compact: Bool) -> some View {
        switch model.trafficHistoryRuntimeState {
        case .notConfigured, .loading, .unavailable:
            persistentTrafficHistoryControl(compact: compact)
        case .sessionOnly, .ready:
            DisclosureGroup("History Settings") {
                persistentTrafficHistoryControl(compact: true)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var historyTable: some View {
        Table(filteredHistory) {
            TableColumn("Application") { entry in
                Text(entry.application.displayName)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 170)

            TableColumn("Destination") { entry in
                Text(ledgerDestination(entry.destination))
                    .lineLimit(1)
                    .help(ledgerDestination(entry.destination))
            }
            .width(min: 150, ideal: 220)

            TableColumn("Decision") { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(outcomeTitle(entry.outcome)) · \(historyRuleTitle(entry))")
                        .foregroundStyle(outcomeColor(entry.outcome))
                        .lineLimit(1)
                    Text(historyCompactDetail(entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help(historyEntryHelp(entry))
                .accessibilityElement(children: .combine)
            }
            .width(min: 150, ideal: 240)

            TableColumn("Traffic") { entry in
                Text(ledgerTrafficTitle(entry))
                    .monospacedDigit()
                    .help(ledgerTrafficHelp(entry))
            }
            .width(min: 92, ideal: 120)
        }
    }

    private var workspaceSummary: String {
        switch workspace {
        case .live:
            return ""
        case .apps:
            return "\(formattedCount(scopedApplicationAggregates.count)) apps"
        case .routes:
            return "\(formattedCount(scopedRouteAggregates.count)) routes"
        case .history:
            return "\(formattedCount(historicalEntries.count)) records"
        }
    }

    private var filteredApplications: [FlowLedgerApplicationAggregate] {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scopedApplicationAggregates }
        return scopedApplicationAggregates.filter { aggregate in
            [
                aggregate.application.displayName,
                aggregate.application.bundleIdentifier,
                aggregate.application.executablePath,
                aggregate.application.signingIdentifier,
            ].compactMap { $0 }.contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private var filteredRoutes: [FlowLedgerRouteAggregate] {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scopedRouteAggregates }
        return scopedRouteAggregates.filter { aggregate in
            routeHelp(aggregate.route, traffic: aggregate.traffic)
                .localizedCaseInsensitiveContains(query)
        }
    }

    private var historicalEntries: [FlowLedgerEntry] {
        model.flowLedger.completedEntries(
            for: selectedProfileScope.trafficTarget
        )
    }

    private var scopedApplicationAggregates: [FlowLedgerApplicationAggregate] {
        model.flowLedger.applicationAggregates(
            for: selectedProfileScope.trafficTarget
        )
    }

    private var scopedRouteAggregates: [FlowLedgerRouteAggregate] {
        model.flowLedger.routeAggregates(
            for: selectedProfileScope.trafficTarget
        )
    }

    private func historyRuleTitle(_ entry: FlowLedgerEntry) -> String {
        entry.mihomoRoute?.rule ?? entry.appRoutingRule ?? "—"
    }

    private func historyRuleHelp(_ entry: FlowLedgerEntry) -> String {
        let value = [entry.appRoutingRule, entry.mihomoRoute?.rule, entry.mihomoRoute?.rulePayload]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " → ")
        return value.isEmpty ? "No rule metadata was reported." : value
    }

    private func historyRouteTitle(_ entry: FlowLedgerEntry) -> String {
        entry.mihomoRoute?.chain.last ?? outcomeTitle(entry.outcome)
    }

    private func historyRouteHelp(_ entry: FlowLedgerEntry) -> String {
        guard let chain = entry.mihomoRoute?.chain, !chain.isEmpty else {
            return outcomeTitle(entry.outcome)
        }
        return chain.joined(separator: " → ")
    }

    private func historyCompactDetail(_ entry: FlowLedgerEntry) -> String {
        let ended = entry.endedAt?.formatted(date: .omitted, time: .shortened) ?? "—"
        return "\(historyRouteTitle(entry)) · \(profileTitle(entry.trafficTarget)) · \(ended)"
    }

    private func historyEntryHelp(_ entry: FlowLedgerEntry) -> String {
        "Capture: \(captureOriginTitle(entry.captureOrigin))\n"
            + "Rule: \(historyRuleHelp(entry))\n"
            + "Route: \(historyRouteHelp(entry))\n"
            + "Profile: \(profileTitle(entry.trafficTarget))\n"
            + "Ended: \(entry.endedAt?.formatted(date: .abbreviated, time: .standard) ?? "—")"
    }

    private var filteredHistory: [FlowLedgerEntry] {
        let query = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return historicalEntries }
        return historicalEntries.filter { entry in
            [
                entry.application.displayName,
                ledgerDestination(entry.destination),
                captureOriginTitle(entry.captureOrigin),
                outcomeTitle(entry.outcome),
                entry.appRoutingRule,
                entry.mihomoRoute?.rule,
                entry.mihomoRoute?.rulePayload,
                entry.mihomoRoute?.chain.joined(separator: " → "),
            ].compactMap { $0 }.contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    @Bindable var model: AppModel
    @SceneStorage("mclash.connections.searchText") private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var selectedConnectionID: String?
    @State private var sortOrder: [KeyPathComparator<ConnectionTableRow>] = []
    @State private var presentation = ConnectionPresentationSnapshot.empty
    @State private var presentationTask: Task<Void, Never>?
    @State private var presentationGeneration: UInt64 = 0
    @SceneStorage("mclash.connections.sortField") private var storedSortField = ""
    @SceneStorage("mclash.connections.sortDescending") private var storedSortDescending = false
    @State private var hasRestoredSortOrder = false
    @State private var inspectorPresented = false
    @State private var inspectorPresentation: ConnectionInspectorPresentation = .popover
    @State private var confirmingCloseAll = false
    @State private var confirmingClearTrafficHistory = false
    @State private var persistentHistoryPeriod: TrafficHistoryPeriod = .today
    @SceneStorage("mclash.traffic.workspace") private var workspace: Workspace = .live
    @State private var selectedProfileScope: ProfileScope = .all

    var body: some View {
        let presentation = presentation
        let selectedConnection = selectedConnectionID.flatMap {
            presentation.connectionsByIdentifier[$0]
        }
        let selectedConnectionIsVisible = selectedConnectionID.map {
            presentation.visibleIdentifiers.contains($0)
        } ?? true

        GeometryReader { geometry in
            VStack(spacing: 0) {
                trafficHeader(
                    presentation: presentation,
                    selectedConnection: selectedConnection,
                    compact: geometry.size.width < 900
                )
                    .fixedSize(horizontal: false, vertical: true)
                Divider()

                ZStack {
                    switch workspace {
                    case .live:
                        liveWorkspace(presentation: presentation)
                    case .apps:
                        applicationWorkspace
                    case .routes:
                        routeWorkspace
                    case .history:
                        historyWorkspace(compact: geometry.size.width < 900)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear { updateWorkspaceWidth(geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in
                updateWorkspaceWidth(width)
            }
        }
        .navigationTitle("Traffic")
        .mclashPageSurface()
        .searchable(text: $searchText, prompt: "Host, process, rule, IP, or node")
        .inspector(isPresented: attachedInspectorBinding) {
            connectionInspector(selectedConnection)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 440)
        }
        .task(id: searchText) {
            do {
                try await Task.sleep(for: .milliseconds(180))
                debouncedSearchText = searchText
            } catch {
                return
            }
        }
        .onAppear {
            restoreSortOrderIfNeeded()
            if workspace == .live {
                schedulePresentationRefresh()
            }
        }
        .onChange(of: sortOrder) { _, order in
            persistSortOrder(order)
            schedulePresentationRefresh()
        }
        .onChange(of: debouncedSearchText) { _, _ in
            schedulePresentationRefresh()
        }
        .onChange(of: model.connectionPresentationRevision) { _, _ in
            schedulePresentationRefresh()
        }
        .onChange(of: selectedConnectionIsVisible) { _, isVisible in
            guard selectedConnectionID != nil, !isVisible else { return }
            self.selectedConnectionID = nil
            inspectorPresented = false
        }
        .onChange(of: model.isConnected) { _, isConnected in
            if !isConnected {
                selectedConnectionID = nil
                inspectorPresented = false
            }
        }
        .onChange(of: workspace) { _, workspace in
            selectedConnectionID = nil
            inspectorPresented = false
            if workspace == .live {
                schedulePresentationRefresh()
            } else {
                presentationTask?.cancel()
                presentationTask = nil
                presentationGeneration &+= 1
            }
        }
        .confirmationDialog(
            "Close all \(formattedCount(presentation.totalConnectionCount)) active connections?",
            isPresented: $confirmingCloseAll
        ) {
            Button("Close All Connections", role: .destructive) {
                Task { await model.closeAllConnections() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apps may reconnect automatically. This affects every active connection, not only the current search results.")
        }
        .confirmationDialog(
            "Clear all local traffic history?",
            isPresented: $confirmingClearTrafficHistory
        ) {
            Button("Clear History", role: .destructive) {
                Task { await model.clearTrafficHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Active connections remain connected. Completed session details and persistent aggregate totals are removed; collection restarts from the moment you clear.")
        }
        .onDisappear {
            presentationTask?.cancel()
            presentationTask = nil
            presentationGeneration &+= 1
        }
    }

    @ViewBuilder
    private func trafficHeader(
        presentation: ConnectionPresentationSnapshot,
        selectedConnection: MihomoConnection?,
        compact: Bool
    ) -> some View {
        if compact {
            compactTrafficHeader(
                presentation: presentation,
                selectedConnection: selectedConnection
            )
        } else {
            expandedTrafficHeader(
                presentation: presentation,
                selectedConnection: selectedConnection
            )
        }
    }

    private func expandedTrafficHeader(
        presentation: ConnectionPresentationSnapshot,
        selectedConnection: MihomoConnection?
    ) -> some View {
        HStack(spacing: 12) {
            Picker("Traffic Workspace", selection: $workspace) {
                ForEach(Workspace.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)

            Label(
                trafficHeaderSummary(presentation: presentation),
                systemImage: trafficDataNotice == nil ? "waveform.path.ecg" : "arrow.clockwise"
            )
            .font(.callout.monospacedDigit())
            .foregroundStyle(trafficDataNotice == nil ? Color.secondary : Color.orange)
            .lineLimit(1)
            .layoutPriority(1)
            .help(trafficDataNotice ?? trafficHeaderSummary(presentation: presentation))

            Spacer(minLength: 12)

            if showsProfileScope {
                Picker("Profile scope", selection: $selectedProfileScope) {
                    Text("All Profiles").tag(ProfileScope.all)
                    Text("Default Profile").tag(ProfileScope.defaultProfile)
                    ForEach(model.profiles) { profile in
                        Text(
                            profile.id == model.activeProfileID
                                ? AppLocalization.format("%@ — Default Source", profile.name)
                                : profile.name
                        )
                        .tag(ProfileScope.profile(profile.id))
                    }
                    Divider()
                    Text("Direct / System").tag(ProfileScope.system)
                }
                .frame(minWidth: 130, idealWidth: 170, maxWidth: 220)
                .help("Show merged traffic from every profile or focus on one profile")
            }

            if workspace == .live, selectedConnection != nil {
                inspectorButton(selectedConnection: selectedConnection)
            }

            trafficMoreMenu(presentation: presentation)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, MClashLayout.pagePadding)
        .padding(.vertical, 8)
    }

    private func compactTrafficHeader(
        presentation: ConnectionPresentationSnapshot,
        selectedConnection: MihomoConnection?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Traffic Workspace", selection: $workspace) {
                    ForEach(Workspace.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)

                compactTrafficActions(
                    presentation: presentation,
                    selectedConnection: selectedConnection
                )
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(
                    compactTrafficHeaderSummary(presentation: presentation),
                    systemImage: trafficDataNotice == nil ? "waveform.path.ecg" : "arrow.clockwise"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(trafficDataNotice == nil ? Color.secondary : Color.orange)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .help(trafficDataNotice ?? trafficHeaderSummary(presentation: presentation))
                .accessibilityLabel(trafficHeaderSummary(presentation: presentation))

                if workspace == .live {
                    Text(defaultLiveProfileTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Live controller details currently come from the default profile. Apps, Routes, and History are merged across profiles.")
                } else if showsProfileScope {
                    Picker("Profile scope", selection: $selectedProfileScope) {
                        Text("All Profiles").tag(ProfileScope.all)
                        Text("Default Profile").tag(ProfileScope.defaultProfile)
                        ForEach(model.profiles) { profile in
                            Text(
                                profile.id == model.activeProfileID
                                    ? AppLocalization.format("%@ — Default Source", profile.name)
                                    : profile.name
                            )
                            .tag(ProfileScope.profile(profile.id))
                        }
                        Divider()
                        Text("Direct / System").tag(ProfileScope.system)
                    }
                    .frame(minWidth: 130, idealWidth: 150, maxWidth: 220)
                    .help("Show merged traffic from every profile or focus on one profile")
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, MClashLayout.pagePadding)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func trafficMoreMenu(
        presentation: ConnectionPresentationSnapshot
    ) -> some View {
        if workspace == .live, presentation.hasConnections {
            Menu {
                Button("Close All Connections", role: .destructive) {
                    confirmingCloseAll = true
                }
                .disabled(!model.canPerform(.closeAllConnections))
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More traffic actions")
        } else if workspace == .history, hasTrafficHistoryToClear {
            Menu {
                Button("Clear History", role: .destructive) {
                    confirmingClearTrafficHistory = true
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More traffic actions")
        }
    }

    private var showsProfileScope: Bool {
        workspace != .live
    }

    @ViewBuilder
    private func compactTrafficActions(
        presentation: ConnectionPresentationSnapshot,
        selectedConnection: MihomoConnection?
    ) -> some View {
        if workspace == .live || workspace == .history {
            Menu {
                if workspace == .live {
                    Button {
                        inspectorPresented.toggle()
                    } label: {
                        Label("Connection Inspector", systemImage: "sidebar.right")
                    }
                    .disabled(selectedConnection == nil)

                    Divider()

                    Button("Close All", role: .destructive) {
                        confirmingCloseAll = true
                    }
                    .disabled(
                        !presentation.hasConnections
                            || !model.canPerform(.closeAllConnections)
                    )
                } else {
                    Button("Clear History", role: .destructive) {
                        confirmingClearTrafficHistory = true
                    }
                    .disabled(!hasTrafficHistoryToClear)
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("More traffic actions")
            .popover(isPresented: popoverInspectorBinding, arrowEdge: .top) {
                connectionInspector(selectedConnection)
                    .frame(width: 360, height: 520)
            }
        }
    }

    private var defaultLiveProfileTitle: String {
        let name = model.profiles.first(where: {
            $0.id == model.activeProfileID
        })?.name ?? "Default"
        return "Default Profile · \(name)"
    }

    private func profileTitle(_ target: ProfileTrafficTarget) -> String {
        switch target {
        case .defaultProfile:
            "Default Profile"
        case let .profile(profileID):
            model.profiles.first(where: { $0.id == profileID })?.name
                ?? "Unavailable Profile"
        case .system:
            "Direct / System"
        }
    }

    private func compactTrafficHeaderSummary(
        presentation: ConnectionPresentationSnapshot
    ) -> String {
        if trafficDataNotice != nil { return "Traffic data reconnecting" }
        if workspace == .live { return presentation.connectionCountLabel }
        return workspaceSummary
    }

    private func trafficHeaderSummary(
        presentation: ConnectionPresentationSnapshot
    ) -> String {
        if trafficDataNotice != nil { return "Live data reconnecting · last-known rows shown" }
        if workspace == .live {
            var parts = [presentation.connectionCountLabel]
            if let download = presentation.downloadTotal,
               let upload = presentation.uploadTotal {
                parts.append("↓ \(formattedByteCount(download)) · ↑ \(formattedByteCount(upload))")
            }
            return parts.joined(separator: " · ")
        }
        if unmeasuredHandoffCount > 0 {
            return "\(workspaceSummary) · \(formattedCount(unmeasuredHandoffCount)) pass-through unmeasured"
        }
        return workspaceSummary
    }

    @ViewBuilder
    private func persistentTrafficHistoryControl(compact: Bool) -> some View {
        if compact {
            compactPersistentTrafficHistoryControl
        } else {
            expandedPersistentTrafficHistoryControl
        }
    }

    private var expandedPersistentTrafficHistoryControl: some View {
        HStack(spacing: 10) {
            switch model.trafficHistoryRuntimeState {
            case .notConfigured:
                Label(
                    "Keep private aggregate totals between launches?",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                )
                .font(.callout.weight(.medium))
                .help("Only local aggregates are kept. Destinations, IPs, ports, PIDs, paths, and raw errors are never persisted.")
                Spacer(minLength: 12)
                Button("Session Only") {
                    Task { await model.setPersistentTrafficHistoryEnabled(false) }
                }
                Button("Keep 30 Days") {
                    Task { await model.setPersistentTrafficHistoryEnabled(true) }
                }
                .buttonStyle(.borderedProminent)

            case .sessionOnly:
                Label("Session history only", systemImage: "memorychip")
                    .font(.callout.weight(.medium))
                Text("Completed flow details reset when MClash quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Keep Local History") {
                    Task { await model.setPersistentTrafficHistoryEnabled(true) }
                }

            case .loading:
                ProgressView()
                    .controlSize(.small)
                Text("Opening private local traffic history…")
                    .font(.callout)
                Spacer()

            case let .unavailable(message):
                Label("Persistent history unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .help(message)
                Spacer(minLength: 12)
                Button("Use Session Only") {
                    Task { await model.setPersistentTrafficHistoryEnabled(false) }
                }
                Button("Retry") {
                    Task { await model.setPersistentTrafficHistoryEnabled(true) }
                }
                .buttonStyle(.borderedProminent)

            case let .ready(lastUpdatedAt):
                Picker("History Range", selection: $persistentHistoryPeriod) {
                    Text("Today").tag(TrafficHistoryPeriod.today)
                    Text("This Week").tag(TrafficHistoryPeriod.week)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)

                Text(persistentHistoryCompactSummary(lastUpdatedAt: lastUpdatedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Menu {
                    ForEach(TrafficHistoryRetention.allCases, id: \.rawValue) { retention in
                        Button {
                            Task { await model.setTrafficHistoryRetention(retention) }
                        } label: {
                            if retention == model.trafficHistoryRetention {
                                Label(retentionTitle(retention), systemImage: "checkmark")
                            } else {
                                Text(retentionTitle(retention))
                            }
                        }
                    }
                    Divider()
                    Button("Use Session Only") {
                        Task { await model.setPersistentTrafficHistoryEnabled(false) }
                    }
                } label: {
                    Label("Keep \(model.trafficHistoryRetention.rawValue) Days", systemImage: "calendar")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var compactPersistentTrafficHistoryControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.trafficHistoryRuntimeState {
            case .notConfigured:
                Label(
                    "Keep private aggregate totals between launches?",
                    systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90"
                )
                .font(.callout.weight(.medium))
                .help("Only local aggregates are kept. Destinations, IPs, ports, PIDs, paths, and raw errors are never persisted.")
                HStack(spacing: 10) {
                    Button("Session Only") {
                        Task { await model.setPersistentTrafficHistoryEnabled(false) }
                    }
                    Button("Keep 30 Days") {
                        Task { await model.setPersistentTrafficHistoryEnabled(true) }
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .sessionOnly:
                Label("Session history only", systemImage: "memorychip")
                    .font(.callout.weight(.medium))
                Text("Completed flow details reset when MClash quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Keep Local History") {
                    Task { await model.setPersistentTrafficHistoryEnabled(true) }
                }

            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Opening private local traffic history…")
                        .font(.callout)
                }

            case let .unavailable(message):
                Label("Persistent history unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                    .help(message)
                HStack(spacing: 10) {
                    Button("Use Session Only") {
                        Task { await model.setPersistentTrafficHistoryEnabled(false) }
                    }
                    Button("Retry") {
                        Task { await model.setPersistentTrafficHistoryEnabled(true) }
                    }
                    .buttonStyle(.borderedProminent)
                }

            case let .ready(lastUpdatedAt):
                HStack(spacing: 10) {
                    Picker("History Range", selection: $persistentHistoryPeriod) {
                        Text("Today").tag(TrafficHistoryPeriod.today)
                        Text("This Week").tag(TrafficHistoryPeriod.week)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)

                    Menu {
                        ForEach(TrafficHistoryRetention.allCases, id: \.rawValue) { retention in
                            Button {
                                Task { await model.setTrafficHistoryRetention(retention) }
                            } label: {
                                if retention == model.trafficHistoryRetention {
                                    Label(retentionTitle(retention), systemImage: "checkmark")
                                } else {
                                    Text(retentionTitle(retention))
                                }
                            }
                        }
                        Divider()
                        Button("Use Session Only") {
                            Task { await model.setPersistentTrafficHistoryEnabled(false) }
                        }
                    } label: {
                        Label("Keep \(model.trafficHistoryRetention.rawValue) Days", systemImage: "calendar")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Text(persistentHistoryCompactSummary(lastUpdatedAt: lastUpdatedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func persistentHistoryCompactSummary(lastUpdatedAt: Date?) -> String {
        guard let snapshot = persistentTrafficHistorySnapshot else {
            return "Preparing aggregate totals…"
        }
        var summary = "\(persistentByteCount(snapshot.totals.exactTotalBytes)) measured · \(formattedCount(Int(clamping: snapshot.totals.completedFlowCount))) completed"
        if let lastUpdatedAt {
            summary += " · updated \(lastUpdatedAt.formatted(.relative(presentation: .named)))"
        }
        return summary
    }

    private var persistentTrafficHistorySnapshot: TrafficHistorySnapshot? {
        switch persistentHistoryPeriod {
        case .today: model.trafficHistoryTodaySnapshot
        case .week: model.trafficHistoryWeekSnapshot
        }
    }

    private var hasTrafficHistoryToClear: Bool {
        !historicalEntries.isEmpty
            || (model.trafficHistoryTodaySnapshot?.totals.completedFlowCount ?? 0) > 0
            || (model.trafficHistoryWeekSnapshot?.totals.completedFlowCount ?? 0) > 0
    }

    private func persistentByteCount(_ bytes: UInt64) -> String {
        formattedByteCount(Int64(clamping: bytes))
    }

    private func persistentCoverageTitle(_ coverage: TrafficHistoryCoverage) -> String {
        guard let fraction = coverage.measuredFraction else { return "No payload" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    private func retentionTitle(_ retention: TrafficHistoryRetention) -> String {
        "\(retention.rawValue) days"
    }

    private var trafficDataNotice: String? {
        switch workspace {
        case .live:
            guard model.isConnected,
                  model.liveStreamHealth[.connections]?.hasCurrentData != true else {
                return nil
            }
            return liveStreamDetail(
                model.liveStreamHealth[.connections] ?? .inactive,
                source: "Mihomo connections"
            )
        case .apps, .routes, .history:
            var staleSources: [String] = []
            if model.isConnected,
               model.liveStreamHealth[.connections]?.hasCurrentData != true {
                staleSources.append("Mihomo connections")
            }
            if appRoutingIsActive,
               model.liveStreamHealth[.appRouting]?.hasCurrentData != true {
                staleSources.append("App Routing activity")
            }
            guard !staleSources.isEmpty else { return nil }
            let details = [
                model.isConnected
                    ? model.liveStreamHealth[.connections].map {
                        liveStreamDetail($0, source: "Mihomo connections")
                    }
                    : nil,
                appRoutingIsActive
                    ? model.liveStreamHealth[.appRouting].map {
                        liveStreamDetail($0, source: "App Routing activity")
                    }
                    : nil,
            ].compactMap { $0 }
            return staleSources.joined(separator: " and ")
                + " are stale. Existing ledger rows remain visible as last-known observations. "
                + details.joined(separator: " ")
        }
    }

    private func liveStreamDetail(
        _ health: LiveStreamHealth,
        source: String
    ) -> String {
        let received = health.lastReceivedAt.map {
            "last received \($0.formatted(.relative(presentation: .named)))"
        } ?? "no sample received"
        let attempt = health.retryAttempt > 0
            ? "retry \(formattedCount(health.retryAttempt))"
            : "waiting for the first response"
        let error = health.lastError.map { " Last error: \($0)" } ?? ""
        return "\(source): \(received), \(attempt).\(error)"
    }

    private var unmeasuredHandoffCount: Int {
        model.flowLedger.unmeasuredHandoffCount
    }

    private var appRoutingIsActive: Bool {
        if case .on = model.networkCaptureState { return true }
        return false
    }

    private func inspectorButton(selectedConnection: MihomoConnection?) -> some View {
        Button {
            inspectorPresented.toggle()
        } label: {
            Label("Connection Inspector", systemImage: "sidebar.right")
        }
        .disabled(selectedConnection == nil)
        .help(inspectorPresented ? "Hide Connection Inspector" : "Show Connection Inspector")
        .accessibilityHint("Shows route, process, address, and traffic details for the selected connection")
        .popover(isPresented: popoverInspectorBinding, arrowEdge: .top) {
            connectionInspector(selectedConnection)
                .frame(width: 360, height: 520)
        }
    }

    private var attachedInspectorBinding: Binding<Bool> {
        Binding(
            get: { inspectorPresented && inspectorPresentation == .attached },
            set: { presented in
                guard inspectorPresentation == .attached else { return }
                inspectorPresented = presented
            }
        )
    }

    private var popoverInspectorBinding: Binding<Bool> {
        Binding(
            get: { inspectorPresented && inspectorPresentation == .popover },
            set: { presented in
                guard inspectorPresentation == .popover else { return }
                inspectorPresented = presented
            }
        )
    }

    private func updateWorkspaceWidth(_ width: CGFloat) {
        guard width > 0 else { return }

        // SwiftUI reports the content width after an attached inspector is removed from it.
        // Reconstruct the full workspace so resizing does not immediately reverse the decision.
        let reconstructedFullWidth = width
            + (inspectorPresented && inspectorPresentation == .attached ? 340 : 0)
        let nextPresentation = inspectorPresentation.presentation(
            forFullWidth: reconstructedFullWidth
        )
        if inspectorPresentation != nextPresentation {
            inspectorPresentation = nextPresentation
        }
    }

    private func connectionTable(rows: [ConnectionTableRow]) -> some View {
        Table(rows, selection: $selectedConnectionID, sortOrder: $sortOrder) {
            TableColumn("Destination", value: \.destination) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.destination)
                        .lineLimit(1)
                    Text(row.process)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help("\(row.destination)\n\(row.process)")
            }
            .width(min: 210, ideal: 320, max: 480)

            TableColumn("Route", value: \.chain) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.chain)
                        .lineLimit(1)
                    Text(row.rule)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help("\(row.fullChain)\n\(row.ruleHelp)")
            }
            .width(min: 150, ideal: 240, max: 380)

            TableColumn("Traffic") { row in
                Text(formattedByteCount(saturatingByteSum(row.download, row.upload)))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(
                        AppLocalization.format(
                            "Download %@ · Upload %@",
                            formattedByteCount(row.download),
                            formattedByteCount(row.upload)
                        )
                    )
            }
            .width(min: 92, ideal: 120, max: 150)
        }
        .contextMenu(forSelectionType: String.self) { selection in
            if let identifier = selection.first,
               let row = rows.first(where: { $0.id == identifier }) {
                Button("Close Connection", role: .destructive) {
                    Task { await model.closeConnection(row.id) }
                }
                .disabled(
                    model.isPerforming(.closeAllConnections)
                        || !model.canPerform(.closeConnection(row.id))
                )
            }
        }
        .accessibilityLabel("Active connections")
    }

    private func restoreSortOrderIfNeeded() {
        guard !hasRestoredSortOrder else { return }
        hasRestoredSortOrder = true
        guard let field = ConnectionSortField(rawValue: storedSortField) else { return }
        sortOrder = [
            field.comparator(order: storedSortDescending ? .reverse : .forward)
        ]
    }

    private func persistSortOrder(_ order: [KeyPathComparator<ConnectionTableRow>]) {
        guard hasRestoredSortOrder else { return }
        guard let comparator = order.first,
              let field = ConnectionSortField(keyPath: comparator.keyPath) else {
            storedSortField = ""
            storedSortDescending = false
            return
        }
        storedSortField = field.rawValue
        storedSortDescending = comparator.order == .reverse
    }

    private func schedulePresentationRefresh() {
        guard workspace == .live else { return }
        presentationTask?.cancel()
        presentationGeneration &+= 1
        let generation = presentationGeneration
        let snapshot = model.connections
        let searchText = debouncedSearchText
        let sortOrder = sortOrder

        presentationTask = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                ConnectionPresentationSnapshot(
                    snapshot: snapshot,
                    searchText: searchText,
                    sortOrder: sortOrder
                )
            }
            let next = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, presentationGeneration == generation else { return }
            presentation = next
            presentationTask = nil
        }
    }

    @ViewBuilder
    private func connectionInspector(_ connection: MihomoConnection?) -> some View {
        if let connection {
            ConnectionDetailView(model: model, connection: connection)
        } else {
            ContentUnavailableView(
                "Select a connection",
                systemImage: "sidebar.right",
                description: Text("Choose a row to inspect its route, process, addresses, and metadata.")
            )
        }
    }
}

enum ConnectionInspectorPresentation: Equatable {
    case popover
    case attached

    func presentation(forFullWidth width: CGFloat) -> Self {
        // The hysteresis band keeps the inspector stable while the window is resized near
        // the point where the table and the inspector can both remain comfortably readable.
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

private enum ConnectionSortField: String {
    case destination
    case process
    case chain
    case rule
    case download
    case upload

    init?(keyPath: any PartialKeyPath<ConnectionTableRow> & Sendable) {
        let keyPath = keyPath as AnyKeyPath
        switch keyPath {
        case \ConnectionTableRow.destination: self = .destination
        case \ConnectionTableRow.process: self = .process
        case \ConnectionTableRow.chain: self = .chain
        case \ConnectionTableRow.rule: self = .rule
        case \ConnectionTableRow.download: self = .download
        case \ConnectionTableRow.upload: self = .upload
        default: return nil
        }
    }

    func comparator(order: SortOrder) -> KeyPathComparator<ConnectionTableRow> {
        switch self {
        case .destination: KeyPathComparator(\ConnectionTableRow.destination, order: order)
        case .process: KeyPathComparator(\ConnectionTableRow.process, order: order)
        case .chain: KeyPathComparator(\ConnectionTableRow.chain, order: order)
        case .rule: KeyPathComparator(\ConnectionTableRow.rule, order: order)
        case .download: KeyPathComparator(\ConnectionTableRow.download, order: order)
        case .upload: KeyPathComparator(\ConnectionTableRow.upload, order: order)
        }
    }
}

private struct ConnectionPresentationSnapshot: Sendable {
    static let empty = ConnectionPresentationSnapshot(
        snapshot: nil,
        searchText: "",
        sortOrder: []
    )

    let rows: [ConnectionTableRow]
    let connectionsByIdentifier: [String: MihomoConnection]
    let visibleIdentifiers: Set<String>
    let totalConnectionCount: Int
    let downloadTotal: Int64?
    let uploadTotal: Int64?
    let isFiltering: Bool
    let hasSnapshot: Bool

    init(
        snapshot: MihomoConnectionSnapshot?,
        searchText: String,
        sortOrder: [KeyPathComparator<ConnectionTableRow>]
    ) {
        let connections = snapshot?.connections ?? []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFiltering = !query.isEmpty
        var rows: [ConnectionTableRow] = []
        rows.reserveCapacity(connections.count)
        var connectionsByIdentifier: [String: MihomoConnection] = [:]
        connectionsByIdentifier.reserveCapacity(connections.count)

        for (index, connection) in connections.enumerated() {
            if index.isMultiple(of: 64), Task.isCancelled { break }
            connectionsByIdentifier[connection.id] = connection
            let row = ConnectionTableRow(connection)
            guard !isFiltering || connectionMatchesSearch(connection, row: row, query: query) else {
                continue
            }
            rows.append(row)
        }

        // The controller ingest worker publishes the default newest-first
        // order. Only pay for a second sort when the user selects a column.
        if !Task.isCancelled, !sortOrder.isEmpty {
            rows.sort(using: sortOrder)
        }

        self.rows = rows
        self.connectionsByIdentifier = connectionsByIdentifier
        visibleIdentifiers = Set(rows.map(\.id))
        totalConnectionCount = connections.count
        downloadTotal = snapshot?.downloadTotal
        uploadTotal = snapshot?.uploadTotal
        self.isFiltering = isFiltering
        hasSnapshot = snapshot != nil
    }

    var hasConnections: Bool {
        totalConnectionCount > 0
    }

    var connectionCountLabel: String {
        if !isFiltering {
            return "\(formattedCount(totalConnectionCount)) active"
        }
        return "\(formattedCount(rows.count)) of \(formattedCount(totalConnectionCount)) active"
    }
}

private struct ConnectionTableRow: Identifiable, Sendable {
    let connection: MihomoConnection
    let destination: String
    let process: String
    let chain: String
    let rule: String
    let download: Int64
    let upload: Int64
    let start: String

    var id: String { connection.id }

    init(_ connection: MihomoConnection) {
        self.connection = connection
        let explanation = RoutingExplanation(connection)
        destination = connectionDestination(connection)
        process = nonEmpty(connection.metadata.process) ?? "—"
        chain = explanation.chains.last
            ?? nonEmpty(connection.metadata.specialProxy)
            ?? "—"
        rule = nonEmpty(connection.rule) ?? "—"
        download = connection.download
        upload = connection.upload
        start = connection.start
    }

    var fullChain: String {
        let explanation = RoutingExplanation(connection)
        return explanation.chains.isEmpty ? chain : explanation.chains.joined(separator: " → ")
    }

    var ruleHelp: String {
        guard let payload = nonEmpty(connection.rulePayload) else { return rule }
        return "\(rule) · \(payload)"
    }
}

private struct ConnectionDetailView: View {
    @Bindable var model: AppModel
    let connection: MihomoConnection

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(connectionDestination(connection))
                        .font(.headline)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text(connectionSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button {
                    Task { await model.closeConnection(connection.id) }
                } label: {
                    if model.isPerforming(.closeConnection(connection.id)) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Close", systemImage: "xmark")
                    }
                }
                .disabled(
                    model.isPerforming(.closeAllConnections)
                        || !model.canPerform(.closeConnection(connection.id))
                )
                .help("Close this connection")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ConnectionDetailSection("Traffic") {
                        ConnectionDetailRow(
                            "Download",
                            value: formattedByteCount(connection.download),
                            monospaced: true
                        )
                        ConnectionDetailRow(
                            "Upload",
                            value: formattedByteCount(connection.upload),
                            monospaced: true
                        )
                        ConnectionDetailRow(
                            "Total",
                            value: formattedByteCount(totalTraffic),
                            monospaced: true
                        )
                    }

                    ConnectionDetailSection("Routing") {
                        let explanation = RoutingExplanation(connection)
                        ConnectionDetailRow(
                            "Chain",
                            value: joined(explanation.chains, separator: " → ")
                                ?? nonEmpty(connection.metadata.specialProxy)
                                ?? "—"
                        )
                        detailRow("Provider Chain", value: joined(explanation.providerChains, separator: " → "))
                        ConnectionDetailRow("Rule", value: nonEmpty(connection.rule) ?? "—")
                        detailRow("Rule Payload", value: nonEmpty(connection.rulePayload))
                        detailRow("Special Proxy", value: nonEmpty(connection.metadata.specialProxy))
                        detailRow("Special Rules", value: nonEmpty(connection.metadata.specialRules))
                    }

                    ConnectionDetailSection("Destination") {
                        ConnectionDetailRow(
                            "Address",
                            value: destinationEndpoint ?? connectionDestination(connection),
                            monospaced: true
                        )
                        detailRow("Host", value: nonEmpty(connection.metadata.host))
                        detailRow("Sniffed Host", value: nonEmpty(connection.metadata.sniffHost))
                        detailRow("Remote", value: nonEmpty(connection.metadata.remoteDestination), monospaced: true)
                        detailRow("Location", value: joined(connection.metadata.destinationGeoIP, separator: " / "))
                        detailRow("ASN", value: nonEmpty(connection.metadata.destinationIPASN))
                    }

                    ConnectionDetailSection("Source") {
                        ConnectionDetailRow("Address", value: sourceEndpoint ?? "—", monospaced: true)
                        detailRow("Inbound", value: nonEmpty(connection.metadata.inboundName))
                        detailRow("Inbound Address", value: inboundEndpoint, monospaced: true)
                        detailRow("User", value: nonEmpty(connection.metadata.inboundUser))
                        if let uid = connection.metadata.uid {
                            ConnectionDetailRow("UID", value: String(uid), monospaced: true)
                        }
                        detailRow("Location", value: joined(connection.metadata.sourceGeoIP, separator: " / "))
                        detailRow("ASN", value: nonEmpty(connection.metadata.sourceIPASN))
                    }

                    ConnectionDetailSection("Process") {
                        ConnectionDetailRow("Name", value: nonEmpty(connection.metadata.process) ?? "Unavailable")
                        detailRow("Path", value: nonEmpty(connection.metadata.processPath), monospaced: true)
                    }
                }
                .padding(16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connection details for \(connectionDestination(connection))")
    }

    private var connectionSubtitle: String {
        let transport = [connection.metadata.network, connection.metadata.type]
            .compactMap(nonEmpty)
            .joined(separator: " · ")
        let started = formattedConnectionStart(connection.start)
        return [nonEmpty(transport), nonEmpty(started)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var totalTraffic: Int64 {
        let (total, overflow) = connection.download.addingReportingOverflow(connection.upload)
        return overflow ? Int64.max : total
    }

    private var destinationEndpoint: String? {
        endpoint(
            address: nonEmpty(connection.metadata.destinationIP),
            port: nonEmpty(connection.metadata.destinationPort)
        )
    }

    private var sourceEndpoint: String? {
        endpoint(
            address: nonEmpty(connection.metadata.sourceIP),
            port: nonEmpty(connection.metadata.sourcePort)
        )
    }

    private var inboundEndpoint: String? {
        endpoint(
            address: nonEmpty(connection.metadata.inboundIP),
            port: nonEmpty(connection.metadata.inboundPort)
        )
    }

    @ViewBuilder
    private func detailRow(_ label: String, value: String?, monospaced: Bool = false) -> some View {
        if let value = nonEmpty(value) {
            ConnectionDetailRow(label, value: value, monospaced: monospaced)
        }
    }
}

private struct ConnectionDetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
    }
}

private struct ConnectionDetailRow: View {
    let label: String
    let value: String
    let monospaced: Bool

    init(_ label: String, value: String, monospaced: Bool = false) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        LabeledContent {
            CopyableValueButton(
                value: value,
                accessibilityName: label.lowercased(),
                font: monospaced ? .callout.monospaced() : .callout
            )
                .frame(maxWidth: 220, alignment: .trailing)
        } label: {
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}

private func connectionMatchesSearch(
    _ connection: MihomoConnection,
    row: ConnectionTableRow,
    query: String
) -> Bool {
    let metadata = connection.metadata

    func matches(_ value: String?) -> Bool {
        guard let value = nonEmpty(value) else { return false }
        return value.localizedCaseInsensitiveContains(query)
    }

    return row.destination.localizedCaseInsensitiveContains(query)
        || row.process.localizedCaseInsensitiveContains(query)
        || row.chain.localizedCaseInsensitiveContains(query)
        || row.rule.localizedCaseInsensitiveContains(query)
        || matches(metadata.host)
        || matches(metadata.sniffHost)
        || matches(metadata.destinationIP)
        || matches(metadata.destinationPort)
        || matches(metadata.remoteDestination)
        || matches(metadata.sourceIP)
        || matches(metadata.sourcePort)
        || matches(metadata.processPath)
        || matches(metadata.inboundName)
        || matches(metadata.inboundUser)
        || matches(metadata.network)
        || matches(metadata.type)
        || matches(connection.rulePayload)
        || matches(metadata.specialProxy)
        || matches(metadata.specialRules)
        || connection.chains.contains { $0.localizedCaseInsensitiveContains(query) }
        || connection.providerChains.contains { $0.localizedCaseInsensitiveContains(query) }
}

private func connectionDestination(_ connection: MihomoConnection) -> String {
    let metadata = connection.metadata
    let port = nonEmpty(metadata.destinationPort)
    if let host = nonEmpty(metadata.host) {
        return endpoint(address: host, port: port) ?? host
    }
    if let host = nonEmpty(metadata.sniffHost) {
        return endpoint(address: host, port: port) ?? host
    }
    if let address = nonEmpty(metadata.destinationIP) {
        return endpoint(address: address, port: port) ?? address
    }
    return nonEmpty(metadata.remoteDestination) ?? "Unknown destination"
}

private func endpoint(address: String?, port: String?) -> String? {
    guard let address = nonEmpty(address) else { return nil }
    guard let port = nonEmpty(port) else { return address }
    if address.contains(":"), !address.hasPrefix("[") {
        return "[\(address)]:\(port)"
    }
    return "\(address):\(port)"
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func joined(_ values: [String]?, separator: String) -> String? {
    guard let values else { return nil }
    return nonEmpty(values.compactMap(nonEmpty).joined(separator: separator))
}

private func formattedConnectionStart(_ value: String) -> String {
    let date = RuntimeTimestampParser.date(from: value)
    return date?.formatted(date: .abbreviated, time: .standard) ?? value
}

private func formattedLedgerBytes(_ value: UInt64) -> String {
    formattedByteCount(value > UInt64(Int64.max) ? Int64.max : Int64(value))
}

private func trafficCoverageTitle(_ traffic: FlowLedgerTrafficAggregate) -> String {
    if traffic.notMeasuredAfterHandoffCount > 0 {
        return "Partial · \(formattedCount(traffic.notMeasuredAfterHandoffCount)) handoff"
    }
    if traffic.notApplicableCount > 0, traffic.exactTotalBytes == 0 {
        return "No payload"
    }
    return "Measured"
}

private func trafficCoverageHelp(_ traffic: FlowLedgerTrafficAggregate) -> String {
    FlowLedgerTrafficPresentation.coverageHelp(traffic)
}

private func routeTitle(_ route: FlowLedgerRouteKey) -> String {
    switch route {
    case let .mihomo(rule, _, chain):
        return chain.last ?? rule ?? "Mihomo"
    case let .unresolvedMihomo(rule):
        return rule.map { "Mihomo · \($0)" } ?? "Mihomo · resolving"
    case .direct:
        return "Direct"
    case .rejected:
        return "Rejected"
    case .failOpen:
        return "Fail Open"
    case .relayFailed:
        return "Relay Failed"
    }
}

private func routeSubtitle(
    _ route: FlowLedgerRouteKey,
    traffic: FlowLedgerTrafficAggregate
) -> String {
    switch route {
    case let .mihomo(rule, payload, chain):
        let decision = [rule, payload].compactMap(nonEmpty).joined(separator: " · ")
        let path = chain.joined(separator: " → ")
        return nonEmpty(decision) ?? nonEmpty(path) ?? "Mihomo route"
    case let .unresolvedMihomo(rule):
        return rule.map { "App rule \($0) · awaiting Mihomo correlation" }
            ?? "Awaiting Mihomo correlation"
    case .direct:
        return FlowLedgerTrafficPresentation.directRouteDetail(traffic)
    case .rejected:
        return "Blocked by App Routing"
    case .failOpen:
        return "Relay failed; handed back to macOS"
    case let .relayFailed(rule):
        return rule.map { "App rule \($0)" } ?? "App Routing relay"
    }
}

private func routeHelp(
    _ route: FlowLedgerRouteKey,
    traffic: FlowLedgerTrafficAggregate
) -> String {
    switch route {
    case let .mihomo(rule, payload, chain):
        let decision = [rule, payload].compactMap(nonEmpty).joined(separator: " · ")
        let path = chain.isEmpty ? "No proxy chain reported" : chain.joined(separator: " → ")
        return [nonEmpty(decision), path].compactMap { $0 }.joined(separator: "\n")
    default:
        return "\(routeTitle(route))\n\(routeSubtitle(route, traffic: traffic))"
    }
}

private func ledgerDestination(_ destination: FlowLedgerDestination) -> String {
    let address = nonEmpty(destination.hostname)
        ?? nonEmpty(destination.ipAddress)
        ?? "Unknown destination"
    guard let port = destination.port else { return address }
    return endpoint(address: address, port: String(port)) ?? address
}

private func captureOriginTitle(_ origin: FlowLedgerCaptureOrigin) -> String {
    switch origin {
    case .systemProxy:
        return "System Proxy"
    case .appRouting:
        return "App Routing"
    case .dnsProxy:
        return "DNS Proxy"
    case let .localListener(name):
        return "\(name) · local listener (origin unverified)"
    case .unknown:
        return "Unattributed"
    }
}

private func outcomeTitle(_ outcome: FlowLedgerOutcome) -> String {
    switch outcome {
    case .viaMihomo: "Via Mihomo"
    case .direct: "Direct"
    case .rejected: "Rejected"
    case .failOpen: "Fail Open"
    case .relayFailed: "Failed"
    }
}

private func outcomeColor(_ outcome: FlowLedgerOutcome) -> Color {
    switch outcome {
    case .viaMihomo: .green
    case .direct: .secondary
    case .rejected, .relayFailed: .red
    case .failOpen: .orange
    }
}

private func ledgerTrafficTitle(_ entry: FlowLedgerEntry) -> String {
    if entry.upload == .notMeasuredAfterHandoff
        || entry.download == .notMeasuredAfterHandoff {
        return "Not measured"
    }
    if entry.upload == .notApplicable, entry.download == .notApplicable {
        return "No payload"
    }
    let upload = ledgerExactBytes(entry.upload)
    let download = ledgerExactBytes(entry.download)
    let (total, overflow) = upload.addingReportingOverflow(download)
    return formattedLedgerBytes(overflow ? .max : total)
}

private func ledgerTrafficHelp(_ entry: FlowLedgerEntry) -> String {
    if entry.upload == .notMeasuredAfterHandoff
        || entry.download == .notMeasuredAfterHandoff {
        return "This flow was handed back to macOS. MClash cannot observe its payload after handoff, so it is not reported as 0 B."
    }
    if entry.upload == .notApplicable, entry.download == .notApplicable {
        return "This decision carried no payload."
    }
    return "Download \(formattedLedgerBytes(ledgerExactBytes(entry.download))) · Upload \(formattedLedgerBytes(ledgerExactBytes(entry.upload)))"
}

private func ledgerExactBytes(_ measurement: FlowLedgerByteMeasurement) -> UInt64 {
    guard case let .exact(bytes) = measurement else { return 0 }
    return bytes
}
