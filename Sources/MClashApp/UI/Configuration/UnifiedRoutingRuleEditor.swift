import AppKit
import SwiftUI

/// A task-oriented editor for strategy-owned routing rules.
///
/// The editor deliberately speaks in terms of "when" and "then".  It does
/// not expose imported profile rules: callers provide the available MClash
/// proxy groups and receive a `RoutingRule` owned by the configuration layer.
///
/// This view is intentionally independent from `AppModel`, so it can be used
/// by `ConfigurationEditorSheet`, a workbench inspector, or a quick-create
/// command without coupling those surfaces to draft state.
struct UnifiedRoutingRuleEditor: View {
    let proxyGroups: [ProxyGroup]
    let applicationCandidates: [ApplicationCaptureCandidate]
    let initialRule: RoutingRule?
    let onSave: (RoutingRule) -> Void
    let onCancel: () -> Void

    @State private var criteria: [RuleCriterion]
    @State private var action: RuleAction
    @State private var priority: Int
    @State private var enabled: Bool
    @State private var validationMessage: String?

    init(
        rule: RoutingRule? = nil,
        proxyGroups: [ProxyGroup],
        applicationCandidates: [ApplicationCaptureCandidate] = [],
        onSave: @escaping (RoutingRule) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.proxyGroups = proxyGroups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.applicationCandidates = applicationCandidates.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        self.initialRule = rule
        self.onSave = onSave
        self.onCancel = onCancel
        _criteria = State(initialValue: Self.criteria(from: rule))
        _action = State(initialValue: RuleAction(from: rule?.action))
        _priority = State(initialValue: rule?.priority ?? 100)
        _enabled = State(initialValue: rule?.enabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    whenSection
                    thenSection
                    previewSection
                    if let validationMessage {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 560)
        .onChange(of: criteria) { _, _ in validationMessage = nil }
        .onChange(of: action) { _, _ in validationMessage = nil }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(initialRule == nil ? "New routing rule" : "Edit routing rule")
                    .font(.title2.weight(.semibold))
                Text("Choose what traffic matches, then decide where it goes.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Spacer()
            Toggle("Enabled", isOn: $enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Rule enabled")
        }
        .padding(24)
    }

    private var whenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("When traffic matches", systemImage: "line.3.horizontal.decrease.circle")
            Text("Conditions in one rule are combined with AND. Add another condition when a rule should be more specific.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach($criteria) { $criterion in
                RuleCriterionRow(
                    criterion: $criterion,
                    applicationCandidates: applicationCandidates,
                    onRemove: { removeCriterion(id: criterion.id) }
                )
            }

            Menu {
                ForEach(RuleCriterion.Kind.allCases) { kind in
                    Button {
                        criteria.append(RuleCriterion(kind: kind))
                    } label: {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            } label: {
                Label("Add condition", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Adds an application, domain, IP, port, or protocol condition")
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var thenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Then send traffic to", systemImage: "arrow.turn.down.right")
            Picker("Action", selection: $action) {
                Text("Direct — connect without a proxy").tag(RuleAction.direct)
                Text("Reject — block the connection").tag(RuleAction.reject)
                if proxyGroups.isEmpty {
                    Text("Proxy group — create a group first").tag(RuleAction.proxyGroup(nil))
                } else {
                    ForEach(proxyGroups) { group in
                        Text("Group — \(group.name)").tag(RuleAction.proxyGroup(group.id))
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 420, alignment: .leading)

            HStack {
                Text("Priority")
                TextField("100", value: $priority, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text("Lower numbers are evaluated first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Rule preview", systemImage: "text.quote")
            Text(preview)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityLabel("Rule preview: \(preview)")
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Save rule", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func sectionHeading(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
    }

    private func removeCriterion(id: UUID) {
        criteria.removeAll { $0.id == id }
        if criteria.isEmpty { criteria = [RuleCriterion(kind: .application)] }
    }

    private var preview: String {
        let conditions = criteria.map(\.summary).filter { !$0.isEmpty }
        let when = conditions.isEmpty ? "any traffic" : conditions.joined(separator: " and ")
        return "When \(when), then \(action.summary(proxyGroups: proxyGroups))."
    }

    private func save() {
        let matchers = criteria.compactMap(\.matcher)
        guard !matchers.isEmpty else {
            validationMessage = "Add at least one condition before saving."
            return
        }
        guard (1...65535).contains(priority) else {
            validationMessage = "Priority must be between 1 and 65535."
            return
        }
        if case let .proxyGroup(groupID) = action,
           (groupID == nil || !proxyGroups.contains(where: { $0.id == groupID })) {
            validationMessage = "Choose an available MClash proxy group."
            return
        }

        let routingAction: RoutingAction
        switch action {
        case .direct: routingAction = .direct
        case .reject: routingAction = .reject
        case let .proxyGroup(groupID): routingAction = .proxyGroup(groupID!)
        }
        onSave(RoutingRule(
            id: initialRule?.id ?? RoutingRuleID(),
            enabled: enabled,
            priority: priority,
            matchers: matchers,
            action: routingAction,
            unavailableFallback: initialRule?.unavailableFallback ?? .direct,
            workspaceScope: initialRule?.workspaceScope
        ))
    }

    private static func criteria(from rule: RoutingRule?) -> [RuleCriterion] {
        guard let rule, !rule.matchers.isEmpty else { return [RuleCriterion(kind: .application)] }
        return rule.matchers.map(RuleCriterion.init(matcher:))
    }
}

private struct RuleCriterion: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case application, domain, ipCIDR, port, transport
        var id: String { rawValue }
        var title: String {
            switch self {
            case .application: "Application"
            case .domain: "Domain"
            case .ipCIDR: "IP / CIDR"
            case .port: "Port"
            case .transport: "Protocol"
            }
        }
        var symbol: String {
            switch self {
            case .application: "app.badge"
            case .domain: "globe"
            case .ipCIDR: "network"
            case .port: "number"
            case .transport: "arrow.left.arrow.right"
            }
        }
    }

    enum DomainMode: String, CaseIterable, Identifiable {
        case exact, suffix, wildcard
        var id: String { rawValue }
        var title: String {
            switch self {
            case .exact: "Exact domain"
            case .suffix: "Domain and subdomains"
            case .wildcard: "Wildcard pattern"
            }
        }
    }

    let id: UUID
    var kind: Kind
    var value: String
    var domainMode: DomainMode
    var protocolValue: String

    init(id: UUID = UUID(), kind: Kind, value: String = "", domainMode: DomainMode = .suffix, protocolValue: String = "TCP") {
        self.id = id
        self.kind = kind
        self.value = value
        self.domainMode = domainMode
        self.protocolValue = protocolValue
    }

    init(matcher: RoutingMatcher) {
        switch matcher {
        case let .application(value): self.init(kind: .application, value: value)
        case let .domainExact(value): self.init(kind: .domain, value: value, domainMode: .exact)
        case let .domainSuffix(value): self.init(kind: .domain, value: value, domainMode: .suffix)
        case let .domainWildcard(value): self.init(kind: .domain, value: value, domainMode: .wildcard)
        case let .ipCIDR(value): self.init(kind: .ipCIDR, value: value)
        case let .port(value): self.init(kind: .port, value: String(value))
        case let .portRange(value): self.init(kind: .port, value: "\(value.lowerBound)-\(value.upperBound)")
        case let .transport(value): self.init(kind: .transport, protocolValue: value.uppercased())
        case let .processPath(value): self.init(kind: .application, value: value)
        case let .userID(value): self.init(kind: .application, value: String(value))
        }
    }

    var matcher: RoutingMatcher? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .application:
            guard !trimmed.isEmpty, !trimmed.contains(where: { $0 == "\n" || $0 == "\r" }) else { return nil }
            return .application(trimmed.lowercased())
        case .domain:
            guard !trimmed.isEmpty, !trimmed.contains(where: { $0 == "\n" || $0 == "\r" }) else { return nil }
            switch domainMode {
            case .exact: return .domainExact(trimmed.lowercased())
            case .suffix: return .domainSuffix(trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            case .wildcard: return .domainWildcard(trimmed.lowercased())
            }
        case .ipCIDR:
            return trimmed.isEmpty ? nil : .ipCIDR(trimmed)
        case .port:
            let parts = trimmed.split(separator: "-", omittingEmptySubsequences: true)
            let values = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard !parts.isEmpty, values.count == parts.count, values.allSatisfy({ (1...65535).contains($0) }) else { return nil }
            if values.count == 1 { return .port(values[0]) }
            guard values.count == 2, values[0] <= values[1] else { return nil }
            return .portRange(values[0]...values[1])
        case .transport:
            return ["TCP", "UDP"].contains(protocolValue.uppercased()) ? .transport(protocolValue.lowercased()) : nil
        }
    }

    var summary: String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .application: return trimmed.isEmpty ? "an application" : "application matching \(trimmed)"
        case .domain:
            let label = domainMode == .wildcard ? "domain wildcard" : domainMode == .exact ? "domain" : "domain or subdomain"
            return trimmed.isEmpty ? "a domain" : "\(label) \(trimmed)"
        case .ipCIDR: return trimmed.isEmpty ? "an IP/CIDR" : "IP/CIDR \(trimmed)"
        case .port: return trimmed.isEmpty ? "a port" : "port \(trimmed)"
        case .transport: return "\(protocolValue) traffic"
        }
    }
}

private enum RuleAction: Hashable {
    case direct, reject, proxyGroup(ProxyGroupID?)

    init(from action: RoutingAction?) {
        switch action {
        case .direct: self = .direct
        case .reject: self = .reject
        case let .proxyGroup(id): self = .proxyGroup(id)
        case nil: self = .direct
        }
    }

    var isNonGroup: Bool {
        switch self { case .direct, .reject: true; case .proxyGroup: false }
    }

    func summary(proxyGroups: [ProxyGroup]) -> String {
        switch self {
        case .direct: return "Direct"
        case .reject: return "Reject"
        case let .proxyGroup(id): return "proxy group \(proxyGroups.first(where: { $0.id == id })?.name ?? "(not selected)")"
        }
    }
}

private struct RuleCriterionRow: View {
    @Binding var criterion: RuleCriterion
    let applicationCandidates: [ApplicationCaptureCandidate]
    let onRemove: () -> Void
    @State private var applicationSearch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Match type", selection: $criterion.kind) {
                    ForEach(RuleCriterion.Kind.allCases) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer()
                Button("Remove", systemImage: "minus.circle", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(criterion.kind.title) condition")
            }
            editor
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder private var editor: some View {
        switch criterion.kind {
        case .application:
            VStack(alignment: .leading, spacing: 8) {
                TextField("App name, bundle ID, or wildcard (for example com.example.*)", text: $criterion.value)
                    .textFieldStyle(.roundedBorder)
                if !applicationCandidates.isEmpty {
                    TextField("Search installed applications", text: $applicationSearch)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(filteredCandidates.prefix(12)) { candidate in
                                Button(candidate.displayName) {
                                    criterion.value = candidate.fallbackIdentifierPatterns.first ?? candidate.bundleIdentifier ?? candidate.displayName
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help(candidate.bundleIdentifier ?? candidate.executablePath)
                            }
                        }
                    }
                }
                Text("Use * as a wildcard. The application identity is matched by its stable identifier; selecting a discovered app fills the safest pattern.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .domain:
            HStack {
                Picker("Domain match", selection: $criterion.domainMode) {
                    ForEach(RuleCriterion.DomainMode.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 190)
                TextField("example.com or *.example.com", text: $criterion.value)
                    .textFieldStyle(.roundedBorder)
            }
        case .ipCIDR:
            TextField("192.168.0.0/16 or 2001:db8::/32", text: $criterion.value)
                .textFieldStyle(.roundedBorder)
        case .port:
            TextField("443 or 8000-9000", text: $criterion.value)
                .textFieldStyle(.roundedBorder)
        case .transport:
            Picker("Transport protocol", selection: $criterion.protocolValue) {
                Text("TCP").tag("TCP")
                Text("UDP").tag("UDP")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
        }
    }

    private var filteredCandidates: [ApplicationCaptureCandidate] {
        let query = applicationSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return applicationCandidates }
        return applicationCandidates.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.fallbackIdentifierPatterns.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }
}
