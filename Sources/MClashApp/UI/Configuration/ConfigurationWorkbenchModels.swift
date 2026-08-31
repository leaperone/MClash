import Foundation

/// The strategy-owned resources shown by the configuration workbench.
/// These intentionally contain no Mihomo or imported-profile types: sources
/// can be replaced without changing the user's workspace organisation.
enum ConfigurationWorkbenchSection: String, CaseIterable, Identifiable, Sendable {
    case workspaces, sources, nodes, proxyGroups, rules, ruleSets, entrances, dns

    var id: String { rawValue }
    var title: String {
        switch self {
        case .workspaces: "Configuration"
        case .sources: "Sources"
        case .nodes: "Nodes"
        case .proxyGroups: "Node Groups"
        case .rules: "Rules"
        case .ruleSets: "Rule Sets"
        case .entrances: "Entrances"
        case .dns: "DNS"
        }
    }
    /// User-facing terminology. “Workspace” and “Proxy Group” are retained in
    /// the model/API for migration, but the navigation speaks in terms users
    /// can act on immediately.
    var presentationTitle: String {
        switch self {
        case .workspaces: "Configuration"
        case .proxyGroups: "Node Groups"
        default: title
        }
    }
    var singularTitle: String {
        switch self {
        case .workspaces: "Workspace"
        case .sources: "Source"
        case .nodes: "Node"
        case .proxyGroups: "Node Group"
        case .rules: "Rule"
        case .ruleSets: "Rule Set"
        case .entrances: "Entrance"
        case .dns: "DNS"
        }
    }
    var presentationSingularTitle: String {
        switch self {
        case .workspaces: "Configuration"
        case .proxyGroups: "Node Group"
        default: singularTitle
        }
    }
    var symbol: String {
        switch self {
        case .workspaces: "rectangle.3.group"
        case .sources: "arrow.down.circle"
        case .nodes: "point.3.connected.trianglepath.dotted"
        case .proxyGroups: "square.3.layers.3d"
        case .rules: "list.bullet.indent"
        case .ruleSets: "list.bullet.rectangle"
        case .entrances: "arrow.triangle.branch"
        case .dns: "network"
        }
    }
}

struct ConfigurationWorkbenchItem: Identifiable, Sendable {
    let id: UUID
    let title: String
    let subtitle: String
    let symbol: String
    let detail: String
    let metadata: [(String, String)]
    let isEnabled: Bool?

    init(
        id: UUID = UUID(), title: String, subtitle: String,
        symbol: String, detail: String, metadata: [(String, String)] = [],
        isEnabled: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.detail = detail
        self.metadata = metadata
        self.isEnabled = isEnabled
    }
}

func configurationDisplayName(_ name: String) -> String {
    switch name {
    case "Everyday", "MClash Select", "New Workspace", "New Group":
        AppLocalization.string(name)
    default: name
    }
}

func canonicalConfigurationDefaultName(_ name: String) -> String {
    for sentinel in ["Everyday", "MClash Select", "New Workspace", "New Group"]
    where name == AppLocalization.string(sentinel) {
        return sentinel
    }
    return name
}

extension ConfigurationSourceKind {
    var localizedTitle: String {
        switch self {
        case .subscription: AppLocalization.string("Subscription")
        case .localFile: AppLocalization.string("Local File")
        case .pastedConfig: AppLocalization.string("Pasted Configuration")
        }
    }
}

extension NodeAvailability {
    var localizedTitle: String {
        switch self {
        case .unknown: AppLocalization.string("Unknown")
        case .available: AppLocalization.string("Available")
        case .unavailable: AppLocalization.string("Unavailable")
        case .sourceRemoved: AppLocalization.string("Source Removed")
        case .unsupported: AppLocalization.string("Unsupported")
        }
    }
}

extension ProxyGroupType {
    var localizedTitle: String {
        switch self {
        case .select: AppLocalization.string("Select")
        case .fallback: AppLocalization.string("Fallback")
        case .urlTest: AppLocalization.string("URL Test")
        case .loadBalance: AppLocalization.string("Load Balance")
        case .direct: AppLocalization.string("Direct")
        case .reject: AppLocalization.string("Reject")
        case .relay: AppLocalization.string("Relay")
        }
    }
}

extension EntranceKind {
    var localizedTitle: String {
        switch self {
        case .http: "HTTP"
        case .socks5: "SOCKS5"
        case .appRouting: AppLocalization.string("App Routing")
        case .tun: "TUN"
        }
    }
}

extension DNSMode {
    var localizedTitle: String {
        switch self {
        case .system: AppLocalization.string("System DNS")
        case .fakeIP: AppLocalization.string("Fake IP")
        case .redirHost: AppLocalization.string("Redir Host")
        }
    }
}

extension RuleSetBehavior {
    var localizedTitle: String {
        switch self {
        case .classical: AppLocalization.string("Classical (mixed rules)")
        case .domain: AppLocalization.string("Domain list")
        case .ipcidr: AppLocalization.string("IP/CIDR list")
        }
    }
}

extension RuleSetFormat {
    var localizedTitle: String {
        switch self {
        case .yaml: "YAML"
        case .text: AppLocalization.string("Text")
        case .mrs: "MRS"
        }
    }
}

func configurationRoutingModeTitle(_ mode: ConfigurationRoutingMode) -> String {
    switch mode {
    case .rule: AppLocalization.string("Rule")
    case .global: AppLocalization.string("Global")
    case .direct: AppLocalization.string("Direct")
    }
}

func configurationRoutingModeExplanation(_ mode: ConfigurationRoutingMode) -> String {
    switch mode {
    case .rule:
        AppLocalization.string(
            "Rule mode evaluates the MClash rule list, then sends traffic to its selected strategy group."
        )
    case .global:
        AppLocalization.string(
            "Global mode sends every entrance to the selected Global exit group; rules are not evaluated."
        )
    case .direct:
        AppLocalization.string(
            "Direct mode bypasses proxy groups and connects through the system network."
        )
    }
}
