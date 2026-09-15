import Foundation
import CryptoKit
import MClashAutomationProtocol

struct XrayTrafficSample: Sendable {
    let uploaded: Int64
    let downloaded: Int64
    let sampledAt: Date
}

enum XrayControlError: Error, LocalizedError {
    case invalidSelection
    case unsupportedGroup
    case busy
    case invalidProbeURL
    case rejectedUpdate
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .invalidSelection: "The selected member is unavailable in this MClash group."
        case .unsupportedGroup: "This group requires a routing operation that has not been configured."
        case .busy: "The node probe limit has been reached. Try again after the current probes finish."
        case .invalidProbeURL: "Node probes require an HTTP or HTTPS URL without embedded credentials."
        case .rejectedUpdate: "Xray did not confirm the requested route selection."
        case .rollbackFailed: "Xray could not restore the previous route selection. Reconnect before retrying."
        }
    }
}

actor XrayControlSession {
    private struct SavedState: Codable {
        var overrides: [ProxyGroupID: ProxyGroupMember] = [:]
        var selections: [ProxyGroupID: GroupSelectionState] = [:]
        var probes: [GroupProbeResult] = []
    }

    private(set) var plan: XrayRuntimePlan
    private var document: ConfigurationDocument
    private let binary: URL
    private let socketPath: String
    private let directory: URL
    private let stateFile: URL
    private let configurationURL: URL
    private var capturedRuleIDs: Set<RoutingRuleID>
    private let commands: CoreSupervisor
    private var saved: SavedState
    private var appliedTargets: [ProxyGroupID: String] = [:]
    private var appliedPools: [ProxyGroupID: [String]] = [:]
    private var knownChainTags = Set<String>()
    private var knownInbounds: [String: XrayInbound]
    private var knownOutbounds: Set<String>
    private var lastPersistence = Date.distantPast
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeProbes = Set<NodeID>()
    private var resolutions: [ProxyGroupID: ProxyGroupResolution] = [:]

    init(plan: XrayRuntimePlan, document: ConfigurationDocument, binary: URL,
         apiSocketPath: String, directory: URL, commands: CoreSupervisor,
         configurationURL: URL? = nil, capturedRuleIDs: Set<RoutingRuleID> = []) throws {
        self.plan = plan
        self.document = document
        self.binary = binary
        self.socketPath = apiSocketPath
        self.directory = directory
        self.commands = commands
        self.configurationURL = configurationURL ?? directory.appending(path: "config.json")
        self.capturedRuleIDs = capturedRuleIDs
        knownInbounds = Dictionary(uniqueKeysWithValues: plan.inbounds.map { ($0.tag, $0) })
        knownOutbounds = Set((plan.configuration["outbounds"]?.arrayValue ?? []).compactMap { $0.objectValue?["tag"]?.stringValue })
        stateFile = directory.appending(path: "group-state.json")
        if FileManager.default.fileExists(atPath: stateFile.path) {
            let data = try Data(contentsOf: stateFile)
            guard data.count <= 4 * 1024 * 1024 else { throw XrayControlError.rejectedUpdate }
            saved = try JSONDecoder().decode(SavedState.self, from: data)
        } else {
            saved = SavedState()
        }
    }

    func prepare() async throws {
        await beginMutation()
        defer { endMutation() }
        appliedTargets = [:]
        appliedPools = [:]
        knownChainTags = []
        knownInbounds = Dictionary(uniqueKeysWithValues: plan.inbounds.map { ($0.tag, $0) })
        knownOutbounds = Set((plan.configuration["outbounds"]?.arrayValue ?? []).compactMap { $0.objectValue?["tag"]?.stringValue })
        try await applyPolicy(saved)
    }

    func select(groupID: ProxyGroupID, member: ProxyGroupMember?) async throws {
        await beginMutation()
        defer { endMutation() }
        guard let group = plan.groups.first(where: { $0.id == groupID }) else { throw XrayControlError.invalidSelection }
        if let member, !group.members.contains(member) { throw XrayControlError.invalidSelection }
        var candidate = saved
        candidate.overrides[groupID] = member
        try await applyPolicy(candidate)
    }

    func groupResolutions() -> [ProxyGroupID: ProxyGroupResolution] { resolutions }
    func overrides() -> [ProxyGroupID: ProxyGroupMember] { saved.overrides }
    func probeResults() -> [GroupProbeResult] { saved.probes }

    func reconfigure(plan replacement: XrayRuntimePlan, document candidateDocument: ConfigurationDocument,
                     capturedRuleIDs candidateCaptured: Set<RoutingRuleID>) async throws {
        await beginMutation()
        defer { endMutation() }
        let identities = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.id, $0.connectionFingerprint) })
        let candidates = Dictionary(uniqueKeysWithValues: replacement.nodes.map { ($0.id, $0.connectionFingerprint) })
        guard identities == candidates, plan.configuration["dns"] == replacement.configuration["dns"],
              plan.configuration["fakedns"] == replacement.configuration["fakedns"] else {
            throw XrayRuntimeOperationError.configurationEditorRequired
        }
        for input in replacement.inbounds {
            if let old = knownInbounds[input.tag],
               old.kind != input.kind || old.bindAddress != input.bindAddress || old.port != input.port || old.authentication != input.authentication {
                throw XrayRuntimeOperationError.configurationEditorRequired
            }
        }
        let previousPlan = plan
        let previousDocument = document
        let previousCaptured = capturedRuleIDs
        let previousTargets = appliedTargets
        let previousPools = appliedPools
        let previousSaved = saved
        let previousResolutions = resolutions
        let previousPersistence = lastPersistence
        let previousChainTags = knownChainTags
        let previousStateData = FileManager.default.fileExists(atPath: stateFile.path) ? try Data(contentsOf: stateFile) : nil
        let previousConfigData = try Data(contentsOf: configurationURL)
        var addedInputs: [String] = []
        var addedOutputs: [String] = []
        let staging = directory.appending(path: "update-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: staging) }
        try write(replacement.configuration, to: staging)
        _ = try await commands.runCommand(executableURL: binary, arguments: ["run", "-test", "-config", staging.path], directory: directory)
        do {
            for output in replacement.configuration["outbounds"]?.arrayValue ?? [] {
                guard let tag = output.objectValue?["tag"]?.stringValue, !knownOutbounds.contains(tag) else { continue }
                try write(["outbounds": AutomationJSONValue.array([output])], to: staging)
                _ = try await api("ado", [staging.path])
                knownOutbounds.insert(tag)
                addedOutputs.append(tag)
            }
            for input in replacement.configuration["inbounds"]?.arrayValue ?? [] {
                guard let tag = input.objectValue?["tag"]?.stringValue, knownInbounds[tag] == nil,
                      let descriptor = replacement.inbounds.first(where: { $0.tag == tag }) else { continue }
                try write(["inbounds": AutomationJSONValue.array([input])], to: staging)
                _ = try await api("adi", [staging.path])
                knownInbounds[tag] = descriptor
                addedInputs.append(tag)
            }
            try await installRouting(replacement)
            plan = replacement
            document = candidateDocument
            capturedRuleIDs = candidateCaptured
            try await applyPolicy(saved)
            try write(replacement.configuration, to: configurationURL)
        } catch {
            plan = previousPlan
            document = previousDocument
            capturedRuleIDs = previousCaptured
            appliedTargets = previousTargets
            appliedPools = previousPools
            saved = previousSaved
            resolutions = previousResolutions
            lastPersistence = previousPersistence
            var restored = true
            do { try await installRouting(previousPlan) } catch { restored = false }
            for tag in addedInputs {
                do { _ = try await api("rmi", [tag]); knownInbounds[tag] = nil } catch { restored = false }
            }
            for tag in addedOutputs {
                do { _ = try await api("rmo", [tag]); knownOutbounds.remove(tag) } catch { restored = false }
            }
            for tag in knownChainTags.subtracting(previousChainTags) {
                do { _ = try await api("rmo", [tag]); knownChainTags.remove(tag) } catch { restored = false }
            }
            do {
                if (try? Data(contentsOf: configurationURL)) != previousConfigData {
                    try previousConfigData.write(to: configurationURL, options: .atomic)
                }
                if let previousStateData {
                    try previousStateData.write(to: stateFile, options: .atomic)
                } else if FileManager.default.fileExists(atPath: stateFile.path) {
                    try FileManager.default.removeItem(at: stateFile)
                }
            } catch { restored = false }
            if !restored { throw XrayControlError.rollbackFailed }
            throw error
        }
    }

    func setMode(_ mode: ConfigurationRoutingMode, globalExit: ProxyGroupID? = nil) async throws {
        await beginMutation()
        defer { endMutation() }
        var candidate = document
        guard let index = candidate.workspaces.firstIndex(where: { $0.id == plan.workspace.id }) else {
            throw XrayControlError.rejectedUpdate
        }
        candidate.workspaces[index].routingMode = mode
        if let globalExit {
            guard plan.groupTags[globalExit] != nil else { throw XrayControlError.invalidSelection }
            candidate.workspaces[index].globalProxyGroupID = globalExit
        }
        let replacement = try XrayConfigurationCompiler.compile(document: candidate, workspaceID: plan.workspace.id,
            inbounds: plan.inbounds, apiSocketPath: socketPath, capturedRuleIDs: capturedRuleIDs, logDirectory: directory.path)
        do {
            try await installRouting(replacement)
            try write(replacement.configuration, to: configurationURL)
            document = candidate
            plan = replacement
        } catch {
            do { try await installRouting(plan) }
            catch { throw XrayControlError.rollbackFailed }
            throw error
        }
    }

    private func installRouting(_ replacement: XrayRuntimePlan,
                                targets: [ProxyGroupID: String]? = nil, pools: [ProxyGroupID: [String]]? = nil) async throws {
        guard var routing = replacement.configuration["routing"]?.objectValue else { throw XrayControlError.rejectedUpdate }
        let targets = targets ?? appliedTargets
        let pools = pools ?? appliedPools
        let currentInputs = Set(replacement.inbounds.map(\.tag))
        let retiredInputs = knownInbounds.keys.filter { !currentInputs.contains($0) }.sorted()
        if !retiredInputs.isEmpty {
            var rules = routing["rules"]?.arrayValue ?? []
            rules.insert(.object(["type": .string("field"), "inboundTag": .array(retiredInputs.map(AutomationJSONValue.string)),
                                  "outboundTag": .string("reject")]), at: 0)
            routing["rules"] = .array(rules)
        }
        routing["balancers"] = .array(replacement.groups.map { group in
            let pool = pools[group.id]
            return .object(["tag": .string(XrayRuntimePlan.groupTag(group.id)),
                     "selector": .array((pool ?? [targets[group.id] ?? "reject"]).map(AutomationJSONValue.string)),
                     "strategy": .object(["type": .string(pool == nil ? "random" : "roundRobin")])])
        })
        let file = directory.appending(path: "routing-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try write(["routing": AutomationJSONValue.object(routing)], to: file)
        _ = try await api("adrules", [file.path])
    }

    func traffic() async throws -> XrayTrafficSample {
        let bytes = try await api("statsquery", ["-pattern", "inbound>>>"])
        let json = try JSONDecoder().decode(AutomationJSONValue.self, from: bytes)
        var upload: Int64 = 0
        var download: Int64 = 0
        for row in json.objectValue?["stat"]?.arrayValue ?? [] {
            guard let fields = row.objectValue, let name = fields["name"]?.stringValue,
                  !name.hasPrefix("inbound>>>probe-") else { continue }
            let value = fields["value"]?.intValue.map(Int64.init) ?? fields["value"]?.stringValue.flatMap(Int64.init) ?? 0
            if name.hasSuffix(">>>uplink") { upload += max(0, value) }
            if name.hasSuffix(">>>downlink") { download += max(0, value) }
        }
        return XrayTrafficSample(uploaded: upload, downloaded: download, sampledAt: Date())
    }

    func probe(nodeID: NodeID, targetURL: URL = ProxyGroupPolicySettings.defaultTestURL,
               timeout: TimeInterval = 5, expectedStatus: String? = nil) async throws -> GroupProbeResult {
        let expected = expectedStatus ?? (targetURL == ProxyGroupPolicySettings.defaultTestURL ? "204" : "200-299")
        guard let statuses = HTTPStatusExpectation.parse(expected), (0.1...30).contains(timeout) else {
            throw XrayControlError.invalidProbeURL
        }
        guard ["http", "https"].contains(targetURL.scheme?.lowercased() ?? ""), targetURL.host != nil,
              targetURL.user == nil, targetURL.password == nil else { throw XrayControlError.invalidProbeURL }
        guard activeProbes.count < 4, activeProbes.insert(nodeID).inserted else { throw XrayControlError.busy }
        defer { activeProbes.remove(nodeID) }
        guard let node = plan.nodes.first(where: { $0.id == nodeID }), plan.nodeTags[nodeID] != nil else {
            throw XrayControlError.invalidSelection
        }
        let port = try LocalPortProbe().availableTCPPort()
        let tag = XrayRuntimePlan.probeTag(nodeID)
        let working = directory.appending(path: "probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: working) }
        let user = UUID().uuidString
        let password = UUID().uuidString
        let config: [String: AutomationJSONValue] = ["inbounds": .array([.object([
            "tag": .string(tag), "listen": .string("127.0.0.1"), "port": .integer(Int64(port)), "protocol": .string("http"),
            "settings": .object(["accounts": .array([.object(["user": .string(user), "pass": .string(password)])])]),
        ])])]
        let jsonPath = working.appending(path: "inbound.json")
        try write(config, to: jsonPath)
        _ = try await api("adi", [jsonPath.path])
        var outcome: GroupProbeResult.Outcome
        do {
            let curlConfig = working.appending(path: "curl.conf")
            let lines = [
                "silent", "show-error", "max-filesize = 65536", "output = \"/dev/null\"", "noproxy = \"\"",
                "proxy = \"http://127.0.0.1:\(port)\"", "proxy-user = \"\(user):\(password)\"",
                "url = \(quoted(targetURL.absoluteString))", "max-time = \(max(0.1, min(30, timeout)))",
                "write-out = \"%{http_code} %{time_total}\"",
            ].joined(separator: "\n")
            try Data(lines.utf8).write(to: curlConfig)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: curlConfig.path)
            let probeCommand = CoreSupervisor(validationTimeout: max(1, min(30, timeout)) + 2)
            let response = try await probeCommand.runCommand(executableURL: URL(fileURLWithPath: "/usr/bin/curl"),
                arguments: ["--config", curlConfig.path], directory: directory)
            let fields = String(decoding: response, as: UTF8.self).split(separator: " ")
            if fields.count == 2, let status = Int(fields[0]), statuses.contains(where: { $0.contains(status) }),
               let seconds = Double(fields[1]), seconds.isFinite, seconds >= 0 {
                outcome = .available(latencyMilliseconds: max(1, Int((seconds * 1000).rounded())))
            } else {
                outcome = .failed(stage: "http_status")
            }
        } catch is CancellationError {
            _ = try? await api("rmi", [tag])
            throw CancellationError()
        } catch {
            outcome = .failed(stage: "request_failed")
        }
        _ = try await api("rmi", [tag])
        let result = GroupProbeResult(nodeID: nodeID, connectionFingerprint: node.connectionFingerprint,
                                     checkedAt: Date(), outcome: outcome, targetURL: targetURL, expectedStatus: expected, timeoutSeconds: timeout)
        await beginMutation()
        defer { endMutation() }
        var candidate = saved
        candidate.probes.removeAll { $0.nodeID == nodeID && $0.connectionFingerprint != node.connectionFingerprint }
        let matching = candidate.probes.filter { $0.nodeID == nodeID && $0.targetURL == targetURL && $0.expectedStatus == expected && $0.timeoutSeconds == timeout }.sorted { $0.checkedAt > $1.checkedAt }
        let keep = Set(matching.prefix(4).map(\.checkedAt))
        candidate.probes.removeAll { $0.nodeID == nodeID && $0.targetURL == targetURL && $0.expectedStatus == expected && $0.timeoutSeconds == timeout && !keep.contains($0.checkedAt) }
        candidate.probes.append(result)
        try await applyPolicy(candidate, persistHealth: false)
        return result
    }

    private func applyPolicy(_ proposed: SavedState, persistHealth: Bool = true) async throws {
        try Task.checkCancellation()
        var activeDocument = document
        activeDocument.nodes = plan.nodes.map { node in
            var candidate = node
            if plan.nodeTags[node.id] == nil { candidate.health.availability = .unsupported }
            return candidate
        }
        let next = ProxyGroupPolicy.resolve(document: activeDocument, workspace: plan.workspace,
            persistedOverrides: proposed.overrides, probes: proposed.probes, previousSelections: proposed.selections)
        var targets: [ProxyGroupID: String] = [:]
        var pools: [ProxyGroupID: [String]] = [:]
        for (id, result) in next {
            switch result.destination {
            case let .node(nodeID):
                guard let tag = plan.nodeTags[nodeID] else { throw XrayControlError.invalidSelection }
                targets[id] = tag
            case .direct: targets[id] = "direct"
            case .reject, .unsupported: targets[id] = "reject"
            case let .balance(ids):
                var unique = Set<String>()
                let tags = ids.compactMap { plan.nodeTags[$0] }.filter { unique.insert($0).inserted }
                guard !tags.isEmpty else { throw XrayControlError.invalidSelection }
                pools[id] = tags
            case let .chain(ids):
                targets[id] = try await prepareChain(groupID: id, nodes: ids)
            }
        }
        let previous = appliedTargets
        let previousPools = appliedPools
        let routingChanged = pools != previousPools
        var changed: [ProxyGroupID] = []
        do {
            if routingChanged { try await installRouting(plan, targets: targets, pools: pools) }
            for id in targets.keys.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
                guard let target = targets[id], target != previous[id], let balancer = plan.groupTags[id] else { continue }
                _ = try await api("bo", ["-b", balancer, target])
                changed.append(id)
                let bytes = try await api("bi", ["--json", balancer])
                let info = try JSONDecoder().decode(AutomationJSONValue.self, from: bytes)
                guard info.objectValue?["balancer"]?.objectValue?["override"]?.objectValue?["target"]?.stringValue == target else {
                    throw XrayControlError.rejectedUpdate
                }
            }
            var committed = proposed
            for (id, result) in next {
                if let member = result.selectedMember, committed.selections[id]?.member != member {
                    committed.selections[id] = GroupSelectionState(member: member, selectedAt: Date())
                }
            }
            if persistHealth || !changed.isEmpty || routingChanged || Date().timeIntervalSince(lastPersistence) >= 60 {
                try write(committed, to: stateFile)
                lastPersistence = Date()
            }
            saved = committed
            appliedTargets = targets
            appliedPools = pools
            resolutions = next
        } catch {
            var restored = true
            if routingChanged {
                do { try await installRouting(plan, targets: previous, pools: previousPools) }
                catch { restored = false }
            }
            for id in changed.reversed() {
                guard let balancer = plan.groupTags[id] else { continue }
                do {
                    let target = previous[id] ?? "reject"
                    _ = try await api("bo", ["-b", balancer, target])
                    let bytes = try await api("bi", ["--json", balancer])
                    let info = try JSONDecoder().decode(AutomationJSONValue.self, from: bytes)
                    guard info.objectValue?["balancer"]?.objectValue?["override"]?.objectValue?["target"]?.stringValue == target else {
                        throw XrayControlError.rollbackFailed
                    }
                }
                catch { restored = false }
            }
            if !restored { throw XrayControlError.rollbackFailed }
            throw error
        }
    }

    private func prepareChain(groupID: ProxyGroupID, nodes ids: [NodeID]) async throws -> String {
        guard !ids.isEmpty, ids.count <= 16 else { throw XrayControlError.unsupportedGroup }
        let nodes = try ids.map { id -> Node in
            guard let node = plan.nodes.first(where: { $0.id == id }), plan.nodeTags[id] != nil else {
                throw XrayControlError.invalidSelection
            }
            return node
        }
        let identity = nodes.map(\.connectionFingerprint).joined(separator: "|")
        let fingerprint = SHA256.hash(data: Data(identity.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        var previous: String?
        for (index, node) in nodes.enumerated() {
            let tag = "chain-" + groupID.rawValue.uuidString.lowercased() + "-" + fingerprint + "-" + String(index)
            if !knownChainTags.contains(tag) {
                guard var outbound = try XrayNodeRenderer.render(node, tag: tag).objectValue else { throw XrayControlError.invalidSelection }
                if let previous {
                    var stream = outbound["streamSettings"]?.objectValue ?? [:]
                    var options = stream["sockopt"]?.objectValue ?? [:]
                    options["dialerProxy"] = .string(previous)
                    stream["sockopt"] = .object(options)
                    outbound["streamSettings"] = .object(stream)
                }
                let file = directory.appending(path: "chain-" + UUID().uuidString + ".json")
                defer { try? FileManager.default.removeItem(at: file) }
                try write(["outbounds": AutomationJSONValue.array([.object(outbound)])], to: file)
                _ = try await api("ado", [file.path])
                knownChainTags.insert(tag)
            }
            previous = tag
        }
        guard let previous else { throw XrayControlError.invalidSelection }
        return previous
    }

    private func api(_ command: String, _ arguments: [String] = []) async throws -> Data {
        try await commands.runCommand(executableURL: binary,
            arguments: ["api", command, "--server=unix:" + socketPath, "--timeout=3"] + arguments, directory: directory)
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func beginMutation() async {
        if mutationInProgress {
            await withCheckedContinuation { mutationWaiters.append($0) }
        } else {
            mutationInProgress = true
        }
    }

    private func endMutation() {
        if mutationWaiters.isEmpty { mutationInProgress = false }
        else { mutationWaiters.removeFirst().resume() }
    }
}
