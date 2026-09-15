import Foundation
import MClashAutomationProtocol

actor XrayRuntimeController: ProxyRuntimeClient {
    nonisolated var backend: ProxyRuntimeBackend { .xray }
    nonisolated var supportsConnectionInspection: Bool { false }
    nonisolated var supportsAPILogs: Bool { false }
    let control: XrayControlSession
    private let version: String
    private var healthLoop: Task<Void, Never>?

    init(control: XrayControlSession, version: String) {
        self.control = control
        self.version = version
    }

    deinit { healthLoop?.cancel() }

    func startHealthChecks() {
        guard healthLoop == nil else { return }
        healthLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.probeAutomaticGroups()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    func stopHealthChecks() {
        healthLoop?.cancel()
        healthLoop = nil
    }

    func fetchVersion() async throws -> MihomoVersion {
        _ = try await control.traffic()
        return MihomoVersion(meta: false, version: "Xray " + version)
    }

    func fetchConfig() async throws -> MihomoConfig {
        let plan = await control.plan
        let inputs = plan.inbounds.filter { !$0.tag.hasPrefix("probe-") }
        let visible = inputs.filter { $0.authentication == nil }
        let listeners: [AutomationJSONValue] = inputs.map { input in
            .object(["name": .string(input.tag), "type": .string(input.kind.rawValue),
                     "listen": .string(input.bindAddress), "port": .integer(Int64(input.port))])
        }
        let config: [String: AutomationJSONValue] = [
            "port": .integer(Int64(visible.first { $0.kind == .http }?.port ?? 0)),
            "socks-port": .integer(Int64(visible.first { $0.kind == .socks }?.port ?? 0)),
            "mixed-port": .integer(Int64(visible.first { $0.kind == .mixed }?.port ?? 0)),
            "redir-port": .integer(0), "tproxy-port": .integer(0),
            "tun": .object(["enable": .bool(false), "device": .string(""), "stack": .string(""),
                            "auto-route": .bool(false), "auto-detect-interface": .bool(false)]),
            "allow-lan": .bool(visible.contains { !["127.0.0.1", "::1"].contains($0.bindAddress) }),
            "bind-address": .string("127.0.0.1"), "mode": .string(plan.workspace.routingMode.rawValue),
            "unified-delay": .bool(false), "log-level": .string("warning"), "ipv6": .bool(true),
            "interface-name": .string(""), "routing-mark": .integer(0), "tcp-concurrent": .bool(false),
            "find-process-mode": .string("off"), "sniffing": .bool(true), "listeners": .array(listeners),
        ]
        return try decode(config)
    }

    func fetchProxies() async throws -> MihomoProxyCollection {
        let plan = await control.plan
        let resolutions = await control.groupResolutions()
        let overrides = await control.overrides()
        let probes = await control.probeResults().sorted { $0.checkedAt > $1.checkedAt }
        let names = nodeNames(plan)
        let groups = Dictionary(uniqueKeysWithValues: plan.groups.map { ($0.id, $0.name) })
        var proxies: [String: MihomoProxy] = [:]
        for node in plan.nodes {
            guard let name = names[node.id] else { continue }
            var fields: [String: AutomationJSONValue] = ["name": .string(name), "type": .string(node.proto.rawValue),
                "udp": .bool(node.proto != .http && node.proto != .https), "alive": .bool(plan.nodeTags[node.id] != nil)]
            if let result = probes.first(where: { $0.nodeID == node.id && $0.connectionFingerprint == node.connectionFingerprint }) {
                switch result.outcome {
                case let .available(latency):
                    fields["history"] = .array([.object(["time": .string(ISO8601DateFormatter().string(from: result.checkedAt)), "delay": .integer(Int64(latency))])])
                case .failed:
                    fields["alive"] = .bool(false)
                }
            }
            proxies[name] = try decode(fields)
        }
        for group in plan.groups {
            let type: String
            switch group.type {
            case .select: type = "Selector"
            case .fallback: type = "Fallback"
            case .urlTest: type = "URLTest"
            case .loadBalance: type = "LoadBalance"
            case .direct: type = "Direct"
            case .reject: type = "Reject"
            case .relay: type = "Relay"
            }
            let members = group.members.compactMap { memberName($0, nodes: names, groups: groups) }
            let resolution = resolutions[group.id]
            let selection: String?
            switch resolution?.destination {
            case .direct: selection = "DIRECT"
            case .reject, .unsupported: selection = "REJECT"
            case .balance, .chain: selection = nil
            case .node: selection = resolution?.selectedMember.flatMap { memberName($0, nodes: names, groups: groups) }
            case nil: selection = nil
            }
            var fields: [String: AutomationJSONValue] = ["name": .string(group.name), "type": .string(type),
                "all": .array(members.map(AutomationJSONValue.string)),
                "testUrl": .string((group.healthCheck ?? ProxyGroupPolicySettings()).testURL.absoluteString),
                "expectedStatus": .string((group.healthCheck ?? ProxyGroupPolicySettings()).expectedStatus)]
            if let selection { fields["now"] = .string(selection) }
            if let fixed = overrides[group.id].flatMap({ memberName($0, nodes: names, groups: groups) }) { fields["fixed"] = .string(fixed) }
            proxies[group.name] = try decode(fields)
        }
        proxies["DIRECT"] = try decode(["name": .string("DIRECT"), "type": .string("Direct")])
        proxies["REJECT"] = try decode(["name": .string("REJECT"), "type": .string("Reject")])
        proxies["GLOBAL"] = try decode([
            "name": .string("GLOBAL"), "type": .string("Selector"),
            "all": .array(plan.groups.map { .string($0.name) }),
            "now": .string(plan.workspace.globalProxyGroupID.flatMap { groups[$0] } ?? plan.groups.first?.name ?? "DIRECT"),
        ])
        return MihomoProxyCollection(proxies: proxies)
    }

    func fetchProxy(named name: String) async throws -> MihomoProxy {
        guard let proxy = try await fetchProxies().proxies[name] else { throw XrayControlError.invalidSelection }
        return proxy
    }

    func selectProxy(group: String, proxy: String) async throws {
        let plan = await control.plan
        if group == "GLOBAL" {
            guard let target = plan.groups.first(where: { $0.name == proxy }) else { throw XrayControlError.invalidSelection }
            try await control.setMode(plan.workspace.routingMode, globalExit: target.id)
            return
        }
        guard let target = plan.groups.first(where: { $0.name == group }) else { throw XrayControlError.invalidSelection }
        let names = nodeNames(plan)
        let member: ProxyGroupMember
        if let node = names.first(where: { $0.value == proxy }) { member = .node(node.key) }
        else if let child = plan.groups.first(where: { $0.name == proxy }) { member = .group(child.id) }
        else { throw XrayControlError.invalidSelection }
        try await control.select(groupID: target.id, member: member)
    }

    func clearProxyOverride(group: String) async throws {
        let plan = await control.plan
        guard let target = plan.groups.first(where: { $0.name == group }) else { throw XrayControlError.invalidSelection }
        try await control.select(groupID: target.id, member: nil)
    }

    func patchConfig(_ patch: MihomoConfigPatch) async throws {
        let bytes = try JSONEncoder().encode(patch)
        let fields = try JSONDecoder().decode(AutomationJSONValue.self, from: bytes).objectValue ?? [:]
        guard fields.keys.allSatisfy({ $0 == "mode" }), let raw = patch.mode, let mode = ConfigurationRoutingMode(rawValue: raw) else {
            throw XrayRuntimeOperationError.configurationEditorRequired
        }
        try await control.setMode(mode)
    }

    func measureDelay(proxy: String, targetURL: URL, timeoutMilliseconds: Int, expectedStatus: String?) async throws -> Int {
        let plan = await control.plan
        let names = nodeNames(plan)
        let nodeID: NodeID
        if let node = names.first(where: { $0.value == proxy }) { nodeID = node.key }
        else if let group = plan.groups.first(where: { $0.name == proxy }),
                case let .node(id)? = await control.groupResolutions()[group.id]?.destination { nodeID = id }
        else { throw XrayControlError.invalidSelection }
        let result = try await control.probe(nodeID: nodeID, targetURL: targetURL, timeout: Double(timeoutMilliseconds) / 1000, expectedStatus: expectedStatus)
        guard case let .available(latency) = result.outcome else { throw XrayRuntimeOperationError.probeFailed }
        return latency
    }

    func fetchRules() async throws -> MihomoRuleCollection {
        let plan = await control.plan
        let rows = plan.configuration["routing"]?.objectValue?["rules"]?.arrayValue ?? []
        let values = rows.enumerated().compactMap { index, row -> AutomationJSONValue? in
            guard let fields = row.objectValue else { return nil }
            let destination = fields["balancerTag"]?.stringValue ?? fields["outboundTag"]?.stringValue ?? "reject"
            let matcher = fields["domain"] ?? fields["ip"] ?? fields["port"] ?? fields["inboundTag"] ?? fields["network"] ?? .string("")
            let payload = matcher.stringValue ?? matcher.arrayValue?.compactMap(\.stringValue).joined(separator: ",") ?? ""
            return .object(["index": .integer(Int64(index)), "type": .string("Xray"), "payload": .string(payload),
                "proxy": .string(destination), "size": .integer(1)])
        }
        return try decode(["rules": .array(values)])
    }

    func fetchProxyProviders() async throws -> MihomoProxyProviderCollection { .init(providers: [:]) }
    func fetchRuleProviders() async throws -> MihomoRuleProviderCollection { .init(providers: [:]) }
    func fetchProxyProvider(named name: String) async throws -> MihomoProxyProvider { throw XrayRuntimeOperationError.sourceEditorRequired }
    func updateProxyProvider(named name: String) async throws { throw XrayRuntimeOperationError.sourceEditorRequired }
    func healthCheckProxyProvider(named name: String) async throws { throw XrayRuntimeOperationError.sourceEditorRequired }
    func updateRuleProvider(named name: String) async throws { throw XrayRuntimeOperationError.configurationEditorRequired }
    func reloadConfig(fromPath path: String?, force: Bool) async throws { throw XrayRuntimeOperationError.configurationEditorRequired }
    func reloadConfig(payload: String, force: Bool) async throws { throw XrayRuntimeOperationError.configurationEditorRequired }
    func fetchConnections() async throws -> MihomoConnectionSnapshot { throw XrayRuntimeOperationError.captureRequired }
    func closeConnection(id: String) async throws { throw XrayRuntimeOperationError.captureRequired }
    func closeAllConnections() async throws { throw XrayRuntimeOperationError.captureRequired }

    func trafficStream() throws -> AsyncThrowingStream<MihomoTraffic, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { [control] in
                var previous: XrayTrafficSample?
                do {
                    while !Task.isCancelled {
                        let current = try await control.traffic()
                        let seconds = max(0.001, previous.map { current.sampledAt.timeIntervalSince($0.sampledAt) } ?? 1)
                        let upload = previous.map { max(0, current.uploaded - $0.uploaded) } ?? 0
                        let download = previous.map { max(0, current.downloaded - $0.downloaded) } ?? 0
                        continuation.yield(MihomoTraffic(upload: Int64(Double(upload) / seconds), download: Int64(Double(download) / seconds),
                            uploadTotal: current.uploaded, downloadTotal: current.downloaded))
                        previous = current
                        try await Task.sleep(for: .seconds(1))
                    }
                    continuation.finish()
                } catch is CancellationError { continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func logStream(minimumLevel: MihomoLogLevel) throws -> AsyncThrowingStream<MihomoLogEntry, Error> { throw XrayRuntimeOperationError.processLogsRequired }
    func structuredLogStream(minimumLevel: MihomoLogLevel) throws -> AsyncThrowingStream<MihomoStructuredLogEntry, Error> { throw XrayRuntimeOperationError.processLogsRequired }
    func connectionStream(intervalMilliseconds: Int) throws -> AsyncThrowingStream<MihomoConnectionSnapshot, Error> { throw XrayRuntimeOperationError.captureRequired }

    private struct ProbeWork: Hashable {
        let nodeID: NodeID
        let url: URL
        let expected: String
        let timeout: TimeInterval
    }

    private func probeAutomaticGroups() async {
        let plan = await control.plan
        let resolutions = await control.groupResolutions()
        let recent = await control.probeResults()
        var due: [ProbeWork: Date] = [:]
        for group in plan.groups where group.type == .fallback || group.type == .urlTest || group.type == .loadBalance {
            let settings = group.healthCheck ?? ProxyGroupPolicySettings()
            for id in resolutions[group.id]?.orderedCandidates ?? [] where plan.nodeTags[id] != nil {
                let key = ProbeWork(nodeID: id, url: settings.testURL, expected: settings.expectedStatus, timeout: settings.probeTimeout)
                let latest = recent.filter {
                    $0.nodeID == id && $0.targetURL == key.url && $0.expectedStatus == key.expected && $0.timeoutSeconds == key.timeout
                }.max { $0.checkedAt < $1.checkedAt }
                let selected = resolutions[group.id]?.destination == .node(id)
                let failed: Bool
                if case .failed? = latest?.outcome { failed = true } else { failed = false }
                let interval = failed ? min(2, settings.probeInterval) : selected ? min(5, settings.probeInterval) : settings.probeInterval
                let deadline = latest?.checkedAt.addingTimeInterval(interval) ?? .distantPast
                if deadline <= Date() {
                    due[key] = min(due[key] ?? deadline, deadline)
                }
            }
        }
        var scheduledNodes = Set<NodeID>()
        let work = due.sorted {
            if $0.value != $1.value { return $0.value < $1.value }
            if $0.key.nodeID != $1.key.nodeID { return $0.key.nodeID.rawValue.uuidString < $1.key.nodeID.rawValue.uuidString }
            if $0.key.url != $1.key.url { return $0.key.url.absoluteString < $1.key.url.absoluteString }
            if $0.key.expected != $1.key.expected { return $0.key.expected < $1.key.expected }
            return $0.key.timeout < $1.key.timeout
        }.filter { scheduledNodes.insert($0.key.nodeID).inserted }.prefix(4).map(\.key)
        await withTaskGroup(of: Void.self) { group in
            for item in work {
                group.addTask { [control] in
                    _ = try? await control.probe(nodeID: item.nodeID, targetURL: item.url, timeout: item.timeout, expectedStatus: item.expected)
                }
            }
        }
    }

    private func nodeNames(_ plan: XrayRuntimePlan) -> [NodeID: String] {
        let occupied = Set(plan.groups.map(\.name) + ["DIRECT", "REJECT", "GLOBAL"])
        let grouped = Dictionary(grouping: plan.nodes) { $0.userAlias ?? $0.displayName }
        return Dictionary(uniqueKeysWithValues: plan.nodes.map { node in
            let base = node.userAlias ?? node.displayName
            let duplicate = (grouped[base]?.count ?? 0) > 1 || occupied.contains(base)
            let suffix = String(node.id.rawValue.uuidString.lowercased().prefix(8))
            return (node.id, duplicate ? base + " [" + suffix + "]" : base)
        })
    }

    private func memberName(_ member: ProxyGroupMember, nodes: [NodeID: String], groups: [ProxyGroupID: String]) -> String? {
        switch member { case let .node(id): nodes[id]; case let .group(id): groups[id] }
    }

    private func decode<Value: Decodable>(_ fields: [String: AutomationJSONValue]) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(fields))
    }
}

enum XrayRuntimeOperationError: Error, LocalizedError {
    case configurationEditorRequired, sourceEditorRequired, captureRequired, processLogsRequired, probeFailed
    var errorDescription: String? {
        switch self {
        case .configurationEditorRequired: "Apply changes through the MClash configuration editor."
        case .sourceEditorRequired: "MClash manages subscriptions in Sources."
        case .captureRequired: "Per-connection inspection and close are available for App Routing capture."
        case .processLogsRequired: "Xray logs are available through the core process log."
        case .probeFailed: "The node did not complete the HTTP probe."
        }
    }
}
