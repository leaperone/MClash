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

    init(
        id: UUID = UUID(), title: String, subtitle: String,
        symbol: String, detail: String, metadata: [(String, String)] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.detail = detail
        self.metadata = metadata
    }

    static func samples(for section: ConfigurationWorkbenchSection) -> [Self] {
        switch section {
        case .workspaces:
            [Self(title: "Everyday", subtitle: "12 nodes · 6 rules", symbol: "briefcase", detail: "Your default routing workspace.", metadata: [("Entrances", "HTTP · SOCKS5 · App Routing"), ("Default", "Auto Select")]), Self(title: "AI Services", subtitle: "8 nodes · 4 rules", symbol: "sparkles", detail: "Routes AI traffic through preferred exits.", metadata: [("Entrances", "HTTP · SOCKS5"), ("Default", "AI Fast Lane")])]
        case .sources:
            [Self(title: "Primary subscription", subtitle: "Updated 12 min ago", symbol: "link", detail: "Nodes imported from a remote subscription.", metadata: [("Nodes", "42"), ("Status", "Healthy")]), Self(title: "Local nodes", subtitle: "Manual collection", symbol: "folder", detail: "Locally maintained connection endpoints.", metadata: [("Nodes", "6"), ("Status", "Ready")])]
        case .nodes:
            [Self(title: "Tokyo · Premium", subtitle: "Primary subscription", symbol: "point.3.filled.connected.trianglepath.dotted", detail: "A stable encrypted connection endpoint.", metadata: [("Protocol", "Hysteria 2"), ("Latency", "86 ms")]), Self(title: "Singapore · Edge", subtitle: "Primary subscription", symbol: "point.3.filled.connected.trianglepath.dotted", detail: "An imported node available to groups.", metadata: [("Protocol", "VLESS"), ("Latency", "124 ms")]), Self(title: "Home fallback", subtitle: "Local nodes", symbol: "point.3.filled.connected.trianglepath.dotted", detail: "A local fallback endpoint.", metadata: [("Protocol", "Shadowsocks"), ("Latency", "—")])]
        case .proxyGroups:
            [Self(title: "Auto Select", subtitle: "url-test · 12 members", symbol: "arrow.triangle.2.circlepath", detail: "Automatically selects the fastest healthy node.", metadata: [("Workspace", "Everyday"), ("Fallback", "DIRECT")]), Self(title: "AI Fast Lane", subtitle: "select · 8 members", symbol: "bolt", detail: "A hand-picked group for AI services.", metadata: [("Workspace", "AI Services"), ("Fallback", "Auto Select")])]
        case .rules:
            [Self(title: "AI services", subtitle: "Domain · AI Fast Lane", symbol: "globe", detail: "Routes known AI domains to the selected group.", metadata: [("Match", "DOMAIN-SUFFIX"), ("Action", "AI Fast Lane")]), Self(title: "Private networks", subtitle: "IP-CIDR · DIRECT", symbol: "network", detail: "Keeps local networks on the direct path.", metadata: [("Match", "IP-CIDR"), ("Action", "DIRECT")])]
        case .entrances:
            []
        }
    }
}
