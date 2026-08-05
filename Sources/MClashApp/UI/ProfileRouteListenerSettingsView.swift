import SwiftUI

private enum RouteListenerTargetKind: String, CaseIterable, Identifiable {
    case profileRules
    case subRule
    case global
    case policyGroup
    case proxyNode

    var id: Self { self }

    var title: String {
        switch self {
        case .profileRules: "Follow Profile Rules"
        case .subRule: "Named Sub-rule"
        case .global: "Mihomo GLOBAL"
        case .policyGroup: "Policy Group"
        case .proxyNode: "Proxy Node"
        }
    }
}

struct ProfileRouteListenerSettingsEditor: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool

    @State private var listeners: [ProfileRouteListenerSpec]
    @State private var selection: UUID?
    @State private var catalogs: [ProfileID: ProfileRouteTargetCatalog] = [:]
    @State private var loadingCatalogs = Set<ProfileID>()
    @State private var saveTask: Task<Void, Never>?
    @State private var errorMessage: String?

    init(model: AppModel, isPresented: Binding<Bool>) {
        self.model = model
        _isPresented = isPresented
        let listeners = model.profileRuntimePlan.routeListeners
        _listeners = State(initialValue: listeners)
        _selection = State(initialValue: listeners.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Dedicated Proxy Ports")
                    .font(.title2.weight(.semibold))
                Text("Create local HTTP, SOCKS5, or Mixed entry points that follow a Profile's rules or use one fixed route.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Divider()

            HSplitView {
                listenerList
                    .frame(minWidth: 230, idealWidth: 260, maxWidth: 310)
                detailPane
                    .frame(minWidth: 430, maxWidth: .infinity)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                if let visibleErrorMessage {
                    Label(visibleErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Label(
                        "Routing ports listen only on this Mac at 127.0.0.1 and ::1.",
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button("Cancel", role: .cancel) { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSaving)

                    Button(model.isConnected ? "Apply & Restart Cores" : "Save") {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.bar)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 500, idealHeight: 570)
        .interactiveDismissDisabled(isSaving)
        .task(id: selectedProfileID) {
            if let selectedProfileID {
                await loadCatalog(for: selectedProfileID)
            }
        }
    }

    private var listenerList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(listeners) { listener in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: listener.protocolType.symbolName)
                            .foregroundStyle(listener.enabled ? .primary : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(listener.name.isEmpty ? "Untitled Port" : listener.name)
                                .lineLimit(1)
                            Text("\(listener.protocolType.title) · 127.0.0.1:\(listener.port)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(profileName(listener.profileID))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(listener.id)
                    .accessibilityLabel(
                        "\(listener.name), \(listener.protocolType.title), port \(listener.port), \(profileName(listener.profileID))"
                    )
                }
            }
            .overlay {
                if listeners.isEmpty {
                    ContentUnavailableView(
                        "No Dedicated Ports",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("Add a port for an app that needs its own route.")
                    )
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    addListener()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add Routing Port")
                .disabled(model.profiles.isEmpty || isSaving)

                Button {
                    removeSelectedListener()
                } label: {
                    Image(systemName: "minus")
                }
                .help("Remove Routing Port")
                .disabled(selection == nil || isSaving)

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let listenerID = selection,
           let listener = listeners.first(where: { $0.id == listenerID }) {
            Form {
                Section("Entry Point") {
                    Toggle("Enabled", isOn: binding(listenerID, \.enabled))
                    TextField("Name", text: binding(listenerID, \.name))
                    Picker("Profile", selection: binding(listenerID, \.profileID)) {
                        ForEach(model.profiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    Picker("Protocol", selection: binding(listenerID, \.protocolType)) {
                        ForEach(ProfileRouteListenerProtocol.allCases, id: \.self) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    TextField(
                        "Port",
                        value: binding(listenerID, \.port),
                        format: .number.grouping(.never)
                    )
                    .monospacedDigit()
                }

                Section("Routing") {
                    Picker("Target", selection: targetKindBinding(listenerID)) {
                        ForEach(RouteListenerTargetKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }

                    if targetKind(for: listener.target).requiresName {
                        namedTargetPicker(listenerID: listenerID, listener: listener)
                    }

                    routeExplanation(listener)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if listener.enabled,
                   model.profileSessionSpec(for: listener.profileID)?.enabled != true {
                    Section {
                        Label(
                            "Saving will also enable this Profile's dedicated session so the port remains available when another Profile is active.",
                            systemImage: "power"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .onChange(of: listener.profileID) { _, profileID in
                normalizeTarget(listenerID, for: profileID)
                Task { await loadCatalog(for: profileID) }
            }
        } else {
            ContentUnavailableView(
                "Select a Routing Port",
                systemImage: "slider.horizontal.3",
                description: Text("Choose a port on the left to edit its protocol and route.")
            )
        }
    }

    @ViewBuilder
    private func namedTargetPicker(
        listenerID: UUID,
        listener: ProfileRouteListenerSpec
    ) -> some View {
        let kind = targetKind(for: listener.target)
        let options = targetNames(for: kind, listener: listener)
        Picker(kind.title, selection: targetNameBinding(listenerID, kind: kind)) {
            ForEach(options, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        if loadingCatalogs.contains(listener.profileID) {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Loading routing targets…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if options.isEmpty {
            Text(emptyTargetMessage(kind, profileID: listener.profileID))
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func routeExplanation(_ listener: ProfileRouteListenerSpec) -> Text {
        switch listener.target {
        case .profileRules:
            Text("Connections entering this port use the Profile's normal rules.")
        case let .subRule(name):
            Text("Connections start at the named sub-rule “\(name)”.")
        case .global:
            Text("Connections use Mihomo's GLOBAL policy selection.")
        case let .policyGroup(name):
            Text("Every connection is handed directly to policy group “\(name)”.")
        case let .proxyNode(name):
            Text("Every connection is handed directly to node “\(name)”.")
        }
    }

    private var selectedProfileID: ProfileID? {
        guard let selection else { return nil }
        return listeners.first(where: { $0.id == selection })?.profileID
    }

    private var isSaving: Bool { saveTask != nil }

    private var visibleErrorMessage: String? {
        draftValidationMessage ?? errorMessage
    }

    private var draftValidationMessage: String? {
        var plan = model.profileRuntimePlan
        plan.routeListeners = listeners
        for profileID in Set(listeners.filter(\.enabled).map(\.profileID)) {
            if let index = plan.sessions.firstIndex(where: { $0.profileID == profileID }) {
                plan.sessions[index].enabled = true
            }
        }
        do {
            try ProfileRuntimePlanValidator().validate(plan)
        } catch {
            return error.localizedDescription
        }

        for listener in listeners where listener.enabled {
            let catalog = catalogs[listener.profileID]
                ?? .empty(profileID: listener.profileID)
            switch listener.target {
            case .profileRules, .global:
                continue
            case let .subRule(name):
                if !catalog.subRules.contains(name) {
                    return "Choose an available sub-rule for \(listener.name)."
                }
            case let .policyGroup(name):
                if !catalog.policyGroups.contains(name) {
                    return "Choose an available policy group for \(listener.name)."
                }
            case let .proxyNode(name):
                if catalog.isLive, !catalog.proxyNodes.contains(name) {
                    return "Choose an available proxy node for \(listener.name)."
                }
            }
        }
        return nil
    }

    private var canSave: Bool {
        !isSaving
            && draftValidationMessage == nil
            && listeners != model.profileRuntimePlan.routeListeners
            && model.canPerform(.changeRuntimeSettings)
    }

    private func binding<Value>(
        _ id: UUID,
        _ keyPath: WritableKeyPath<ProfileRouteListenerSpec, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                listeners.first(where: { $0.id == id })![keyPath: keyPath]
            },
            set: { value in
                guard let index = listeners.firstIndex(where: { $0.id == id }) else {
                    return
                }
                listeners[index][keyPath: keyPath] = value
                errorMessage = nil
            }
        )
    }

    private func targetKindBinding(_ id: UUID) -> Binding<RouteListenerTargetKind> {
        Binding(
            get: {
                guard let listener = listeners.first(where: { $0.id == id }) else {
                    return .profileRules
                }
                return targetKind(for: listener.target)
            },
            set: { kind in
                guard let index = listeners.firstIndex(where: { $0.id == id }) else {
                    return
                }
                let profileID = listeners[index].profileID
                listeners[index].target = defaultTarget(kind, profileID: profileID)
                errorMessage = nil
            }
        )
    }

    private func targetNameBinding(
        _ id: UUID,
        kind: RouteListenerTargetKind
    ) -> Binding<String> {
        Binding(
            get: {
                guard let listener = listeners.first(where: { $0.id == id }) else {
                    return ""
                }
                return listener.target.presentationName
            },
            set: { name in
                guard let index = listeners.firstIndex(where: { $0.id == id }) else {
                    return
                }
                listeners[index].target = switch kind {
                case .subRule: .subRule(name)
                case .policyGroup: .policyGroup(name)
                case .proxyNode: .proxyNode(name)
                case .profileRules: .profileRules
                case .global: .global
                }
                errorMessage = nil
            }
        )
    }

    private func addListener() {
        guard let profileID = model.activeProfileID ?? model.profiles.first?.id else {
            return
        }
        let reserved = Set(
            listeners.map(\.port)
                + model.profileRuntimePlan.sessions.map(\.mixedPort)
                + [model.profileRuntimePlan.defaultMixedPort]
        )
        let port = (18_080...65_535).first { !reserved.contains($0) }
            ?? (1..<18_080).first { !reserved.contains($0) }
            ?? 18_080
        let listener = ProfileRouteListenerSpec(
            profileID: profileID,
            name: "Routing Port \(listeners.count + 1)",
            protocolType: .socks,
            port: port,
            target: .profileRules
        )
        listeners.append(listener)
        selection = listener.id
        errorMessage = nil
    }

    private func removeSelectedListener() {
        guard let selection,
              let index = listeners.firstIndex(where: { $0.id == selection }) else {
            return
        }
        listeners.remove(at: index)
        self.selection = listeners.indices.contains(index)
            ? listeners[index].id
            : listeners.last?.id
        errorMessage = nil
    }

    private func profileName(_ id: ProfileID) -> String {
        model.profiles.first(where: { $0.id == id })?.name ?? "Unavailable Profile"
    }

    private func loadCatalog(for profileID: ProfileID) async {
        guard !loadingCatalogs.contains(profileID) else { return }
        loadingCatalogs.insert(profileID)
        if profileID == model.activeProfileID
            || model.profileSessionSpec(for: profileID)?.enabled == true {
            _ = await model.refreshProxyWorkspace(for: profileID)
        }
        let catalog = await model.profileRouteTargetCatalog(for: profileID)
        catalogs[profileID] = catalog
        loadingCatalogs.remove(profileID)
    }

    private func normalizeTarget(_ listenerID: UUID, for profileID: ProfileID) {
        guard let index = listeners.firstIndex(where: { $0.id == listenerID }) else {
            return
        }
        let kind = targetKind(for: listeners[index].target)
        listeners[index].target = defaultTarget(kind, profileID: profileID)
    }

    private func targetKind(
        for target: ProfileRouteListenerTarget
    ) -> RouteListenerTargetKind {
        switch target {
        case .profileRules: .profileRules
        case .subRule: .subRule
        case .global: .global
        case .policyGroup: .policyGroup
        case .proxyNode: .proxyNode
        }
    }

    private func defaultTarget(
        _ kind: RouteListenerTargetKind,
        profileID: ProfileID
    ) -> ProfileRouteListenerTarget {
        let catalog = catalogs[profileID] ?? .empty(profileID: profileID)
        return switch kind {
        case .profileRules: .profileRules
        case .subRule: .subRule(catalog.subRules.first ?? "")
        case .global: .global
        case .policyGroup: .policyGroup(catalog.policyGroups.first ?? "")
        case .proxyNode: .proxyNode(catalog.proxyNodes.first ?? "")
        }
    }

    private func targetNames(
        for kind: RouteListenerTargetKind,
        listener: ProfileRouteListenerSpec
    ) -> [String] {
        let catalog = catalogs[listener.profileID]
            ?? .empty(profileID: listener.profileID)
        var values: [String] = switch kind {
        case .subRule: catalog.subRules
        case .policyGroup: catalog.policyGroups
        case .proxyNode: catalog.proxyNodes
        case .profileRules, .global: []
        }
        let current = listener.target.presentationName
        if !current.isEmpty, !values.contains(current) {
            values.insert(current, at: 0)
        }
        return values
    }

    private func emptyTargetMessage(
        _ kind: RouteListenerTargetKind,
        profileID: ProfileID
    ) -> String {
        switch kind {
        case .proxyNode:
            "Connect \(profileName(profileID)) to load provider nodes."
        case .subRule:
            "This Profile does not define any named sub-rules."
        case .policyGroup:
            "This Profile does not define any policy groups."
        case .profileRules, .global:
            ""
        }
    }

    private func save() {
        guard canSave else { return }
        errorMessage = nil
        saveTask = Task {
            do {
                _ = try await model.applyProfileRouteListeners(listeners)
                if !Task.isCancelled {
                    await MainActor.run {
                        saveTask = nil
                        isPresented = false
                    }
                }
            } catch is CancellationError {
                await MainActor.run { saveTask = nil }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    saveTask = nil
                }
            }
        }
    }
}

private extension RouteListenerTargetKind {
    var requiresName: Bool {
        switch self {
        case .subRule, .policyGroup, .proxyNode: true
        case .profileRules, .global: false
        }
    }
}

extension ProfileRouteListenerProtocol {
    var title: String {
        switch self {
        case .mixed: "Mixed"
        case .socks: "SOCKS5"
        case .http: "HTTP"
        }
    }

    var symbolName: String {
        switch self {
        case .mixed: "arrow.triangle.branch"
        case .socks: "point.3.connected.trianglepath.dotted"
        case .http: "network"
        }
    }
}
