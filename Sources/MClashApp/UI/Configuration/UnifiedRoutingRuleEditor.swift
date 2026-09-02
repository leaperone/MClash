import AppKit
import MClashNetworkShared
import SwiftUI
import UniformTypeIdentifiers

/// A task-oriented editor for strategy-owned routing rules.
///
/// The editor deliberately speaks in terms of "when" and "then".  It does
/// not expose imported profile rules: callers provide the available MClash
/// proxy groups and receive a `RoutingRule` owned by the configuration layer.
///
/// This view is intentionally independent from `AppModel`, so it can be used
/// by `ConfigurationEditorSheet` or a quick-create command without coupling
/// those surfaces to draft state.
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
        let availableProxyGroups = proxyGroups.filter(\.enabled)
        self.proxyGroups = availableProxyGroups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.applicationCandidates = applicationCandidates.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        self.initialRule = rule
        self.onSave = onSave
        self.onCancel = onCancel
        _criteria = State(initialValue: Self.criteria(from: rule))
        let defaultGroup = availableProxyGroups.first(where: {
            $0.name == ConfigurationProxyGroupPreset.mainGroupName
                || $0.name == "MClash Select"
        }) ?? availableProxyGroups.first
        _action = State(initialValue: rule.map { RuleAction(from: $0.action) }
            ?? defaultGroup.map { .proxyGroup($0.id) }
            ?? .direct)
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
                        Text(AppLocalization.string(initialRule == nil ? "New routing rule" : "Edit routing rule"))
                    .font(.title2.weight(.semibold))
                Text(AppLocalization.string("Choose what traffic matches, then decide where it goes."))
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Spacer()
            Toggle(AppLocalization.string("Enabled"), isOn: $enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(AppLocalization.string("Rule enabled"))
        }
        .padding(24)
    }

    private var whenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(AppLocalization.string("When traffic matches"), systemImage: "line.3.horizontal.decrease.circle")
            Text(AppLocalization.string("Different condition types are combined with AND. Multiple values of the same type are combined with OR."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if initialRule == nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { ruleTemplates }
                    VStack(alignment: .leading, spacing: 8) { ruleTemplates }
                }
            }

            ForEach($criteria) { $criterion in
                RuleCriterionRow(
                    criterion: $criterion,
                    applicationCandidates: applicationCandidates,
                    onRemove: { removeCriterion(id: criterion.id) }
                )
            }

            Menu {
                ForEach(RuleCriterion.Kind.editableCases) { kind in
                    Button {
                        criteria.append(RuleCriterion(kind: kind))
                    } label: {
                        Label(AppLocalization.string(kind.title), systemImage: kind.symbol)
                    }
                }
            } label: {
                Label(AppLocalization.string("Add condition"), systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)
            .accessibilityHint(AppLocalization.string("Adds an application, domain, IP, port, or protocol condition"))
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var thenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(AppLocalization.string("Then send traffic to"), systemImage: "arrow.turn.down.right")
            Picker(AppLocalization.string("Action"), selection: $action) {
                Text(AppLocalization.string("Direct — connect without a proxy")).tag(RuleAction.direct)
                Text(AppLocalization.string("Reject — block the connection")).tag(RuleAction.reject)
                if proxyGroups.isEmpty {
                    Text(AppLocalization.string("Node group — create a group first")).tag(RuleAction.proxyGroup(nil))
                } else {
                    ForEach(proxyGroups) { group in
                        Text(configurationDisplayName(group.name)).tag(RuleAction.proxyGroup(group.id))
                    }
                    if case let .proxyGroup(existingID) = action,
                       let existingID,
                       !proxyGroups.contains(where: { $0.id == existingID }) {
                        Text(AppLocalization.string("Unavailable group (choose another)"))
                            .tag(RuleAction.proxyGroup(existingID))
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 420, alignment: .leading)

            Text(AppLocalization.string("Use Node Selection as the stable parent when rules should follow regional or automatic groups."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(AppLocalization.string("Priority"))
                TextField("100", value: $priority, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text(AppLocalization.string("Lower numbers are evaluated first"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(AppLocalization.string("Rule preview"), systemImage: "text.quote")
            Text(preview)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityLabel(AppLocalization.format("Rule preview: %@", preview))
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(AppLocalization.string("Cancel"), action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(AppLocalization.string("Save rule"), action: save)
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

    @ViewBuilder
    private var ruleTemplates: some View {
        Button(AppLocalization.string("Domain")) {
            criteria = [RuleCriterion(kind: .domain)]
        }
        Button(AppLocalization.string("Application")) {
            criteria = [RuleCriterion(kind: .application)]
        }
        Button(AppLocalization.string("GFW List")) {
            criteria = [RuleCriterion(kind: .geoSite, value: "gfw")]
        }
        Button(AppLocalization.string("China IP")) {
            criteria = [RuleCriterion(kind: .geoIP, value: "CN")]
        }
    }

    private var preview: String {
        let andWord = AppLocalization.string("and")
        let when = groupedConditionSummaries.isEmpty
            ? AppLocalization.string("any traffic")
            : groupedConditionSummaries.joined(separator: " \(andWord) ")
        return AppLocalization.format(
            "When %@, send traffic to %@.",
            when,
            action.summary(proxyGroups: proxyGroups)
        )
    }

    /// CaptureRule evaluates fields (application, destination, protocol and
    /// port) with AND semantics, while values inside one field are alternatives.
    /// Grouping here keeps the preview faithful to the runtime evaluator.
    private var groupedConditionSummaries: [String] {
        let orWord = AppLocalization.string("or")
        let grouped = Dictionary(grouping: criteria.filter { !$0.summary.isEmpty }, by: \.family)
        return RuleCriterion.Family.allCases.compactMap { family in
            let values = grouped[family, default: []].map(\.summary)
            guard !values.isEmpty else { return nil }
            return values.count == 1
                ? values[0]
                : AppLocalization.format(
                    "%@: %@",
                    family.title,
                    values.joined(separator: " \(orWord) ")
                )
        }
    }

    private func save() {
        if let invalid = criteria.compactMap(\.validationMessage).first {
            validationMessage = invalid
            return
        }
        let matchers = criteria.compactMap(\.matcher)
        guard !matchers.isEmpty else {
            validationMessage = AppLocalization.string("Add at least one condition before saving.")
            return
        }
        guard (1...65535).contains(priority) else {
            validationMessage = AppLocalization.string("Priority must be between 1 and 65535.")
            return
        }
        if case let .proxyGroup(groupID) = action,
           (groupID == nil || !proxyGroups.contains(where: { $0.id == groupID })) {
            validationMessage = AppLocalization.string("Choose an available MClash node group.")
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
        guard let rule, !rule.matchers.isEmpty else { return [RuleCriterion(kind: .domain)] }
        return rule.matchers.map(RuleCriterion.init(matcher:))
    }
}

private struct RuleCriterion: Identifiable, Equatable {
    enum Family: String, CaseIterable, Hashable {
        case source, destination, protocolValue, port

        var title: String {
            switch self {
            case .source: AppLocalization.string("Application / process")
            case .destination: AppLocalization.string("Destination")
            case .protocolValue: AppLocalization.string("Protocol")
            case .port: AppLocalization.string("Port")
            }
        }
    }

    enum Kind: String, CaseIterable, Identifiable, Hashable {
        case application, process, processName, userID, domain, ipCIDR
        case geoIP, geoIP6, geoSite, port, transport
        var id: String { rawValue }
        static var editableCases: [Self] {
            allCases.filter { $0 != .geoIP6 }
        }
        var title: String {
            switch self {
            case .application: AppLocalization.string("Application")
            case .process: AppLocalization.string("Process path")
            case .processName: AppLocalization.string("Process name")
            case .userID: AppLocalization.string("User ID")
            case .domain: AppLocalization.string("Domain")
            case .ipCIDR: AppLocalization.string("IP / CIDR")
            case .geoIP: AppLocalization.string("GEOIP country")
            case .geoIP6: AppLocalization.string("GEOIP6 (unsupported)")
            case .geoSite: AppLocalization.string("GEOSITE database")
            case .port: AppLocalization.string("Port")
            case .transport: AppLocalization.string("Protocol")
            }
        }
        var symbol: String {
            switch self {
            case .application: "app.badge"
            case .process: "terminal"
            case .processName: "text.magnifyingglass"
            case .userID: "person.crop.circle"
            case .domain: "globe"
            case .ipCIDR: "network"
            case .geoIP, .geoIP6, .geoSite: "globe.americas"
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
            case .exact: AppLocalization.string("Exact domain")
            case .suffix: AppLocalization.string("Domain and subdomains")
            case .wildcard: AppLocalization.string("Wildcard pattern")
            }
        }
    }

    let id: UUID
    var kind: Kind
    var value: String
    var domainMode: DomainMode
    var protocolValue: String

    var family: Family {
        switch kind {
        case .application, .process, .processName, .userID: .source
        case .domain, .ipCIDR, .geoIP, .geoIP6, .geoSite: .destination
        case .transport: .protocolValue
        case .port: .port
        }
    }

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
        case let .processName(value): self.init(kind: .processName, value: value)
        case let .domainExact(value): self.init(kind: .domain, value: value, domainMode: .exact)
        case let .domainSuffix(value): self.init(kind: .domain, value: value, domainMode: .suffix)
        case let .domainWildcard(value): self.init(kind: .domain, value: value, domainMode: .wildcard)
        case let .ipCIDR(value): self.init(kind: .ipCIDR, value: value)
        case let .geoIP(value): self.init(kind: .geoIP, value: value)
        case let .geoIP6(value): self.init(kind: .geoIP6, value: value)
        case let .geoSite(value): self.init(kind: .geoSite, value: value)
        case let .port(value): self.init(kind: .port, value: String(value))
        case let .portRange(value): self.init(kind: .port, value: "\(value.lowerBound)-\(value.upperBound)")
        case let .transport(value): self.init(kind: .transport, protocolValue: value.uppercased())
        case let .processPath(value): self.init(kind: .process, value: value)
        case let .userID(value): self.init(kind: .userID, value: String(value))
        }
    }

    var matcher: RoutingMatcher? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .application:
            guard !trimmed.isEmpty, !trimmed.contains(where: { $0 == "\n" || $0 == "\r" }) else { return nil }
            return .application(trimmed.lowercased())
        case .process:
            guard !trimmed.isEmpty, !trimmed.contains(where: { $0 == "\n" || $0 == "\r" }) else { return nil }
            return .processPath(trimmed)
        case .processName:
            guard !trimmed.isEmpty, !trimmed.contains(where: { $0 == "\n" || $0 == "\r" }) else { return nil }
            return .processName(trimmed)
        case .userID:
            guard let value = UInt32(trimmed) else { return nil }
            return .userID(value)
        case .domain:
            guard !trimmed.isEmpty, !trimmed.contains(where: { $0 == "\n" || $0 == "\r" }) else { return nil }
            switch domainMode {
            case .exact: return .domainExact(trimmed.lowercased())
            case .suffix: return .domainSuffix(trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            case .wildcard: return .domainWildcard(trimmed.lowercased())
            }
        case .ipCIDR:
            return trimmed.isEmpty ? nil : .ipCIDR(trimmed)
        case .geoIP:
            return trimmed.isEmpty ? nil : .geoIP(trimmed.uppercased())
        case .geoIP6:
            return trimmed.isEmpty ? nil : .geoIP6(trimmed.uppercased())
        case .geoSite:
            return trimmed.isEmpty ? nil : .geoSite(trimmed.lowercased())
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
        case .application:
            return trimmed.isEmpty ? AppLocalization.string("an application") : AppLocalization.format("App %@", trimmed)
        case .process:
            return trimmed.isEmpty ? AppLocalization.string("a process path") : AppLocalization.format("Process %@", trimmed)
        case .processName:
            return trimmed.isEmpty ? AppLocalization.string("a process name") : AppLocalization.format("Process %@", trimmed)
        case .userID:
            return trimmed.isEmpty ? AppLocalization.string("a user ID") : AppLocalization.format("User %@", trimmed)
        case .domain:
            let label = domainMode == .wildcard
                ? AppLocalization.string("domain wildcard")
                : domainMode == .exact
                    ? AppLocalization.string("domain")
                    : AppLocalization.string("domain or subdomain")
            return trimmed.isEmpty ? AppLocalization.string("a domain") : "\(label) \(trimmed)"
        case .ipCIDR: return trimmed.isEmpty ? AppLocalization.string("an IP/CIDR") : trimmed
        case .geoIP: return trimmed.isEmpty ? AppLocalization.string("a GEOIP country") : AppLocalization.format("GEOIP %@", trimmed.uppercased())
        case .geoIP6: return trimmed.isEmpty ? AppLocalization.string("a GEOIP6 country") : AppLocalization.format("GEOIP6 %@", trimmed.uppercased())
        case .geoSite: return trimmed.isEmpty ? AppLocalization.string("a GEOSITE name") : AppLocalization.format("GEOSITE %@", trimmed.lowercased())
        case .port: return trimmed.isEmpty ? AppLocalization.string("a port") : AppLocalization.format("Port %@", trimmed)
        case .transport: return AppLocalization.format("%@ traffic", protocolValue)
        }
    }

    var validationMessage: String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AppLocalization.string("Enter a value.") }
        do {
            switch kind {
            case .application:
                _ = try ApplicationIdentifierPatternMatcher(pattern: trimmed)
            case .process:
                guard trimmed.hasPrefix("/"),
                      !trimmed.contains(where: { $0 == "\n" || $0 == "\r" }) else {
                    return AppLocalization.string("Process path must be an absolute path without line breaks.")
                }
            case .processName:
                guard !trimmed.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "," }) else {
                    return AppLocalization.string("Process name contains an unsafe character.")
                }
            case .userID:
                guard UInt32(trimmed) != nil else { return AppLocalization.string("User ID must be a number.") }
            case .domain:
                switch domainMode {
                case .exact: _ = try HostMatcher(kind: .exact, value: trimmed)
                case .suffix: _ = try HostMatcher(kind: .suffix, value: trimmed)
                case .wildcard: _ = try HostPatternMatcher(pattern: trimmed)
                }
            case .ipCIDR:
                _ = try IPNetwork(trimmed)
            case .geoIP:
                guard !trimmed.contains(",") else {
                    return AppLocalization.string("GEO values must not contain commas.")
                }
            case .geoIP6:
                return AppLocalization.string("Mihomo does not support GEOIP6 rules. Use IP-CIDR6 for IPv6 networks.")
            case .geoSite:
                guard !trimmed.contains(",") else {
                    return AppLocalization.string("GEO values must not contain commas.")
                }
            case .port, .transport:
                guard matcher != nil else {
                    return kind == .port
                        ? AppLocalization.string("Enter a port from 1 to 65535, or a valid range.")
                        : AppLocalization.string("Choose TCP or UDP.")
                }
            }
        } catch {
            return error.localizedDescription
        }
        return nil
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
        case .direct: return AppLocalization.string("Direct")
        case .reject: return AppLocalization.string("Reject")
        case let .proxyGroup(id):
            return configurationDisplayName(
                proxyGroups.first(where: { $0.id == id })?.name
                    ?? AppLocalization.string("(not selected)")
            )
        }
    }
}

private struct RuleCriterionRow: View {
    @Binding var criterion: RuleCriterion
    let applicationCandidates: [ApplicationCaptureCandidate]
    let onRemove: () -> Void
    @State private var applicationSearch = ""
    @State private var applicationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker(AppLocalization.string("Match type"), selection: $criterion.kind) {
                    ForEach(RuleCriterion.Kind.allCases) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Spacer()
                Button(AppLocalization.string("Remove"), systemImage: "minus.circle", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(AppLocalization.format("Remove %@ condition", criterion.kind.title))
            }
            editor
            if let validationMessage = criterion.validationMessage,
               !criterion.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
    }

    @ViewBuilder private var editor: some View {
        switch criterion.kind {
        case .application:
            VStack(alignment: .leading, spacing: 8) {
                TextField(AppLocalization.string("App name, bundle ID, or wildcard (for example com.example.*)"), text: $criterion.value)
                    .textFieldStyle(.roundedBorder)
                Button(AppLocalization.string("Choose an installed app…")) {
                    chooseInstalledApplication()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if !applicationCandidates.isEmpty {
                    TextField(AppLocalization.string("Search installed applications"), text: $applicationSearch)
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
                } else {
                    Text(AppLocalization.string("No running apps were detected. Enter a bundle ID or use the installed-app picker."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let applicationError {
                    Label(applicationError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text(AppLocalization.string("Use * as a wildcard. The application identity is matched by its stable identifier; selecting a discovered app fills the safest pattern."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .process:
            TextField(AppLocalization.string("Executable path"), text: $criterion.value)
                .textFieldStyle(.roundedBorder)
        case .processName:
            TextField(AppLocalization.string("Process name (for example curl)"), text: $criterion.value)
                .textFieldStyle(.roundedBorder)
        case .userID:
            TextField(AppLocalization.string("Numeric user ID"), text: $criterion.value)
                .textFieldStyle(.roundedBorder)
        case .domain:
            HStack {
                Picker(AppLocalization.string("Domain match"), selection: $criterion.domainMode) {
                    ForEach(RuleCriterion.DomainMode.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 190)
                TextField(AppLocalization.string("example.com or *.example.com"), text: $criterion.value)
                    .textFieldStyle(.roundedBorder)
            }
        case .ipCIDR:
            TextField(AppLocalization.string("192.168.0.0/16 or 2001:db8::/32"), text: $criterion.value)
                .textFieldStyle(.roundedBorder)
        case .geoIP, .geoIP6:
            HStack {
                TextField(
                    AppLocalization.string("Country code, for example CN or US"),
                    text: $criterion.value
                )
                .textFieldStyle(.roundedBorder)
                Button(AppLocalization.string("CN")) { criterion.value = "CN" }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button(AppLocalization.string("US")) { criterion.value = "US" }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .geoSite:
            HStack {
                Menu {
                    Button("gfw") { criterion.value = "gfw" }
                    Button("google") { criterion.value = "google" }
                    Button("cn") { criterion.value = "cn" }
                    Button("private") { criterion.value = "private" }
                } label: {
                    Label(AppLocalization.string("Database set"), systemImage: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                TextField(AppLocalization.string("GEOSITE name"), text: $criterion.value)
                    .textFieldStyle(.roundedBorder)
            }
        case .port:
            TextField(AppLocalization.string("443 or 8000-9000"), text: $criterion.value)
                .textFieldStyle(.roundedBorder)
        case .transport:
            Picker(AppLocalization.string("Transport protocol"), selection: $criterion.protocolValue) {
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

    private func chooseInstalledApplication() {
        let panel = NSOpenPanel()
        panel.title = AppLocalization.string("Choose an installed application")
        panel.prompt = AppLocalization.string("Choose")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let candidate = try ApplicationCaptureCandidateProvider().candidate(bundleURL: url)
            criterion.value = candidate.fallbackIdentifierPatterns.first
                ?? candidate.bundleIdentifier
                ?? candidate.displayName
            applicationError = nil
        } catch {
            applicationError = error.localizedDescription
        }
    }
}
