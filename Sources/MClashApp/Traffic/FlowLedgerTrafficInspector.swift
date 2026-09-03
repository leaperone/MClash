import Foundation
import MClashNetworkShared

/// The user-facing reason a flow appears in the traffic workbench.
///
/// This is deliberately a MClash-owned projection.  It does not expose a
/// controller/API model and can be populated by either the native relay or a
/// compatibility connection record.
enum FlowTrafficRouteKind: String, Hashable, Sendable {
    case direct
    case proxy
    case rejected
    case failOpen
    case unresolved
}

enum FlowTrafficDNSPath: Hashable, Sendable {
    case system
    case localResolver
    case remoteResolver(String)
    case fakeIP
    case unknown

    /// Stable, non-localized value for automation and diagnostics.
    var identifier: String {
        switch self {
        case .system: "system"
        case .localResolver: "local"
        case let .remoteResolver(name): "remote:(name)"
        case .fakeIP: "fake-ip"
        case .unknown: "unknown"
        }
    }
}

/// A reviewed rule action offered by the traffic inspector.
struct FlowTrafficQuickRuleDraft: Hashable, Sendable, Identifiable {
    enum Kind: String, Hashable, Sendable {
        case exactDomain
        case domainSuffix
        case application
        case processPath
        case ipAddress
    }

    let kind: Kind
    let matcher: RoutingMatcher
    let value: String

    var id: String { "(kind.rawValue):(value)" }
}

/// All evidence needed to answer “why is this traffic here?” in one place.
///
/// `why` is intentionally a short, deterministic explanation suitable for a
/// table/inspector summary.  Detailed evidence remains available in the
/// structured properties so the UI can localize each part independently.
struct FlowLedgerTrafficInspector: Hashable, Sendable {
    let route: FlowTrafficRouteKind
    let entrance: String?
    let matchedRule: String?
    let rulePayload: String?
    let routeChain: [String]
    let selectedNode: String?
    let dnsPath: FlowTrafficDNSPath
    let destination: FlowLedgerDestination
    let application: FlowLedgerApplication
    let evidence: [String]

    var why: String {
        switch route {
        case .direct: "Matched a direct route"
        case .proxy: "Matched a proxy route"
        case .rejected: "Matched a blocking route"
        case .failOpen: "Relay failed; traffic was handed back directly"
        case .unresolved: "Route decision is not available yet"
        }
    }

    /// Rule actions are proposals only.  The normal rule editor must review
    /// and validate them before they become part of the workspace.
    var quickRuleDrafts: [FlowTrafficQuickRuleDraft] {
        var drafts: [FlowTrafficQuickRuleDraft] = []
        if let hostname = nonEmpty(destination.hostname), hostname.contains(".") {
            drafts.append(.init(kind: .exactDomain, matcher: .domainExact(hostname), value: hostname))
            drafts.append(.init(kind: .domainSuffix, matcher: .domainSuffix(hostname), value: hostname))
        }
        if let ip = nonEmpty(destination.ipAddress), (try? IPAddress(ip)) != nil {
            drafts.append(.init(kind: .ipAddress, matcher: .ipCIDR(ip), value: ip))
        }
        if let bundle = nonEmpty(application.bundleIdentifier) {
            drafts.append(.init(kind: .application, matcher: .application(bundle), value: bundle))
        } else if let name = nonEmpty(application.displayName), application.isAttributed {
            drafts.append(.init(kind: .application, matcher: .processName(name), value: name))
        }
        if let path = nonEmpty(application.executablePath) {
            drafts.append(.init(kind: .processPath, matcher: .processPath(path), value: path))
        }
        return drafts
    }

    init(entry: FlowLedgerEntry, dnsPath: FlowTrafficDNSPath = .unknown) {
        route = switch entry.outcome {
        case .direct: .direct
        case .viaMihomo: .proxy
        case .rejected: .rejected
        case .failOpen: .failOpen
        case .relayFailed: .unresolved
        }
        entrance = Self.originIdentifier(entry.captureOrigin)
        matchedRule = nonEmpty(entry.appRoutingRule) ?? nonEmpty(entry.mihomoRoute?.rule)
        rulePayload = nonEmpty(entry.mihomoRoute?.rulePayload)
        routeChain = entry.mihomoRoute?.chain ?? []
        selectedNode = routeChain.last
        self.dnsPath = dnsPath
        destination = entry.destination
        application = entry.application
        evidence = Self.evidence(
            entrance: entrance,
            matchedRule: matchedRule,
            rulePayload: rulePayload,
            routeChain: routeChain,
            dnsPath: dnsPath
        )
    }

    init(connection: MihomoConnection) {
        let metadata = connection.metadata
        if connection.rule.uppercased() == "REJECT" {
            route = .rejected
        } else if connection.chains.isEmpty, connection.rule.uppercased() == "DIRECT" {
            route = .direct
        } else if !connection.chains.isEmpty || !connection.rule.isEmpty {
            route = .proxy
        } else {
            route = .unresolved
        }
        entrance = nonEmpty(metadata.inboundName)
        matchedRule = nonEmpty(connection.rule)
        rulePayload = nonEmpty(connection.rulePayload)
        routeChain = connection.chains.reversed().compactMap(nonEmpty)
        selectedNode = routeChain.last
        dnsPath = Self.dnsPath(metadata.dnsMode)
        destination = FlowLedgerDestination(
            hostname: nonEmpty(metadata.host) ?? nonEmpty(metadata.sniffHost),
            ipAddress: nonEmpty(metadata.destinationIP),
            port: metadata.destinationPort.flatMap(UInt16.init)
        )
        application = FlowLedgerApplication(
            key: metadata.processPath.map(FlowLedgerApplicationKey.executablePath)
                ?? metadata.process.map(FlowLedgerApplicationKey.processName)
                ?? .unattributed,
            displayName: nonEmpty(metadata.process) ?? "Unattributed",
            bundleIdentifier: nil,
            executablePath: nonEmpty(metadata.processPath),
            processIdentifier: nil,
            userIdentifier: metadata.uid,
            signingIdentifier: nil
        )
        evidence = Self.evidence(
            entrance: entrance,
            matchedRule: matchedRule,
            rulePayload: rulePayload,
            routeChain: routeChain,
            dnsPath: dnsPath
        )
    }

    private static func dnsPath(_ mode: String?) -> FlowTrafficDNSPath {
        guard let mode = nonEmpty(mode)?.lowercased() else { return .unknown }
        if mode.contains("fake") { return .fakeIP }
        if mode.contains("redir") || mode.contains("local") { return .localResolver }
        if mode.contains("system") { return .system }
        return .remoteResolver(mode)
    }

    private static func originIdentifier(_ origin: FlowLedgerCaptureOrigin) -> String {
        switch origin {
        case .systemProxy: "system-proxy"
        case .appRouting: "app-routing"
        case .dnsProxy: "dns-proxy"
        case let .localListener(name): "listener:(name)"
        case .unknown: "unknown"
        }
    }

    private static func evidence(
        entrance: String?, matchedRule: String?, rulePayload: String?,
        routeChain: [String], dnsPath: FlowTrafficDNSPath
    ) -> [String] {
        [
            entrance.map { "entrance=($0)" },
            matchedRule.map { "rule=($0)" },
            rulePayload.map { "rule-payload=($0)" },
            routeChain.isEmpty ? nil : "chain=(routeChain.joined(separator: "→"))",
            "dns=(dnsPath.identifier)"
        ].compactMap { $0 }
    }
}

private func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
