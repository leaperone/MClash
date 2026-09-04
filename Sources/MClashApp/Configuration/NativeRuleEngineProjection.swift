import Foundation
import MClashNetworkShared

/// The policy result understood by MClash's connector layer.  It deliberately
/// does not expose the historical compatibility runtime vocabulary.
public enum NativeRouteAction: Codable, Hashable, Sendable {
    case direct
    case reject
    case outbound(ProxyGroupID)
}

public struct NativeRouteDecision: Codable, Hashable, Sendable {
    public let action: NativeRouteAction
    public let matchedRuleID: RoutingRuleID?
    public let matchedRuleSetID: RuleSetID?

    public init(
        action: NativeRouteAction,
        matchedRuleID: RoutingRuleID? = nil,
        matchedRuleSetID: RuleSetID? = nil
    ) {
        self.action = action
        self.matchedRuleID = matchedRuleID
        self.matchedRuleSetID = matchedRuleSetID
    }
}

/// A database-backed matcher supplied by the runtime for GEOIP/GEOSITE and
/// other external rule-set data.  Keeping this dependency at the boundary
/// means the policy engine never needs to know which database implementation
/// (or connector) is being used.
public typealias NativeRuleSetMatcher = @Sendable (_ ruleSet: RuleSet, _ context: FlowContext) -> Bool
public typealias NativeGeoMatcher = @Sendable (_ kind: NativeGeoKind, _ value: String, _ context: FlowContext) -> Bool

public enum NativeGeoKind: String, Codable, Hashable, Sendable {
    case ip
    case site
}

/// Describes whether a rule set has data that the native projection can
/// evaluate synchronously.  Remote providers and file-backed sets need an
/// explicit loader/matcher; treating their absent cache as an empty set would
/// silently change routing policy.
public enum NativeRuleSetSupport: Equatable, Sendable {
    case inline
    case externalRequiresLoader

    public static func assess(_ ruleSet: RuleSet) -> NativeRuleSetSupport {
        if ruleSet.sourceURL == nil,
           ruleSet.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return .inline
        }
        return .externalRequiresLoader
    }
}

/// Evaluates a compiled, workspace-scoped plan before any outbound connector
/// is selected. Rule sets are evaluated in plan order, followed by explicit
/// rules, matching the policy order emitted by the compiler.  Compatibility
/// YAML and CaptureRuleEngine remain available to older providers, but are not
/// involved in this projection.
public struct NativeRuleEngineProjection: Sendable {
    private let plan: CompiledRuntimePlan
    private let geoMatcher: NativeGeoMatcher?
    private let ruleSetMatcher: NativeRuleSetMatcher?
    private let groups: Set<ProxyGroupID>
    private let groupNames: [String: ProxyGroupID]

