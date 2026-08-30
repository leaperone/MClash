import Foundation

/// The strategy-owned resources shown by the configuration workbench.
/// These intentionally contain no Mihomo or imported-profile types: sources
/// can be replaced without changing the user's workspace organisation.
enum ConfigurationWorkbenchSection: String, CaseIterable, Identifiable, Sendable {
    case workspaces, sources, nodes, proxyGroups, rules, entrances

    var id: String { rawValue }
    var title: String {
        switch self {
        case .workspaces: "Workspaces"
        case .sources: "Sources"
        case .nodes: "Nodes"
        case .proxyGroups: "Proxy Groups"
        case .rules: "Rules"
        case .entrances: "Entrances"
        }
    }
    /// User-facing terminology. “Workspace” and “Proxy Group” are retained in
    /// the model/API for migration, but the navigation speaks in terms users
    /// can act on immediately.
    var presentationTitle: String {
        switch self {
        case .workspaces: "Configurations"
        case .proxyGroups: "Groups"
        default: title
        }
    }
    var singularTitle: String {
        switch self {
        case .workspaces: "Workspace"
        case .sources: "Source"
        case .nodes: "Node"
        case .proxyGroups: "Proxy Group"
        case .rules: "Rule"
        case .entrances: "Entrance"
        }
    }
    var presentationSingularTitle: String {
        switch self {
        case .workspaces: "Configuration"
        case .proxyGroups: "Group"
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
        case .entrances: "arrow.triangle.branch"
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
