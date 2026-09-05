import Foundation

/// Presentation snapshot built directly from MClash's compiled workspace.
///
/// The UI still exposes a few historical Mihomo-shaped value types for source
/// compatibility. This adapter keeps those values read-only and synthesizes
/// them from the native plan, so a native launch never needs an HTTP controller
/// or a Mihomo process to populate the Proxies and Rules surfaces.
enum NativeRuntimeProjection {
    static func proxyCollection(
        from plan: CompiledRuntimePlan
    ) -> MihomoProxyCollection {
        var values: [String: MihomoProxy] = [:]
        for node in plan.nodes where node.enabled {
            let available = node.health.availability == .available
                || node.health.availability == .unknown
            guard let proxy = decodeProxy([
                "name": node.displayName,
                "type": node.proto.rawValue,
                "alive": available,
                "all": [],
                "now": node.displayName
            ]) else { continue }
            values[node.displayName] = proxy
        }
        for group in plan.proxyGroups where group.enabled {
            let members = group.members.compactMap { member -> String? in
                switch member {
                case let .node(id):
                    return plan.nodes.first(where: { $0.id == id && $0.enabled })?.displayName
                case let .group(id):
                    return plan.proxyGroups.first(where: { $0.id == id && $0.enabled })?.name
                }
            }
            guard let proxy = decodeProxy([
                "name": group.name,
                "type": presentationType(for: group.type),
                "alive": !members.isEmpty,
                "all": members,
                "now": members.first as Any,
                "fixed": members.first as Any
            ]) else { continue }
            values[group.name] = proxy
        }
        return MihomoProxyCollection(proxies: values)
    }

    static func ruleCollection(
        from plan: CompiledRuntimePlan
    ) -> MihomoRuleCollection {
        let rules = plan.rules.enumerated().map { index, rule in
            let matcher = rule.matchers.map(presentationMatcher).joined(separator: ",")
            let target = presentationTarget(rule.action, plan: plan)
            return MihomoRule(
                index: index,
                type: matcher.isEmpty ? "MATCH" : matcher,
                payload: matcher,
                proxy: target,
                size: 1,
                extra: nil
            )
        }
        return MihomoRuleCollection(rules: rules)
    }

    static func config(from plan: CompiledRuntimePlan) -> MihomoConfig {
        let sockets = plan.entrances.compactMap { entrance -> MihomoListener? in
            guard entrance.enabled, let port = entrance.port else { return nil }
            return MihomoListener(
                name: entrance.name,
                type: entrance.kind.rawValue,
                port: port,
                listen: entrance.bindAddress,
                proxy: presentationTarget(entrance.defaultAction, plan: plan)
            )
        }
        return MihomoConfig(
            port: 0,
            socksPort: 0,
            redirPort: 0,
            tproxyPort: 0,
            mixedPort: 0,
            tun: MihomoTUNConfig(
                enable: false,
                device: "MClash",
                stack: "system",
                dnsHijack: nil,
                autoRoute: false,
                autoDetectInterface: false,
                mtu: nil,
                strictRoute: nil,
                routeAddresses: nil,
                routeExcludeAddresses: nil,
                includeInterfaces: nil,
                excludeInterfaces: nil,
                endpointIndependentNAT: nil,
                udpTimeout: nil,
                icmpTimeout: nil,
                receiveMessageX: nil,
                sendMessageX: nil
            ),
            authentication: nil,
            skipAuthPrefixes: nil,
            lanAllowedIPs: nil,
            lanDisallowedIPs: nil,
            allowLAN: false,
            bindAddress: "127.0.0.1",
            mode: plan.routingMode.rawValue,
            unifiedDelay: true,
            logLevel: "info",
            ipv6: true,
            interfaceName: "",
            routingMark: 0,
            geoXURL: nil,
            geoAutoUpdate: false,
            geoUpdateInterval: nil,
            geodataMode: true,
            geodataLoader: "standard",
            geositeMatcher: nil,
            tcpConcurrent: true,
            findProcessMode: "off",
            sniffing: false,
            globalUserAgent: nil,
            etagSupport: nil,
            keepAliveIdle: nil,
            keepAliveInterval: nil,
            disableKeepAlive: nil,
            listeners: sockets
        )
    }

    private static func presentationType(for type: ProxyGroupType) -> String {
        switch type {
        case .select: "Selector"
        case .fallback: "Fallback"
        case .urlTest: "URLTest"
        case .loadBalance: "LoadBalance"
        case .direct: "Direct"
        case .reject: "Reject"
        case .relay: "Relay"
        }
    }

    private static func decodeProxy(_ object: [String: Any]) -> MihomoProxy? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let value = try? JSONDecoder().decode(MihomoProxy.self, from: data)
        else { return nil }
        return value
    }

    private static func presentationMatcher(_ matcher: RoutingMatcher) -> String {
        switch matcher {
        case let .application(value): "APPLICATION,\(value)"
        case let .processPath(value): "PROCESS-PATH,\(value)"
        case let .processName(value): "PROCESS-NAME,\(value)"
        case let .userID(value): "UID,\(value)"
        case let .domainExact(value): "DOMAIN,\(value)"
        case let .domainSuffix(value): "DOMAIN-SUFFIX,\(value)"
        case let .domainWildcard(value): "DOMAIN-WILDCARD,\(value)"
        case let .ipCIDR(value): "IP-CIDR,\(value)"
        case let .geoIP(value): "GEOIP,\(value)"
        case let .geoIP6(value): "GEOIP6,\(value)"
        case let .geoSite(value): "GEOSITE,\(value)"
        case let .transport(value): "NETWORK,\(value)"
        case let .port(value): "DST-PORT,\(value)"
        case let .portRange(value): "DST-PORT,\(value.lowerBound)-\(value.upperBound)"
        }
    }

    private static func presentationTarget(
        _ action: RoutingAction,
        plan: CompiledRuntimePlan
    ) -> String {
        switch action {
        case .direct: "DIRECT"
        case .reject: "REJECT"
        case let .proxyGroup(id):
            plan.proxyGroups.first(where: { $0.id == id })?.name ?? "DIRECT"
        }
    }
}