    public init(
        plan: CompiledRuntimePlan,
        geoMatcher: NativeGeoMatcher? = nil,
        ruleSetMatcher: NativeRuleSetMatcher? = nil
    ) {
        self.plan = plan
        self.geoMatcher = geoMatcher
        self.ruleSetMatcher = ruleSetMatcher
        self.groups = Set(plan.proxyGroups.filter(\.enabled).map(\.id))
        self.groupNames = Dictionary(
            plan.proxyGroups.filter(\.enabled).map { ($0.name.lowercased(), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    public func evaluate(_ context: FlowContext) -> NativeRouteDecision {
        if BuiltInBypassPolicy().reason(for: context) != nil {
            return NativeRouteDecision(action: .direct)
        }
        switch plan.routingMode {
        case .direct:
            return NativeRouteDecision(action: .direct)
        case .global:
            return NativeRouteDecision(action: globalAction())
        case .rule:
            break
        }

        // Rule-set entries precede explicit rules in the authoritative plan.
        for ruleSet in plan.ruleSets where ruleSet.enabled {
            if let ruleSetAction = ruleSetAction(ruleSet: ruleSet, context: context, visited: []) {
                return NativeRouteDecision(
                    action: ruleSetAction.action,
                    matchedRuleSetID: ruleSet.id
                )
            }
        }
        for rule in plan.rules.sorted(by: stableRuleOrder) where rule.enabled {
            guard matches(rule: rule, context: context) else { continue }
            return NativeRouteDecision(action: action(rule.action), matchedRuleID: rule.id)
        }
        return NativeRouteDecision(action: .direct)
    }

    private func globalAction() -> NativeRouteAction {
        guard let id = plan.globalProxyGroupID, groups.contains(id) else { return .direct }
        return .outbound(id)
    }

    private func action(_ value: RoutingAction) -> NativeRouteAction {
        switch value {
        case .direct: .direct
        case .reject: .reject
        case let .proxyGroup(id): groups.contains(id) ? .outbound(id) : .direct
        }
    }

    private func stableRuleOrder(_ lhs: RoutingRule, _ rhs: RoutingRule) -> Bool {
        lhs.priority == rhs.priority
            ? lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
            : lhs.priority < rhs.priority
    }

    /// Matchers of one family are ORed; distinct families are ANDed. This is
    /// the same useful rule authoring model as the compiler (e.g. two domains
    /// OR together while a port condition remains an additional constraint).
    private func matches(rule: RoutingRule, context: FlowContext) -> Bool {
        let matchers = rule.matchers
        for family in MatcherFamily.allCases {
            let values = matchers.filter { $0.family == family }
            guard values.isEmpty || values.contains(where: { matches($0, context: context) }) else {
                return false
            }
        }
        return true
    }

    private func matches(_ matcher: RoutingMatcher, context: FlowContext) -> Bool {
        let host = context.destination.hostname?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch matcher {
        case let .application(value):
            return [context.source.bundleIdentifier, context.source.signingIdentifier]
                .compactMap { $0?.lowercased() }
                .contains { wildcard($0, pattern: value.lowercased()) }
        case let .processPath(value): return context.source.executablePath == value
        case let .processName(value):
            return context.source.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() == value.lowercased() } ?? false
        case let .userID(value): return context.source.userID == value
        case let .domainExact(value): return host == value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        case let .domainSuffix(value):
            let suffix = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host == suffix || host?.hasSuffix("." + suffix) == true
        case let .domainWildcard(value): return host.map { wildcard($0, pattern: value.lowercased()) } ?? false
        case let .ipCIDR(value): return context.destination.ipAddress.map { (try? IPNetwork(value))?.contains($0) == true } ?? false
        case let .geoIP(value): return geoMatcher?(.ip, value, context) ?? false
        case let .geoIP6(value): return geoMatcher?(.ip, value, context) ?? false
        case let .geoSite(value): return geoMatcher?(.site, value, context) ?? false
        case let .transport(value): return context.transportProtocol.rawValue.caseInsensitiveCompare(value) == .orderedSame
        case let .port(value): return context.destination.port == UInt16(clamping: value)
        case let .portRange(value): return value.contains(Int(context.destination.port))
        }
    }

    /// Evaluates inline rule-set entries and preserves an explicit target when
    /// one is present. This is important for native mode: a downloaded
    /// classical rule set may contain `GEOSITE,gfw,REJECT` or
    /// `GEOIP,CN,DIRECT,no-resolve`, and silently replacing that target with
    /// the rule-set default would change policy semantics.
    private struct RuleSetResolution {
        let action: NativeRouteAction
        /// True when the action came from an explicit target token in a
        /// classical rule-set entry. A nested rule-set's default must not
        /// override its wrapper's default unless it carried such a token.
        let isExplicit: Bool
    }

    private func ruleSetAction(
        ruleSet: RuleSet,
        context: FlowContext,
        visited: Set<RuleSetID>
    ) -> RuleSetResolution? {
        guard !visited.contains(ruleSet.id) else { return nil }
        if let ruleSetMatcher, ruleSetMatcher(ruleSet, context) {
            return RuleSetResolution(
                action: action(ruleSet.defaultAction),
                isExplicit: false
            )
        }
        var nextVisited = visited
        nextVisited.insert(ruleSet.id)
        for raw in ruleSet.rules {
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let kind = parts.first?.uppercased(), parts.count >= 2 else { continue }
            let explicitTarget = parts.dropFirst(2).first(where: { actionToken($0) != nil })
            if kind == "RULE-SET", let name = parts.dropFirst().first?.lowercased(),
               let nested = plan.ruleSets.first(where: { $0.enabled && $0.name.lowercased() == name }) {
                guard let nestedResolution = ruleSetAction(
                    ruleSet: nested,
                    context: context,
                    visited: nextVisited
                ) else { continue }
                if let explicitTarget, let resolved = actionToken(explicitTarget) {
                    return RuleSetResolution(action: resolved, isExplicit: true)
                }
                return nestedResolution.isExplicit
                    ? nestedResolution
                    : RuleSetResolution(
                        action: action(ruleSet.defaultAction),
                        isExplicit: false
                    )
            }
            guard matchesRuleSetEntry(kind: kind, value: parts[1], context: context) else {
                continue
            }
            if let explicitTarget, let resolved = actionToken(explicitTarget) {
                return RuleSetResolution(action: resolved, isExplicit: true)
            }
            return RuleSetResolution(
                action: action(ruleSet.defaultAction),
                isExplicit: false
            )
        }
        return nil
    }

    private func actionToken(_ token: String) -> NativeRouteAction? {
        switch token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "DIRECT": return .direct
        case "REJECT": return .reject
        case "GLOBAL": return globalAction()
        default:
            guard let id = groupNames[token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] else {
                return nil
            }
            return groups.contains(id) ? .outbound(id) : nil
        }
    }

    private func matchesRuleSetEntry(kind: String, value: String, context: FlowContext) -> Bool {
        let host = context.destination.hostname?.lowercased()
        switch kind {
        case "DOMAIN": return host == value.lowercased()
        case "DOMAIN-SUFFIX": return host == value.lowercased() || host?.hasSuffix("." + value.lowercased()) == true
        case "DOMAIN-KEYWORD": return host?.contains(value.lowercased()) == true
        case "DOMAIN-WILDCARD": return host.map { wildcard($0, pattern: value.lowercased()) } ?? false
        case "IP-CIDR", "IP-CIDR6": return context.destination.ipAddress.map { (try? IPNetwork(value))?.contains($0) == true } ?? false
        case "GEOIP": return geoMatcher?(.ip, value, context) ?? false
        case "GEOSITE": return geoMatcher?(.site, value, context) ?? false
        case "MATCH": return true
        default: return false
        }
    }

    private func wildcard(_ value: String, pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return value.range(of: "^" + escaped + "$", options: .regularExpression) != nil
    }
}

private enum MatcherFamily: CaseIterable {
    case source, domain, address, geo, transport, port
}

private extension RoutingMatcher {
    var family: MatcherFamily {
        switch self {
        case .application, .processPath, .processName, .userID: .source
        case .domainExact, .domainSuffix, .domainWildcard: .domain
        case .ipCIDR: .address
        case .geoIP, .geoIP6, .geoSite: .geo
        case .transport: .transport
        case .port, .portRange: .port
        }
    }
}
