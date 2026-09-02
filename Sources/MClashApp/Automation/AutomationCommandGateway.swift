import AppKit
import CryptoKit
import Foundation
import MClashAutomationProtocol
import MClashNetworkShared

@MainActor
final class AutomationCommandGateway {
    typealias ShowWindow = @MainActor (AppModel.Destination) -> Void

    private let model: AppModel
    private let updater: ApplicationUpdater
    private let showWindow: ShowWindow
    private let authorizationStore: AutomationAuthorizationStore
    /// The gateway is currently only exposed through a private, same-user Unix
    /// socket.  The socket server has already authenticated the peer with
    /// getpeereid, ownership/permissions, and process identity, so repeating
    /// the Keychain-backed pairing flow here only creates an authorization
    /// prompt loop (especially after helper updates).
    private let localSocketTrusted: Bool
    private var mutationInProgress = false
    private var lastPairingPromptAt: Date?
    private var lastInteractionPromptAt: Date?
    private var cachedMutations: [String: CachedMutation] = [:]
    private var cachedMutationOrderByClient: [UUID: [String]] = [:]
    private var cachedMutationBytesByClient: [UUID: Int] = [:]
    private var cachedMutationGlobalOrder: [String] = []
    private var cachedMutationGlobalBytes = 0
    private var candidateCache: CandidateCache?

    init(
        model: AppModel,
        updater: ApplicationUpdater,
        authorizationStore: AutomationAuthorizationStore,
        showWindow: @escaping ShowWindow,
        localSocketTrusted: Bool = false
    ) {
        self.model = model
        self.updater = updater
        self.authorizationStore = authorizationStore
        self.showWindow = showWindow
        self.localSocketTrusted = localSocketTrusted
    }

    func execute(
        _ request: AutomationRPCRequest,
        peer: AutomationPeerIdentity,
        pairingMayCommit: @Sendable () -> Bool = { true }
    ) async -> AutomationRPCResponse {
        var mutationCacheContext: MutationCacheContext?
        do {
            guard request.jsonrpc == "2.0" else {
                throw GatewayError.invalidRequest("jsonrpc must be 2.0")
            }
            guard request.apiVersion == MClashAutomationProtocol.currentVersion else {
                throw GatewayError.unsupportedVersion(request.apiVersion)
            }
            guard let capability = Self.capabilities.first(where: {
                $0.method == request.method
            }) else {
                throw GatewayError.methodNotFound(request.method)
            }
            try Self.validateParameters(request)
            if request.method == "auth.pair" {
                if localSocketTrusted {
                    // Keep the method for protocol compatibility with older
                    // clients, but never prompt or persist a token for the
                    // already-authenticated local transport.
                    return AutomationRPCResponse(
                        id: request.id,
                        result: .object(["alreadyTrusted": .bool(true)])
                    )
                }
                guard !mutationInProgress else {
                    throw GatewayError.operationInProgress
                }
                if let lastPairingPromptAt,
                   Date().timeIntervalSince(lastPairingPromptAt) < 30 {
                    throw GatewayError.pairingRateLimited
                }
                mutationInProgress = true
                defer { mutationInProgress = false }
                return AutomationRPCResponse(
                    id: request.id,
                    result: try pair(
                        request: request,
                        peer: peer,
                        mayCommit: pairingMayCommit
                    )
                )
            }
            var authorizedClient: AutomationAuthorizationStore.PublicClient?
            if request.method != "system.capabilities", !localSocketTrusted {
                authorizedClient = try authorizationStore.authorize(
                    token: request.authorization,
                    requiredScope: Self.requiredScope(for: capability),
                    peer: peer
                )
            }
            let ownsMutationSlot = capability.risk != .read
            let requestDigest = mutationRequestDigest(request)
            let cacheKey = mutationCacheKey(
                request: request,
                clientIdentifier: authorizedClient?.id
            )
            if ownsMutationSlot, let cached = cachedMutations[cacheKey] {
                guard cached.requestDigest == requestDigest else {
                    throw GatewayError.invalidRequest(
                        "A request id cannot be reused with different parameters"
                    )
                }
                return cached.response
            }
            if Self.inherentlyInteractiveMethods.contains(request.method) {
                guard request.allowInteraction else {
                    throw GatewayError.confirmationRequired(request.method)
                }
                try beginInteractivePresentation()
            }
            if ownsMutationSlot {
                guard !mutationInProgress else {
                    throw GatewayError.operationInProgress
                }
                mutationInProgress = true
            }
            defer {
                if ownsMutationSlot { mutationInProgress = false }
            }
            if capability.risk == .destructive,
               !localSocketTrusted,
               authorizedClient?.trust != .trusted {
                try confirmDestructiveRequest(
                    request,
                    summary: capability.summary,
                    peer: peer,
                    client: authorizedClient
                )
            }
            if ownsMutationSlot, let clientIdentifier = authorizedClient?.id {
                mutationCacheContext = MutationCacheContext(
                    key: cacheKey,
                    clientIdentifier: clientIdentifier,
                    requestDigest: requestDigest
                )
            }
            let response = AutomationRPCResponse(
                id: request.id,
                result: try await perform(request, peer: peer)
            )
            cacheMutation(response, context: mutationCacheContext)
            return response
        } catch let error as GatewayError {
            let response = AutomationRPCResponse(id: request.id, error: error.rpcError)
            cacheMutation(response, context: mutationCacheContext)
            return response
        } catch let error as AuthorizationError {
            let response = AutomationRPCResponse(id: request.id, error: error.rpcError)
            cacheMutation(response, context: mutationCacheContext)
            return response
        } catch {
            let response = AutomationRPCResponse(
                id: request.id,
                error: AutomationRPCError(
                    code: -32603,
                    type: "operation_failed",
                    message: "The operation failed",
                    retryable: false
                )
            )
            cacheMutation(response, context: mutationCacheContext)
            return response
        }
    }

    private func perform(
        _ request: AutomationRPCRequest,
        peer: AutomationPeerIdentity
    ) async throws
        -> AutomationJSONValue
    {
        switch request.method {
        case "system.capabilities":
            return try encode(Self.capabilitiesForClients)
        case "system.snapshot":
            return snapshot()
        case "auth.clients.list":
            return try encode(authorizationStore.list())
        case "auth.clients.revoke":
            guard let id = UUID(uuidString: try request.string("id")) else {
                throw GatewayError.invalidParameters("id must be a client UUID")
            }
            try authorizationStore.revoke(id: id)
            removeCachedMutations(clientIdentifier: id)
            return accepted()
        case "app.ui.show":
            let destination = try destination(request.string("destination", default: "overview"))
            model.selection = destination
            showWindow(destination)
            return accepted()
        case "app.ui.hide":
            NSApplication.shared.hide(nil)
            return accepted()
        case "app.quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApplication.shared.terminate(nil)
            }
            return accepted()
        case "app.update.status":
            return updaterStatus()
        case "app.update.check":
            guard updater.canCheckForUpdates else {
                throw GatewayError.operationFailed("The update checker is not ready", true)
            }
            updater.checkForUpdates()
            return accepted()
        case "app.update.configure":
            if let enabled = request.optionalBool("automaticChecks") {
                updater.setAutomaticallyChecksForUpdates(enabled)
            }
            if let enabled = request.optionalBool("automaticDownloads") {
                updater.setAutomaticallyDownloadsUpdates(enabled)
            }
            return updaterStatus()
        case "settings.get":
            return settings()
        case "settings.patch":
            if let value = request.optionalBool("launchAtLogin") {
                try model.setLaunchAtLogin(value)
            }
            if let value = request.optionalBool("notificationsEnabled") {
                await model.setNotificationsEnabled(value)
            }
            if let value = request.optionalBool("autoConnectOnLaunch") {
                model.autoConnectOnLaunch = value
            }
            if let value = request.optionalBool("autoEnableSystemProxy") {
                model.autoEnableSystemProxy = value
            }
            if let value = request.optionalBool("lightweightMode") {
                model.lightweightMode = value
            }
            if let value = request.optionalString("menuBarDisplayStyle") {
                guard let style = AppModel.MenuBarDisplayStyle(rawValue: value) else {
                    throw GatewayError.invalidParameters(
                        "menuBarDisplayStyle must be logo or proxyStatus"
                    )
                }
                model.menuBarDisplayStyle = style
            }
            if let value = request.optionalBool("closeConnectionsOnRoutingChange") {
                model.closeConnectionsOnRoutingChange = value
            }
            return settings()
        case "configuration.snapshot":
            let nodePage = try pageBounds(
                count: model.configurationDocument.nodes.count,
                request: request,
                maximumLimit: 200,
                offsetParameter: "nodeOffset",
                limitParameter: "nodeLimit",
                defaultLimit: 100
            )
            let sourcePage = try pageBounds(
                count: model.configurationDocument.sources.count,
                request: request,
                maximumLimit: 100,
                offsetParameter: "sourceOffset",
                limitParameter: "sourceLimit",
                defaultLimit: 50
            )
            return try encode(model.configurationAutomationSnapshot(
                nodeOffset: nodePage.offset,
                nodeLimit: nodePage.limit,
                sourceOffset: sourcePage.offset,
                sourceLimit: sourcePage.limit
            ))
        case "configuration.proxyGroup.selectors.export":
            do {
                guard let groupUUID = UUID(uuidString: try request.string("groupID")) else {
                    throw GatewayError.invalidParameters("groupID must be a proxy group UUID")
                }
                let data = try model.configurationAutomationSelectorData(
                    groupID: ProxyGroupID(rawValue: groupUUID),
                    expectedRevision: try request.configurationRevision()
                )
                let page = try pageBounds(
                    count: data.count,
                    request: request,
                    maximumLimit: 512 * 1_024,
                    limitParameter: "limitBytes",
                    defaultLimit: 256 * 1_024
                )
                let hasMore = page.range.upperBound < data.count
                let digest = SHA256.hash(data: data).map {
                    String(format: "%02x", $0)
                }.joined()
                return .object([
                    "configurationRevision": .string(
                        model.configurationRevision.uuidString.lowercased()
                    ),
                    "groupID": .string(groupUUID.uuidString.lowercased()),
                    "offset": .integer(Int64(page.offset)),
                    "limitBytes": .integer(Int64(page.limit)),
                    "totalBytes": .integer(Int64(data.count)),
                    "hasMore": .bool(hasMore),
                    "nextOffset": hasMore
                        ? .integer(Int64(page.range.upperBound)) : .null,
                    "sha256": .string(digest),
                    "dataBase64": .string(Data(data[page.range]).base64EncodedString()),
                ])
            } catch {
                throw configurationGatewayError(error)
            }
        case "configuration.plan":
            do {
                let document: ConfigurationAutomationDocument = try request.decode("document")
                return try encode(model.planConfigurationAutomationDocument(
                    document,
                    expectedRevision: try request.configurationRevision()
                ))
            } catch {
                throw configurationGatewayError(error)
            }
        case "configuration.apply":
            do {
                let document: ConfigurationAutomationDocument = try request.decode("document")
                let plan = try await model.applyConfigurationAutomationDocument(
                    document,
                    expectedRevision: try request.configurationRevision()
                )
                return try configurationMutationReceipt(
                    plan: plan,
                    currentSessionChanged: false
                )
            } catch {
                throw configurationGatewayError(error)
            }
        case "configuration.delete":
            do {
                guard let kind = ConfigurationAutomationObjectKind(
                    rawValue: try request.string("kind")
                ) else {
                    throw GatewayError.invalidParameters(
                        "kind must be proxyGroup, rule, ruleSet, dnsPolicy, entrance, or workspace"
                    )
                }
                guard let id = UUID(uuidString: try request.string("id")) else {
                    throw GatewayError.invalidParameters("id must be an object UUID")
                }
                let plan = try await model.deleteConfigurationAutomationObject(
                    kind: kind,
                    id: id,
                    expectedRevision: try request.configurationRevision()
                )
                var receipt = try configurationMutationReceipt(
                    plan: plan,
                    currentSessionChanged: false
                ).objectValue ?? [:]
                receipt["deletedKind"] = .string(kind.rawValue)
                receipt["deletedID"] = .string(id.uuidString.lowercased())
                return .object(receipt)
            } catch {
                throw configurationGatewayError(error)
            }
        case "configuration.workspace.activate":
            do {
                guard let id = UUID(uuidString: try request.string("id")) else {
                    throw GatewayError.invalidParameters("id must be a workspace UUID")
                }
                let currentSessionChanged = try await model.activateConfigurationWorkspace(
                    WorkspaceID(rawValue: id),
                    expectedConfigurationRevision: try request.configurationRevision()
                )
                guard let runtimeSnapshot = model.configurationDocument.lastRuntimeSnapshot else {
                    throw GatewayError.operationFailed(
                        "The activated workspace did not produce a runtime snapshot",
                        false
                    )
                }
                return .object([
                    "configurationRevision": .string(
                        model.configurationRevision.uuidString.lowercased()
                    ),
                    "workspaceID": .string(id.uuidString.lowercased()),
                    "activated": .bool(true),
                    "currentSessionChanged": .bool(currentSessionChanged),
                    "runtimeSnapshot": try encode(
                        ConfigurationAutomationRuntimeSnapshot(runtimeSnapshot)
                    ),
                ])
            } catch {
                throw configurationGatewayError(error)
            }
        case "core.status":
            return coreStatus()
        case "core.toggle":
            let shouldConnect = !model.isConnected && !model.isBusy
            await model.toggleConnection()
            if shouldConnect {
                try require(model.isConnected, "The Mihomo core did not connect")
            } else {
                try require(!model.isConnected && !model.isBusy, "The Mihomo core did not stop")
            }
            return coreStatus()
        case "core.connect":
            await model.connect()
            try require(model.isConnected, "The Mihomo core did not connect")
            return coreStatus()
        case "core.disconnect":
            await model.disconnect()
            try require(!model.isConnected && !model.isBusy, "The Mihomo core did not stop")
            return coreStatus()
        case "core.restart":
            await model.restartConnection()
            try require(model.isConnected, "The Mihomo core did not restart")
            return coreStatus()
        case "profiles.list":
            return try profiles(request: request)
        case "profiles.importInteractive":
            let previousIDs = Set(model.profiles.map(\.id))
            await model.importProfile()
            return profileCreationReceipt(previousIDs: previousIDs)
        case "profiles.import":
            let encoded = try request.string("dataBase64")
            guard let data = Data(base64Encoded: encoded),
                  data.count <= MClashAutomationProtocol.maximumInlineProfileSize else {
                throw GatewayError.invalidParameters(
                    "dataBase64 must contain a profile no larger than 700 KiB"
                )
            }
            let profile = try await model.importProfile(
                data: data,
                suggestedFileName: request.string("fileName", default: "profile.yaml"),
                activate: request.bool("activate", default: true)
            )
            return .object([
                "id": .string(profile.id.description),
            ])
        case "profiles.addSubscription":
            let urlString = try request.string("url")
            guard let url = URL(string: urlString),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw GatewayError.invalidParameters("url must be an HTTP or HTTPS URL")
            }
            let previousIDs = Set(model.profiles.map(\.id))
            try await model.addRemoteProfile(
                name: try request.string("name"),
                url: url,
                activate: request.bool("activate", default: true)
            )
            return profileCreationReceipt(previousIDs: previousIDs)
        case "profiles.activate":
            let id = try request.profileID()
            try await model.activateProfile(
                id,
                force: request.bool("force", default: false)
            )
            return .object([
                "accepted": .bool(true),
                "id": .string(id.description),
                "active": .bool(model.activeProfileID == id),
            ])
        case "profiles.update":
            let id = try request.profileID()
            guard let profile = model.profiles.first(where: { $0.id == id }) else {
                throw GatewayError.invalidParameters("Unknown profile id")
            }
            let url: URL?
            if let urlString = request.optionalString("subscriptionURL") {
                guard let parsed = URL(string: urlString),
                      ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else {
                    throw GatewayError.invalidParameters("subscriptionURL must be HTTP or HTTPS")
                }
                url = parsed
            } else if case let .remote(metadata) = profile.origin {
                url = metadata.url
            } else {
                url = nil
            }
            try await model.updateProfile(
                id,
                name: request.optionalString("name") ?? profile.name,
                subscriptionURL: url,
                automaticUpdatesEnabled: request.bool(
                    "automaticUpdatesEnabled",
                    default: profile.automaticUpdatesEnabled
                ),
                updateIntervalHours: request.params.keys.contains("updateIntervalHours")
                    ? request.optionalInt("updateIntervalHours")
                    : profile.updateIntervalHours
            )
            return .object([
                "accepted": .bool(true),
                "id": .string(id.description),
            ])
        case "profiles.refresh":
            let id = try request.profileID()
            try require(
                await model.refreshProfile(id),
                "The profile refresh failed"
            )
            return .object([
                "accepted": .bool(true),
                "id": .string(id.description),
            ])
        case "profiles.refreshAll":
            guard let receipt = await model.refreshAllProfiles() else {
                throw GatewayError.operationFailed("The profile refresh failed", true)
            }
            return .object([
                "updatedCount": .integer(Int64(receipt.updatedCount)),
                "unchangedCount": .integer(Int64(receipt.unchangedCount)),
                "failedCount": .integer(Int64(receipt.failedCount)),
            ])
        case "profiles.remove":
            let id = try request.profileID()
            guard model.profiles.contains(where: { $0.id == id }) else {
                throw GatewayError.invalidParameters("Unknown profile id")
            }
            await model.removeProfile(id)
            try require(
                !model.profiles.contains(where: { $0.id == id }),
                "The profile was not removed"
            )
            return .object([
                "accepted": .bool(true),
                "removedID": .string(id.description),
            ])
        case "profiles.pendingImport.get":
            guard let pending = model.pendingSubscriptionImport else { return .null }
            return .object([
                "name": .string(pending.name),
                "url": .string(redactedURL(pending.url)),
            ])
        case "profiles.pendingImport.confirm":
            guard let pending = model.pendingSubscriptionImport else {
                throw GatewayError.invalidParameters("There is no pending subscription import")
            }
            let previousIDs = Set(model.profiles.map(\.id))
            try require(
                await model.confirmPendingSubscriptionImport(pending),
                "The pending subscription import failed"
            )
            return profileCreationReceipt(previousIDs: previousIDs)
        case "profiles.pendingImport.cancel":
            model.cancelPendingSubscriptionImport()
            return accepted()
        case "backup.exportInteractive":
            guard let completed = await model.exportBackup() else {
                return .object(["cancelled": .bool(true)])
            }
            try require(completed, "The backup was not exported")
            return accepted()
        case "backup.restoreInteractive":
            guard let completed = await model.restoreBackup() else {
                return .object(["cancelled": .bool(true)])
            }
            try require(completed, "The backup was not restored")
            return accepted()
        case "runtime.get":
            return try encode(model.runtimeOverrides)
        case "runtime.overrides.replace":
            let overrides: RuntimeOverrides = try request.decode("overrides")
            let outcome = try await model.applyRuntimeOverrides(overrides)
            return .object(["outcome": .string(String(describing: outcome))])
        case "runtime.overrides.reset":
            let outcome = try await model.resetRuntimeOverrides()
            return .object(["outcome": .string(String(describing: outcome))])
        case "routing.status":
            return routingStatus()
        case "routing.mode.set":
            let mode = try request.string("mode").lowercased()
            guard ["rule", "global", "direct"].contains(mode) else {
                throw GatewayError.invalidParameters("mode must be rule, global, or direct")
            }
            await model.setMode(mode)
            try require(
                model.runtimeConfig?.mode.lowercased() == mode,
                "The routing mode was not changed"
            )
            return .object([
                "accepted": .bool(true),
                "mode": .string(mode),
            ])
        case "routing.groups.list":
            return try routingGroups(request: request)
        case "routing.group.choices.list":
            let groupName = try request.string("group")
            guard let group = model.proxyGroups.first(where: { $0.name == groupName }) else {
                throw GatewayError.invalidParameters("Unknown proxy group")
            }
            return try paged(
                group.all,
                request: request,
                maximumLimit: 200
            ).mergingObject(["group": .string(groupName)])
        case "routing.proxy.select":
            let success = await model.selectProxy(
                group: try request.string("group"),
                proxy: try request.string("proxy")
            )
            return .object(["selected": .bool(success)])
        case "routing.proxy.clearOverride":
            let success = await model.clearProxyOverride(group: try request.string("group"))
            return .object(["cleared": .bool(success)])
        case "routing.proxy.test":
            let delay = await model.measureDelay(
                proxy: try request.string("proxy"),
                group: request.optionalString("group")
            )
            return .object(["delayMilliseconds": delay.map {
                .integer(Int64($0))
            } ?? .null])
        case "routing.group.test":
            let group = try request.string("group")
            await model.measureGroupDelays(group: group)
            return .object([
                "accepted": .bool(true),
                "testedCount": .integer(Int64(model.proxyDelayMap(for: group).count)),
            ])
        case "mihomo.rules.list":
            return try paged(model.rules, request: request, maximumLimit: 500)
        case "mihomo.rules.refresh":
            try require(await model.refreshRules(), "Mihomo rules could not be refreshed")
            return .object([
                "accepted": .bool(true),
                "ruleCount": .integer(Int64(model.rules.count)),
                "lastLoadedAt": model.rulesLastLoadedAt.map {
                    .string($0.ISO8601Format())
                } ?? .null,
            ])
        case "providers.list":
            return try providers(request: request)
        case "providers.refresh":
            try require(await model.refreshProviders(), "Providers could not be refreshed")
            return .object([
                "accepted": .bool(true),
                "proxyProviderCount": .integer(Int64(model.proxyProviders.count)),
                "ruleProviderCount": .integer(Int64(model.ruleProviders.count)),
                "lastLoadedAt": model.providersLastLoadedAt.map {
                    .string($0.ISO8601Format())
                } ?? .null,
            ])
        case "providers.proxy.update":
            let name = try request.string("name")
            let startedAt = Date()
            await model.updateProxyProvider(name)
            try requireProviderReceipt(.updateProxy, name: name, startedAt: startedAt)
            return accepted()
        case "providers.proxy.healthCheck":
            let name = try request.string("name")
            let startedAt = Date()
            await model.healthCheckProxyProvider(name)
            try requireProviderReceipt(.healthCheckProxy, name: name, startedAt: startedAt)
            return accepted()
        case "providers.rule.update":
            let name = try request.string("name")
            let startedAt = Date()
            await model.updateRuleProvider(name)
            try requireProviderReceipt(.updateRule, name: name, startedAt: startedAt)
            return accepted()
        case "systemProxy.status":
            return systemProxyStatus()
        case "systemProxy.setEnabled":
            let enabled = try request.requiredBool("enabled")
            await model.setSystemProxyEnabled(enabled)
            try require(
                model.systemProxyEnabled == enabled,
                "The macOS System Proxy did not reach the requested state"
            )
            return systemProxyStatus()
        case "systemProxy.preferences.get":
            return try encode(model.systemProxyPreferences)
        case "systemProxy.preferences.replace":
            let preferences: SystemProxyPreferences = try request.decode("preferences")
            try await model.applySystemProxyPreferences(preferences)
            return accepted()
        case "systemProxy.guard.setPaused":
            try require(
                await model.setSystemProxyGuardPaused(try request.requiredBool("paused")),
                "The System Proxy guard preference was not applied"
            )
            return systemProxyStatus()
        case "systemProxy.guard.verify":
            try await model.verifySystemProxyGuardNow()
            return systemProxyStatus()
        case "appRouting.status":
            return appRoutingStatus()
        case "appRouting.setEnabled":
            let enabled = try request.requiredBool("enabled")
            await model.setNetworkCaptureEnabled(enabled)
            try require(
                model.networkCapturePreferences.enabled == enabled,
                "App Routing did not reach the requested state"
            )
            return appRoutingStatus()
        case "appRouting.retry":
            await model.retryNetworkCaptureActivation()
            return appRoutingStatus()
        case "appRouting.dns.setEnabled":
            let enabled = try request.requiredBool("enabled")
            await model.setDNSCaptureEnabled(enabled)
            try require(
                model.networkCapturePreferences.dnsEnabled == enabled,
                "App Routing DNS did not reach the requested state"
            )
            return appRoutingStatus()
        case "appRouting.dns.retry":
            await model.retryDNSCaptureActivation()
            return appRoutingStatus()
        case "appRouting.rules.list":
            return try paged(
                model.networkCapturePreferences.snapshot.rules,
                request: request,
                maximumLimit: 500
            ).mergingObject([
                "revision": .unsignedInteger(model.networkCapturePreferences.snapshot.revision),
            ])
        case "appRouting.candidates.list":
            let kind = try request.string("kind")
            guard ["applications", "processes"].contains(kind) else {
                throw GatewayError.invalidParameters(
                    "kind must be applications or processes"
                )
            }
            let candidates = await applicationCaptureCandidates()
            let result: AutomationJSONValue
            if kind == "applications" {
                let page = try pageBounds(
                    count: candidates.applications.count,
                    request: request,
                    maximumLimit: 50
                )
                let items: [AutomationJSONValue] = candidates.applications[page.range].map { candidate in
                    .object([
                        "id": .string(candidate.id),
                        "displayName": .string(candidate.displayName),
                        "bundleIdentifier": candidate.bundleIdentifier.map {
                            .string($0)
                        } ?? .null,
                        "executablePath": .string(candidate.executablePath),
                        "processIdentifiers": .array(candidate.runningProcessIdentifiers.map {
                            .integer(Int64($0))
                        }),
                        "fallbackIdentifierPatterns": .array(
                            candidate.fallbackIdentifierPatterns.map(AutomationJSONValue.string)
                        ),
                    ])
                }
                result = page.object(items: .array(items))
            } else {
                let page = try pageBounds(
                    count: candidates.processes.count,
                    request: request,
                    maximumLimit: 100
                )
                let items: [AutomationJSONValue] = candidates.processes[page.range].map { candidate in
                    .object([
                        "id": .string(candidate.id),
                        "displayName": .string(candidate.displayName),
                        "processIdentifier": .integer(Int64(candidate.processIdentifier)),
                        "executablePath": .string(candidate.executablePath),
                    ])
                }
                result = page.object(items: .array(items))
            }
            return result.mergingObject([
                "kind": .string(kind),
                "generatedAt": .string(candidateCache?.loadedAt.ISO8601Format() ?? Date().ISO8601Format()),
            ])
        case "appRouting.rules.replace":
            let rules: [CaptureRule] = try request.decode("rules")
            let expectedRevision = try request.int("expectedRevision")
            guard expectedRevision >= 0,
                  UInt64(expectedRevision) == model.networkCapturePreferences.snapshot.revision else {
                throw GatewayError.revisionConflict(
                    model.networkCapturePreferences.snapshot.revision
                )
            }
            try await model.applyNetworkCaptureRules(
                rules,
                enabled: request.bool(
                    "enabled",
                    default: model.networkCapturePreferences.enabled
                ),
                dnsEnabled: request.optionalBool("dnsEnabled")
            )
            return appRoutingStatus()
        case "appRouting.proxifier.preview":
            let input = try await proxifierInput(request)
            let existingRules = model.networkCapturePreferences.snapshot.rules
            let plan = try await Task.detached(priority: .userInitiated) {
                try AppLocalization.withLanguage(.english) {
                    try ProxifierRuleImporter().makePlan(
                        data: input.data,
                        sourceName: input.sourceName,
                        existingRules: existingRules
                    )
                }
            }.value
            return try proxifierPlan(plan, request: request)
        case "appRouting.proxifier.import":
            let expectedRevision = try request.int("expectedRevision")
            guard expectedRevision >= 0,
                  UInt64(expectedRevision)
                    == model.networkCapturePreferences.snapshot.revision else {
                throw GatewayError.revisionConflict(
                    model.networkCapturePreferences.snapshot.revision
                )
            }
            let selectedIDs: [Int] = try request.decode("selectedItemIDs")
            guard !selectedIDs.isEmpty, selectedIDs.count <= 10_000,
                  Set(selectedIDs).count == selectedIDs.count else {
                throw GatewayError.invalidParameters(
                    "selectedItemIDs must contain 1...10000 unique item IDs"
                )
            }
            let input = try await proxifierInput(request)
            let existingRules = model.networkCapturePreferences.snapshot.rules
            let plan = try await Task.detached(priority: .userInitiated) {
                try AppLocalization.withLanguage(.english) {
                    try ProxifierRuleImporter().makePlan(
                        data: input.data,
                        sourceName: input.sourceName,
                        existingRules: existingRules
                    )
                }
            }.value
            let byID = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.id, $0) })
            let selectedRules = try selectedIDs.map { id -> CaptureRule in
                guard let item = byID[id] else {
                    throw GatewayError.invalidParameters("Unknown Proxifier item ID: \(id)")
                }
                guard let rule = item.rule else {
                    throw GatewayError.invalidParameters(
                        "Proxifier item \(id) is not safely importable"
                    )
                }
                return rule
            }
            try await model.applyNetworkCaptureRules(
                existingRules + selectedRules,
                enabled: model.networkCapturePreferences.enabled
            )
            return .object([
                "importedCount": .integer(Int64(selectedRules.count)),
                "importedRuleIDs": .array(
                    selectedRules.map { .string($0.id) }
                ),
                "revision": .unsignedInteger(
                    model.networkCapturePreferences.snapshot.revision
                ),
            ])
        case "appRouting.activities.clear":
            try require(
                await model.clearAppRoutingActivity(),
                "App Routing activities could not be cleared"
            )
            return accepted()
        case "appRouting.activities.list":
            return try paged(
                model.appRoutingActivities,
                request: request,
                maximumLimit: 200
            ).mergingObject(["freshness": freshness(.appRouting)])
        case "traffic.snapshot":
            return trafficSnapshot()
        case "traffic.connections.list":
            return try paged(
                model.connections?.connections ?? [],
                request: request,
                maximumLimit: 100
            ).mergingObject(["freshness": freshness(.connections)])
        case "traffic.connections.close":
            try require(
                await model.closeConnection(try request.string("id")),
                "The connection could not be closed"
            )
            return accepted()
        case "traffic.connections.closeAll":
            try require(
                await model.closeAllConnections(),
                "Connections could not be closed"
            )
            return accepted()
        case "traffic.closed.clear":
            model.clearClosedConnectionHistory()
            return accepted()
        case "traffic.closed.list":
            let page = try pageBounds(
                count: model.recentlyClosedConnections.count,
                request: request,
                maximumLimit: 100
            )
            let items: [AutomationJSONValue] = model.recentlyClosedConnections[page.range].map { record in
                .object([
                    "closedAt": .string(record.closedAt.ISO8601Format()),
                    "connection": (try? encode(record.connection)) ?? .null,
                ])
            }
            return page.object(items: .array(items))
        case "traffic.history.setPersistent":
            let enabled = try request.requiredBool("enabled")
            await model.setPersistentTrafficHistoryEnabled(enabled)
            if enabled, case .unavailable = model.trafficHistoryRuntimeState {
                throw GatewayError.operationFailed(
                    "Persistent traffic history is unavailable",
                    true
                )
            }
            return trafficSnapshot()
        case "traffic.history.setRetention":
            let days = try request.int("days")
            guard let retention = TrafficHistoryRetention(rawValue: days) else {
                throw GatewayError.invalidParameters("days must be 7, 30, or 90")
            }
            await model.setTrafficHistoryRetention(retention)
            try require(
                model.trafficHistoryPersistenceChoice == .persistent
                    && model.trafficHistoryRetention == retention,
                "Traffic history retention was not applied"
            )
            return trafficSnapshot()
        case "traffic.history.clear":
            try require(
                await model.clearTrafficHistory(),
                "Traffic history could not be cleared"
            )
            return accepted()
        case "traffic.history.summary":
            guard let snapshot = try trafficHistorySnapshot(request) else {
                return .object(["available": .bool(false)])
            }
            return trafficHistorySummary(snapshot)
        case "traffic.history.applications.list":
            guard let snapshot = try trafficHistorySnapshot(request) else {
                return try emptyPage(request: request, maximumLimit: 200)
            }
            let page = try pageBounds(
                count: snapshot.applications.count,
                request: request,
                maximumLimit: 200
            )
            return page.object(items: .array(
                snapshot.applications[page.range].map(trafficHistoryApplication)
            ))
        case "traffic.history.routes.list":
            guard let snapshot = try trafficHistorySnapshot(request) else {
                return try emptyPage(request: request, maximumLimit: 200)
            }
            let page = try pageBounds(
                count: snapshot.routes.count,
                request: request,
                maximumLimit: 200
            )
            return page.object(items: .array(
                snapshot.routes[page.range].map(trafficHistoryRoute)
            ))
        case "traffic.ledger.applications.list":
            let values = model.flowLedger.applicationAggregates
            let page = try pageBounds(
                count: values.count,
                request: request,
                maximumLimit: 200
            )
            return page.object(items: .array(
                values[page.range].map(flowLedgerApplicationAggregate)
            )).mergingObject(["freshness": ledgerFreshness()])
        case "traffic.ledger.routes.list":
            let values = model.flowLedger.routeAggregates
            let page = try pageBounds(
                count: values.count,
                request: request,
                maximumLimit: 200
            )
            return page.object(items: .array(
                values[page.range].map(flowLedgerRouteAggregate)
            )).mergingObject(["freshness": ledgerFreshness()])
        case "traffic.ledger.history.list":
            let values = model.flowLedger.completedEntries
            let page = try pageBounds(
                count: values.count,
                request: request,
                maximumLimit: 100
            )
            return page.object(items: .array(
                values[page.range].map(flowLedgerEntry)
            )).mergingObject(["freshness": ledgerFreshness()])
        case "logs.list":
            let page = try pageBounds(
                count: model.logs.count,
                request: request,
                maximumLimit: 200
            )
            let items: [AutomationJSONValue] = model.logs[page.range].map { line in
                .object([
                    "id": .string(line.id.uuidString.lowercased()),
                    "timestamp": .string(line.timestamp.ISO8601Format()),
                    "source": .string(line.stream.rawValue),
                    "message": .string(redactedDiagnosticText(line.message)),
                ])
            }
            return page.object(items: .array(items)).mergingObject([
                "freshness": freshness(.logs),
            ])
        case "logs.clear":
            model.clearLogs()
            return accepted()
        case "diagnostics.snapshot":
            return diagnostics()
        case "diagnostics.report.get":
            return try diagnosticReport(request)
        default:
            throw GatewayError.methodNotFound(request.method)
        }
    }

    private func confirmDestructiveRequest(
        _ request: AutomationRPCRequest,
        summary: String,
        peer: AutomationPeerIdentity,
        client: AutomationAuthorizationStore.PublicClient?
    ) throws {
        guard request.allowInteraction else {
            throw GatewayError.confirmationRequired(request.method)
        }
        try beginInteractivePresentation()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppLocalization.string("Allow External MClash Operation?")
        let clientName = displaySafe(
            client?.name ?? AppLocalization.string("Unknown paired client")
        )
        let signingIdentity = [
            peer.signingIdentifier,
            peer.teamIdentifier,
        ].compactMap { $0 }.map { displaySafe($0) }.joined(separator: " / ")
        alert.informativeText = AppLocalization.format(
            "Client: %@\nProcess: %@ (PID %d)\nPath: %@\nSigning: %@\n\nRequested: %@\nMethod: %@\n%@\n\nApprove this operation once?",
            clientName,
            displaySafe(peer.displayName),
            peer.processIdentifier,
            displaySafe(peer.executablePath, maximumLength: 240),
            signingIdentity.isEmpty ? AppLocalization.string("Ad hoc signed") : signingIdentity,
            displaySafe(AppLocalization.string(summary)),
            displaySafe(request.method),
            requestSummary(request)
        )
        alert.addButton(withTitle: AppLocalization.string("Approve Once"))
        alert.addButton(withTitle: AppLocalization.string("Deny"))
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            throw GatewayError.permissionDenied(request.method)
        }
    }

    private func beginInteractivePresentation() throws {
        if let lastInteractionPromptAt,
           Date().timeIntervalSince(lastInteractionPromptAt) < 5 {
            throw GatewayError.interactionRateLimited
        }
        lastInteractionPromptAt = Date()
    }

    private func pair(
        request: AutomationRPCRequest,
        peer: AutomationPeerIdentity,
        mayCommit: @Sendable () -> Bool
    ) throws -> AutomationJSONValue {
        guard peer.teamIdentifier != nil || peer.codeHash != nil else {
            throw GatewayError.untrustedClient
        }
        guard request.allowInteraction else {
            throw GatewayError.confirmationRequired("auth.pair")
        }
        let rawScopes = try request.stringArray("scopes")
        let requestedScopes = Set(try rawScopes.map { value -> AutomationClientScope in
            guard let scope = AutomationClientScope(rawValue: value) else {
                throw GatewayError.invalidParameters("Unknown scope: \(value)")
            }
            return scope
        })
        let name = displaySafe(try request.string("name"), maximumLength: 80)
        let scopes = authorizationStore.scopesForPairing(
            name: name,
            requestedScopes: requestedScopes,
            peer: peer
        )
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppLocalization.string("Pair External Client with MClash?")
        let signatureDescription: String
        if let teamIdentifier = peer.teamIdentifier, !teamIdentifier.isEmpty {
            signatureDescription = AppLocalization.format(
                "Signing ID: %@\nTeam ID: %@",
                displaySafe(peer.signingIdentifier ?? AppLocalization.string("Unknown")),
                displaySafe(teamIdentifier)
            )
        } else {
            let fingerprint = peer.codeHash.map { String($0.prefix(16)) } ?? AppLocalization.string("None")
            signatureDescription = AppLocalization.format(
                "Signing: Ad hoc signed\nIdentifier: %@\nCode fingerprint: %@",
                displaySafe(peer.signingIdentifier ?? AppLocalization.string("None")),
                fingerprint
            )
        }
        let brokerWarning = peer.displayName == "mclashctl"
            ? AppLocalization.string("\n\nThe bundled mclashctl is a user-level broker. Granting it access allows processes running under this macOS login to invoke these scopes through it.")
            : ""
        alert.informativeText = AppLocalization.format(
            "Client: %@\nProcess: %@ (PID %d)\nPath: %@\n%@\nNeeded scopes: %@\n\nAllow Needed Access grants only these scopes and keeps one-time confirmation for destructive operations. Trust This Client grants every scope and allows unattended destructive operations for 180 days, or until revoked.%@",
            name,
            displaySafe(peer.displayName),
            peer.processIdentifier,
            displaySafe(peer.executablePath, maximumLength: 240),
            signatureDescription,
            scopes.map(\.rawValue).sorted().joined(separator: ", "),
            brokerWarning
        )
        alert.addButton(withTitle: AppLocalization.string("Allow Needed Access"))
        alert.addButton(withTitle: AppLocalization.string("Trust This Client"))
        alert.addButton(withTitle: AppLocalization.string("Deny"))
        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        lastPairingPromptAt = Date()
        let trust: AutomationClientTrust
        switch response {
        case .alertFirstButtonReturn:
            trust = .standard
        case .alertSecondButtonReturn:
            trust = .trusted
        default:
            throw GatewayError.permissionDenied("auth.pair")
        }
        guard mayCommit() else { throw CancellationError() }
        let issued = try authorizationStore.issue(
            name: name,
            scopes: scopes,
            trust: trust,
            peer: peer
        )
        return .object([
            "client": try encode(issued.client),
            "token": .string(issued.token),
        ])
    }

    private static func requiredScope(
        for capability: AutomationCapability
    ) -> AutomationClientScope {
        if capability.risk == .destructive { return .destructive }
        if capability.risk == .write { return .control }
        if Self.sensitiveReadMethods.contains(capability.method) {
            return .readSensitive
        }
        return .readBasic
    }

    private func requestSummary(_ request: AutomationRPCRequest) -> String {
        switch request.method {
        case "configuration.apply":
            let document = request.params["document"]?.objectValue ?? [:]
            let counts = [
                "nodeSettings", "proxyGroups", "rules", "ruleSets",
                "dnsPolicies", "entrances", "workspaces",
            ].map { key in
                "\(key)=\(document[key]?.arrayValue?.count ?? 0)"
            }.joined(separator: ", ")
            let revision = request.params["expectedRevision"]?.stringValue
                ?? AppLocalization.string("Missing")
            return AppLocalization.format(
                "Expected revision: %@\nObjects: %@",
                displaySafe(revision),
                counts
            )
        case "configuration.delete":
            return AppLocalization.format(
                "Configuration object: %@\nID: %@\nExpected revision: %@",
                displaySafe(request.params["kind"]?.stringValue ?? AppLocalization.string("Missing")),
                displaySafe(request.params["id"]?.stringValue ?? AppLocalization.string("Missing")),
                displaySafe(request.params["expectedRevision"]?.stringValue ?? AppLocalization.string("Missing"))
            )
        case "configuration.workspace.activate":
            return AppLocalization.format(
                "Workspace ID: %@\nExpected revision: %@",
                displaySafe(request.params["id"]?.stringValue ?? AppLocalization.string("Missing")),
                displaySafe(request.params["expectedRevision"]?.stringValue ?? AppLocalization.string("Missing"))
            )
        case "appRouting.rules.replace":
            let ruleCount = request.params["rules"]?.arrayValue?.count ?? 0
            let revision = request.params["expectedRevision"]?.intValue.map(String.init)
                ?? AppLocalization.string("Missing")
            let enabled = request.params["enabled"]?.boolValue.map {
                AppLocalization.string($0 ? "On" : "Off")
            }
                ?? AppLocalization.string("Unchanged")
            let dnsEnabled = request.params["dnsEnabled"]?.boolValue.map {
                AppLocalization.string($0 ? "On" : "Off")
            }
                ?? AppLocalization.string("Unchanged")
            return AppLocalization.format(
                "Rules: %d\nExpected revision: %@\nApp Routing enabled: %@\nDNS enabled: %@",
                ruleCount,
                revision,
                enabled,
                dnsEnabled
            )
        case "profiles.remove":
            let id = request.params["id"]?.stringValue
                ?? AppLocalization.string("Missing")
            let name = UUID(uuidString: id).flatMap { uuid in
                model.profiles.first { $0.id.rawValue == uuid }?.name
            } ?? AppLocalization.string("Unknown")
            return AppLocalization.format(
                "Profile: %@\nID: %@",
                displaySafe(name),
                displaySafe(id)
            )
        case "auth.clients.revoke":
            let id = request.params["id"]?.stringValue
                ?? AppLocalization.string("Missing")
            let name = UUID(uuidString: id).flatMap { uuid in
                authorizationStore.list().first { $0.id == uuid }?.name
            } ?? AppLocalization.string("Unknown")
            return AppLocalization.format(
                "Client: %@\nID: %@",
                displaySafe(name),
                displaySafe(id)
            )
        case "appRouting.proxifier.import":
            let sourceName = request.params["sourceName"]?.stringValue
                ?? "Automation.ppx"
            let selectedCount = request.params["selectedItemIDs"]?.arrayValue?.count ?? 0
            let revision = request.params["expectedRevision"]?.intValue.map(String.init)
                ?? AppLocalization.string("Missing")
            return AppLocalization.format(
                "Source: %@\nSelected rules: %d\nExpected revision: %@",
                displaySafe(sourceName),
                selectedCount,
                revision
            )
        default:
            break
        }
        let visibleKeys = ["id", "name", "enabled", "mode", "group", "proxy", "days", "destination"]
        let details = visibleKeys.compactMap { key -> String? in
            guard let value = request.params[key] else { return nil }
            switch value {
            case let .string(value): return "\(key): \(displaySafe(value, maximumLength: 120))"
            case let .bool(value): return "\(key): \(value)"
            case let .integer(value): return "\(key): \(value)"
            case let .unsignedInteger(value): return "\(key): \(value)"
            case let .number(value): return "\(key): \(value)"
            case .object, .array, .null: return nil
            }
        }
        return details.isEmpty
            ? AppLocalization.string("Parameters: no display-safe summary")
            : details.joined(separator: "\n")
    }

    private func displaySafe(
        _ value: String,
        maximumLength: Int = 160
    ) -> String {
        let printable = value.unicodeScalars.map { scalar -> String in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        let normalized = printable.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(normalized.prefix(maximumLength))
    }

    private func mutationCacheKey(
        request: AutomationRPCRequest,
        clientIdentifier: UUID?
    ) -> String {
        let source = "\(clientIdentifier?.uuidString ?? "unpaired")|\(request.id)"
        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func mutationRequestDigest(_ request: AutomationRPCRequest) -> String {
        let signature = AutomationJSONValue.object([
            "method": .string(request.method),
            "params": .object(request.params),
            "allowInteraction": .bool(request.allowInteraction),
        ])
        let data = (try? JSONEncoder.automation.encode(signature)) ?? Data()
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func cacheMutation(
        _ response: AutomationRPCResponse,
        context: MutationCacheContext?
    ) {
        guard let context else { return }
        guard response.error?.type != "operation_in_progress" else { return }
        removeCachedMutation(context.key)
        let responseBytes = (try? JSONEncoder.automation.encode(response).count) ?? 0
        let entry = CachedMutation(
            clientIdentifier: context.clientIdentifier,
            requestDigest: context.requestDigest,
            response: response,
            byteCount: responseBytes + context.requestDigest.utf8.count
        )
        cachedMutations[context.key] = entry
        var byteCount = cachedMutationBytesByClient[context.clientIdentifier] ?? 0
        byteCount += entry.byteCount
        var order = cachedMutationOrderByClient[context.clientIdentifier] ?? []
        order.append(context.key)
        cachedMutationGlobalOrder.append(context.key)
        cachedMutationGlobalBytes += entry.byteCount
        cachedMutationOrderByClient[context.clientIdentifier] = order
        cachedMutationBytesByClient[context.clientIdentifier] = byteCount
        while order.count > 256 || byteCount > 4 * 1_024 * 1_024 {
            let oldestKey = order.removeFirst()
            removeCachedMutation(oldestKey)
            order = cachedMutationOrderByClient[context.clientIdentifier] ?? []
            byteCount = cachedMutationBytesByClient[context.clientIdentifier] ?? 0
        }
        while cachedMutationGlobalOrder.count > 1_024
            || cachedMutationGlobalBytes > 16 * 1_024 * 1_024
        {
            guard let oldestKey = cachedMutationGlobalOrder.first else { break }
            removeCachedMutation(oldestKey)
        }
    }

    private func removeCachedMutations(clientIdentifier: UUID) {
        for key in cachedMutationOrderByClient[clientIdentifier] ?? [] {
            removeCachedMutation(key)
        }
    }

    private func removeCachedMutation(_ key: String) {
        guard let removed = cachedMutations.removeValue(forKey: key) else {
            cachedMutationGlobalOrder.removeAll { $0 == key }
            return
        }
        cachedMutationGlobalBytes = max(0, cachedMutationGlobalBytes - removed.byteCount)
        cachedMutationGlobalOrder.removeAll { $0 == key }
        var order = cachedMutationOrderByClient[removed.clientIdentifier] ?? []
        order.removeAll { $0 == key }
        let bytes = max(
            0,
            (cachedMutationBytesByClient[removed.clientIdentifier] ?? 0)
                - removed.byteCount
        )
        if order.isEmpty {
            cachedMutationOrderByClient.removeValue(forKey: removed.clientIdentifier)
            cachedMutationBytesByClient.removeValue(forKey: removed.clientIdentifier)
        } else {
            cachedMutationOrderByClient[removed.clientIdentifier] = order
            cachedMutationBytesByClient[removed.clientIdentifier] = bytes
        }
    }

    private func accepted() -> AutomationJSONValue {
        .object(["accepted": .bool(true), "completedAt": .string(Date().ISO8601Format())])
    }

    private func require(
        _ condition: Bool,
        _ fallbackMessage: String
    ) throws {
        guard condition else {
            throw GatewayError.operationFailed(fallbackMessage, true)
        }
    }

    private func requireProviderReceipt(
        _ kind: AppModel.ProviderOperationKind,
        name: String,
        startedAt: Date
    ) throws {
        guard let receipt = model.providerOperationReceipt(kind, providerName: name),
              receipt.completedAt >= startedAt else {
            throw GatewayError.operationFailed("The provider operation did not run", true)
        }
        if case .failed = receipt.outcome {
            throw GatewayError.operationFailed("The provider operation failed", true)
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> AutomationJSONValue {
        let data = try JSONEncoder.automation.encode(value)
        return try JSONDecoder.automation.decode(AutomationJSONValue.self, from: data)
    }

    private func configurationMutationReceipt(
        plan: ConfigurationAutomationPlan,
        currentSessionChanged: Bool
    ) throws -> AutomationJSONValue {
        .object([
            "configurationRevision": .string(
                model.configurationRevision.uuidString.lowercased()
            ),
            "changed": .bool(plan.changed),
            "valid": .bool(plan.valid),
            "diagnostics": try encode(plan.diagnostics),
            "diagnosticCount": .integer(Int64(plan.diagnosticCount)),
            "compilations": try encode(plan.compilations),
            "currentSessionChanged": .bool(currentSessionChanged),
        ])
    }

    private func paged<T: Encodable>(
        _ values: [T],
        request: AutomationRPCRequest,
        maximumLimit: Int
    ) throws -> AutomationJSONValue {
        let page = try pageBounds(
            count: values.count,
            request: request,
            maximumLimit: maximumLimit
        )
        return page.object(items: try encode(Array(values[page.range])))
    }

    private func pageBounds(
        count: Int,
        request: AutomationRPCRequest,
        maximumLimit: Int,
        offsetParameter: String = "offset",
        limitParameter: String = "limit",
        defaultLimit: Int? = nil
    ) throws -> AutomationPage {
        let offset = try request.int(offsetParameter, default: 0)
        let limit = try request.int(limitParameter, default: defaultLimit ?? maximumLimit)
        guard offset >= 0 else {
            throw GatewayError.invalidParameters("\(offsetParameter) must be at least 0")
        }
        guard (1...maximumLimit).contains(limit) else {
            throw GatewayError.invalidParameters(
                "\(limitParameter) must be between 1 and \(maximumLimit)"
            )
        }
        let lower = min(offset, count)
        let upper = min(lower + limit, count)
        return AutomationPage(offset: lower, limit: limit, total: count, range: lower..<upper)
    }

    private func freshness(_ stream: AppModel.LiveStream) -> AutomationJSONValue {
        let health = model.liveStreamHealth[stream] ?? .inactive
        let phase: String = switch health.phase {
        case .inactive: "inactive"
        case .connecting: "connecting"
        case .live: "live"
        case .reconnecting: "reconnecting"
        case .stale: "stale"
        }
        return .object([
            "current": .bool(health.hasCurrentData),
            "phase": .string(phase),
            "lastReceivedAt": health.lastReceivedAt.map {
                .string($0.ISO8601Format())
            } ?? .null,
        ])
    }

    private func snapshot() -> AutomationJSONValue {
        return .object([
            "schemaVersion": .integer(1),
            "generatedAt": .string(Date().ISO8601Format()),
            "app": .object([
                "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"),
                "windowVisible": .bool(model.mainWindowIsVisible),
                "destination": model.selection.map { .string($0.rawValue) } ?? .null,
            ]),
            "core": coreStatus(),
            "configuration": configurationStatus(),
            "routing": routingStatus(),
            "systemProxy": systemProxyStatus(),
            "appRouting": appRoutingStatus(),
            "traffic": trafficSnapshot(),
            "diagnostics": diagnostics(),
        ])
    }

    private func configurationStatus() -> AutomationJSONValue {
        let workspace = model.configurationDocument.currentWorkspace
        return .object([
            "unified": .bool(model.unifiedConfigurationEnabled),
            "workspaceID": workspace.map { .string($0.id.rawValue.uuidString.lowercased()) } ?? .null,
            "workspaceName": workspace.map { .string($0.name) } ?? .null,
            "routingMode": workspace.map { .string($0.routingMode.rawValue) } ?? .null,
            "sourcePolicy": .string("nodes-only"),
            "nodeCount": .integer(Int64(model.configurationDocument.nodes.count)),
            "groupCount": .integer(Int64(model.configurationDocument.proxyGroups.count)),
            "ruleCount": .integer(Int64(model.configurationDocument.rules.count)),
            "ruleSetCount": .integer(Int64(model.configurationDocument.ruleSets.count)),
            "entranceCount": .integer(Int64(model.activeConfiguredEntrances.count)),
            "runtimeHash": model.compiledConfiguration.map { .string($0.configHash) } ?? .null,
        ])
    }

    private func coreStatus() -> AutomationJSONValue {
        let state: String
        var version: AutomationJSONValue = .null
        var startedAt: AutomationJSONValue = .null
        switch model.coreState {
        case .stopped: state = "stopped"
        case .validating: state = "validating"
        case .starting: state = "starting"
        case let .running(session):
            state = "running"
            version = .string(session.version)
            startedAt = .string(session.startedAt.ISO8601Format())
        case .stopping: state = "stopping"
        case .failed: state = "failed"
        }
        let controller: String = switch model.controllerState {
        case .idle: "idle"
        case .loading: "loading"
        case .ready: "ready"
        case .degraded: "degraded"
        }
        var listeners: [AutomationJSONValue]
        if model.unifiedConfigurationEnabled {
            listeners = []
            listeners.append(contentsOf: model.activeConfiguredEntrances.map { entrance in
                .object([
                    "id": .string(entrance.id.rawValue.uuidString.lowercased()),
                    "name": .string(entrance.name),
                    "kind": .string(entrance.kind.rawValue),
                    "address": entrance.address.map(AutomationJSONValue.string) ?? .null,
                    "enabled": .bool(entrance.enabled),
                    "workspaceID": model.configurationDocument.currentWorkspace.map {
                        AutomationJSONValue.string($0.id.rawValue.uuidString.lowercased())
                    } ?? .null,
                    "routingMode": model.configurationDocument.currentWorkspace.map {
                        AutomationJSONValue.string($0.routingMode.rawValue)
                    } ?? .null,
                    "source": .string("MClash configuration"),
                    "managed": .bool(true),
                ])
            })
        } else {
            listeners = model.localListenerEndpoints.map { endpoint in
                AutomationJSONValue.object([
                    "name": .string(AppLocalization.string("MClash local fallback")),
                    "kind": .string(endpoint.kind.rawValue),
                    "address": .string(endpoint.address),
                    "managed": .bool(true),
                ])
            }
        }
        // Route listeners belong to the legacy per-profile fleet. In unified
        // mode the workspace entrances above are authoritative; reporting the
        // retained legacy plan here would make internal recovery ports look
        // like extra user entrances.
        if !model.unifiedConfigurationEnabled {
            listeners.append(contentsOf: model.profileRuntimePlan.routeListeners.map { listener in
                .object([
                    "id": .string(listener.id.uuidString.lowercased()),
                    "name": .string(listener.name),
                    "kind": .string(listener.protocolType.rawValue),
                    "address": .string("127.0.0.1:\(listener.port)"),
                    "profileID": .string(listener.profileID.description),
                    "enabled": .bool(listener.enabled),
                    "target": profileRouteListenerTargetJSON(listener.target),
                    "managed": .bool(true),
                ])
            })
        }
        return .object([
            "state": .string(state),
            "connected": .bool(model.isConnected),
            "controller": .string(controller),
            "version": version,
            "startedAt": startedAt,
            "activeProfileID": model.activeProfileID.map { .string($0.description) } ?? .null,
            "listeners": .array(listeners),
        ])
    }

    private func profileRouteListenerTargetJSON(
        _ target: ProfileRouteListenerTarget
    ) -> AutomationJSONValue {
        switch target {
        case .profileRules:
            .object(["kind": .string("profileRules")])
        case let .subRule(name):
            .object(["kind": .string("subRule"), "name": .string(name)])
        case .global:
            .object(["kind": .string("global"), "name": .string("GLOBAL")])
        case let .policyGroup(name):
            .object(["kind": .string("policyGroup"), "name": .string(name)])
        case let .proxyNode(name):
            .object(["kind": .string("proxyNode"), "name": .string(name)])
        }
    }

    private func profiles(request: AutomationRPCRequest) throws -> AutomationJSONValue {
        let page = try pageBounds(
            count: model.profiles.count,
            request: request,
            maximumLimit: 100
        )
        return page.object(items: .array(model.profiles[page.range].map(profileJSON)))
    }

    private func profileJSON(_ profile: ProfileMetadata) -> AutomationJSONValue {
        let origin: AutomationJSONValue
        switch profile.origin {
        case .local:
            origin = .object(["kind": .string("local")])
        case let .imported(fileName):
            origin = .object([
                "kind": .string("imported"),
                "originalFileName": .string(fileName),
            ])
        case let .remote(metadata):
            origin = .object([
                "kind": .string("remote"),
                "host": .string(metadata.url.host ?? ""),
                "automaticUpdatesEnabled": .bool(metadata.automaticUpdatesEnabled),
                "updateIntervalHours": metadata.updateIntervalHours.map {
                    .integer(Int64($0))
                } ?? .null,
                "lastCheckedAt": metadata.lastCheckedAt.map {
                    .string($0.ISO8601Format())
                } ?? .null,
                "lastSuccessfulUpdateAt": metadata.lastSuccessfulUpdateAt.map {
                    .string($0.ISO8601Format())
                } ?? .null,
            ])
        }
        return .object([
            "id": .string(profile.id.description),
            "name": .string(profile.name),
            "origin": origin,
            "active": .bool(profile.id == model.activeProfileID),
            "createdAt": .string(profile.createdAt.ISO8601Format()),
            "updatedAt": .string(profile.updatedAt.ISO8601Format()),
        ])
    }

    /// Mutation receipts deliberately contain IDs only. Profile names, source
    /// filenames, and subscription hosts remain behind `read.sensitive`.
    private func profileCreationReceipt(
        previousIDs: Set<ProfileID>
    ) -> AutomationJSONValue {
        let createdIDs = model.profiles.lazy
            .map(\.id)
            .filter { !previousIDs.contains($0) }
        return .object([
            "accepted": .bool(true),
            "createdIDs": .array(Array(createdIDs.map { .string($0.description) })),
        ])
    }

    private func applicationCaptureCandidates() async -> ApplicationCaptureCandidates {
        if let candidateCache,
           Date().timeIntervalSince(candidateCache.loadedAt) < 2 {
            return candidateCache.value
        }
        let value = await ApplicationCaptureCandidateProvider().loadRunningCandidates()
        candidateCache = CandidateCache(loadedAt: Date(), value: value)
        return value
    }

    private func routingStatus() -> AutomationJSONValue {
        var selections: [String: AutomationJSONValue] = [:]
        for group in model.proxyGroups {
            if let selected = group.now {
                selections[group.name] = AutomationJSONValue.string(selected)
            }
        }
        let mode: AutomationJSONValue
        if let value = model.runtimeConfig?.mode {
            mode = .string(value)
        } else {
            mode = .null
        }
        let lastLoadedAt: AutomationJSONValue
        if let date = model.liveStreamHealth[.proxies]?.lastReceivedAt {
            lastLoadedAt = .string(date.ISO8601Format())
        } else {
            lastLoadedAt = .null
        }
        return .object([
            "mode": mode,
            "groupCount": .integer(Int64(model.proxyGroups.count)),
            "selections": .object(selections),
            "lastLoadedAt": lastLoadedAt,
        ])
    }

    private func systemProxyStatus() -> AutomationJSONValue {
        let state: String = switch model.systemProxyState {
        case .off: "off"
        case .enabling: "enabling"
        case .on: "on"
        case .disabling: "disabling"
        case .failed: "failed"
        }
        return .object([
            "state": .string(state),
            "enabled": .bool(model.systemProxyEnabled),
            "observedEnabled": .bool(model.systemProxyObservedEnabled),
            "observedMatchesMClash": .bool(model.systemProxyObservedMatchesMClash),
            "observedAt": model.systemProxyObservedAt.map {
                .string($0.ISO8601Format())
            } ?? .null,
            "recoveryRequired": .bool(model.systemProxyRecoveryRequired),
            "guardEnabled": .bool(model.systemProxyPreferences.guardEnabled),
            "guardHealthy": .bool(model.systemProxyGuardFailure == nil),
        ])
    }

    private func appRoutingStatus() -> AutomationJSONValue {
        let state: String = switch model.networkCaptureState {
        case .off: "off"
        case .waitingForConnection: "waitingForConnection"
        case .enabling: "enabling"
        case .awaitingUserApproval: "awaitingUserApproval"
        case .on: "on"
        case .disabling: "disabling"
        case .requiresReboot: "requiresReboot"
        case .failed: "failed"
        }
        return .object([
            "state": .string(state),
            "enabled": .bool(model.networkCapturePreferences.enabled),
            "dnsEnabled": .bool(model.networkCapturePreferences.dnsEnabled),
            "revision": .unsignedInteger(model.networkCapturePreferences.snapshot.revision),
            "ruleCount": .integer(Int64(model.networkCapturePreferences.snapshot.rules.count)),
            "activitiesAvailableWhileWindowHidden": .bool(!model.lightweightMode),
            "activityFreshness": freshness(.appRouting),
        ])
    }

    private func trafficSnapshot() -> AutomationJSONValue {
        .object([
            "uploadBytesPerSecond": .integer(model.traffic.upload),
            "downloadBytesPerSecond": .integer(model.traffic.download),
            "uploadTotal": .integer(model.traffic.uploadTotal),
            "downloadTotal": .integer(model.traffic.downloadTotal),
            "connectionCount": .integer(Int64(model.connections?.connections.count ?? 0)),
            "memoryBytes": model.connections?.memory.map {
                .unsignedInteger($0)
            } ?? .null,
            "freshness": freshness(.traffic),
            "historyPersistent": .bool(model.trafficHistoryPersistenceChoice == .persistent),
            "historyRetentionDays": .integer(Int64(model.trafficHistoryRetention.rawValue)),
        ])
    }

    private func settings() -> AutomationJSONValue {
        .object([
            "launchAtLogin": .bool(model.launchAtLogin),
            "notificationsEnabled": .bool(model.notificationsEnabled),
            "autoConnectOnLaunch": .bool(model.autoConnectOnLaunch),
            "autoEnableSystemProxy": .bool(model.autoEnableSystemProxy),
            "lightweightMode": .bool(model.lightweightMode),
            "menuBarDisplayStyle": .string(model.menuBarDisplayStyle.rawValue),
            "closeConnectionsOnRoutingChange": .bool(model.closeConnectionsOnRoutingChange),
        ])
    }

    private func updaterStatus() -> AutomationJSONValue {
        .object([
            "canCheckForUpdates": .bool(updater.canCheckForUpdates),
            "automaticChecks": .bool(updater.automaticallyChecksForUpdates),
            "automaticDownloads": .bool(updater.automaticallyDownloadsUpdates),
            "allowsAutomaticUpdates": .bool(updater.allowsAutomaticUpdates),
        ])
    }

    private func diagnostics() -> AutomationJSONValue {
        return .object([
            "issues": .array(model.operationalIssues.map { issue in
                let severity: String = switch issue.severity {
                case .information: "information"
                case .warning: "warning"
                case .error: "error"
                }
                return .object([
                    "id": .string(issue.id),
                    "severity": .string(severity),
                    "subsystem": .string(issue.subsystem.rawValue),
                    "title": .string(issue.title),
                    "consequence": .string(issue.consequence),
                    "technicalDetail": issue.technicalDetail.map {
                        .string(redactedDiagnosticText($0))
                    } ?? .null,
                ])
            }),
            "lastError": model.errorMessage.map {
                .string(redactedDiagnosticText($0))
            } ?? .null,
            "telemetryPolicy": .object([
                "traffic": .bool(model.presentationTelemetryPolicy.traffic),
                "connections": .bool(model.presentationTelemetryPolicy.connections),
                "logs": .bool(model.presentationTelemetryPolicy.logs),
                "proxies": .bool(model.presentationTelemetryPolicy.proxies),
                "appRouting": .bool(model.presentationTelemetryPolicy.appRoutingActivity),
            ]),
        ])
    }

    private func providers(
        request: AutomationRPCRequest
    ) throws -> AutomationJSONValue {
        var items = model.proxyProviders.map { provider in
            AutomationJSONValue.object([
                "kind": .string("proxy"),
                "name": .string(provider.name),
                "type": .string(provider.type),
                "vehicleType": .string(provider.vehicleType),
                "proxyCount": .integer(Int64(provider.proxies.count)),
                "testURL": .string(redactedURLString(provider.testURL)),
                "expectedStatus": .string(provider.expectedStatus),
                "updatedAt": provider.updatedAt.map(AutomationJSONValue.string) ?? .null,
                "subscriptionInfo": (try? encode(provider.subscriptionInfo)) ?? .null,
            ])
        }
        items.append(contentsOf: model.ruleProviders.map { provider in
            .object([
                "kind": .string("rule"),
                "name": .string(provider.name),
                "type": .string(provider.type),
                "vehicleType": .string(provider.vehicleType),
                "behavior": .string(provider.behavior),
                "format": .string(provider.format),
                "ruleCount": .integer(Int64(provider.ruleCount)),
                "updatedAt": .string(provider.updatedAt),
            ])
        })
        items.sort { lhs, rhs in
            let left = lhs.objectValue?["name"]?.stringValue ?? ""
            let right = rhs.objectValue?["name"]?.stringValue ?? ""
            return left.localizedStandardCompare(right) == .orderedAscending
        }
        let page = try pageBounds(
            count: items.count,
            request: request,
            maximumLimit: 50
        )
        return page.object(items: .array(Array(items[page.range]))).mergingObject([
            "lastLoadedAt": model.providersLastLoadedAt.map {
                .string($0.ISO8601Format())
            } ?? .null,
        ])
    }

    private func proxifierInput(
        _ request: AutomationRPCRequest
    ) async throws -> (data: Data, sourceName: String) {
        let inline = try request.string("dataBase64")
        guard let data = Data(base64Encoded: inline), !data.isEmpty else {
            throw GatewayError.invalidParameters("dataBase64 is not valid base64")
        }
        return (
            data,
            request.optionalString("sourceName") ?? "Automation.ppx"
        )
    }

    private func proxifierPlan(
        _ plan: ProxifierRuleImportPlan,
        request: AutomationRPCRequest
    ) throws -> AutomationJSONValue {
        let page = try pageBounds(
            count: plan.items.count,
            request: request,
            maximumLimit: 50
        )
        let items = try plan.items[page.range].map { item in
            AutomationJSONValue.object([
                "id": .integer(Int64(item.id)),
                "originalName": .string(item.originalName),
                "importedName": .string(item.importedName),
                "originalAction": .string(item.originalAction),
                "criteriaSummary": .string(item.criteriaSummary),
                "notes": .array(item.notes.map(AutomationJSONValue.string)),
                "selectedByDefault": .bool(item.selectedByDefault),
                "isCatchAll": .bool(item.isCatchAll),
                "importable": .bool(item.isImportable),
                "convertedRule": try item.rule.map(encode) ?? .null,
            ])
        }
        return page.object(items: .array(items)).mergingObject([
            "sourceName": .string(plan.sourceName),
            "profileVersion": .string(plan.profileVersion),
            "platform": .string(plan.platform),
            "importableCount": .integer(Int64(plan.importableCount)),
            "skippedCount": .integer(Int64(plan.skippedCount)),
            "notes": .array(plan.notes.map(AutomationJSONValue.string)),
            "expectedRevision": .unsignedInteger(
                model.networkCapturePreferences.snapshot.revision
            ),
        ])
    }

    private func routingGroups(
        request: AutomationRPCRequest
    ) throws -> AutomationJSONValue {
        let page = try pageBounds(
            count: model.proxyGroups.count,
            request: request,
            maximumLimit: 200
        )
        let items: [AutomationJSONValue] = model.proxyGroups[page.range]
            .map(routingGroup)
        return page.object(items: .array(items)).mergingObject([
            "freshness": freshness(.proxies),
        ])
    }

    private func routingGroup(_ group: MihomoProxy) -> AutomationJSONValue {
        let lastDelay: AutomationJSONValue = group.history.last.map {
            .integer(Int64($0.delay))
        } ?? .null
        let testURL: AutomationJSONValue = group.testURL.map(redactedURLString)
            .map(AutomationJSONValue.string) ?? .null
        let iconURL: AutomationJSONValue = group.icon.map(redactedURLString)
            .map(AutomationJSONValue.string) ?? .null
        return .object([
            "name": .string(group.name),
            "type": .string(group.type),
            "alive": .bool(group.alive),
            "choicesPreview": .array(
                group.all.prefix(20).map(AutomationJSONValue.string)
            ),
            "choiceCount": .integer(Int64(group.all.count)),
            "choicesTruncated": .bool(group.all.count > 20),
            "selected": group.now.map(AutomationJSONValue.string) ?? .null,
            "fixed": group.fixed.map(AutomationJSONValue.string) ?? .null,
            "hidden": .bool(group.hidden),
            "supportsManualSelection": .bool(
                group.groupBehavior?.supportsSelectionUpdate == true
            ),
            "supportsClearingOverride": .bool(
                group.groupBehavior?.supportsClearingOverride == true
            ),
            "lastDelayMilliseconds": lastDelay,
            "testURL": testURL,
            "iconURL": iconURL,
        ])
    }

    private func trafficHistorySnapshot(
        _ request: AutomationRPCRequest
    ) throws -> TrafficHistorySnapshot? {
        switch try request.string("period") {
        case "today": return model.trafficHistoryTodaySnapshot
        case "week": return model.trafficHistoryWeekSnapshot
        default:
            throw GatewayError.invalidParameters("period must be today or week")
        }
    }

    private func trafficHistorySummary(
        _ snapshot: TrafficHistorySnapshot
    ) -> AutomationJSONValue {
        let period = switch snapshot.period {
        case .today: "today"
        case .week: "week"
        }
        return .object([
            "available": .bool(true),
            "period": .string(period),
            "intervalStart": .string(snapshot.interval.start.ISO8601Format()),
            "intervalEnd": .string(snapshot.interval.end.ISO8601Format()),
            "baselineGeneration": .integer(snapshot.baseline.generation),
            "baselineStartedAt": .string(snapshot.baseline.startedAt.ISO8601Format()),
            "totals": trafficHistoryTotals(snapshot.totals),
            "applicationCount": .integer(Int64(snapshot.applications.count)),
            "routeCount": .integer(Int64(snapshot.routes.count)),
        ])
    }

    private func trafficHistoryTotals(
        _ totals: TrafficHistoryTotals
    ) -> AutomationJSONValue {
        .object([
            "completedFlowCount": .unsignedInteger(totals.completedFlowCount),
            "exactUploadBytes": .unsignedInteger(totals.exactUploadBytes),
            "exactDownloadBytes": .unsignedInteger(totals.exactDownloadBytes),
            "exactTotalBytes": .unsignedInteger(totals.exactTotalBytes),
            "coverage": .object([
                "exactDirectionCount": .unsignedInteger(
                    totals.coverage.exactDirectionCount
                ),
                "notMeasuredDirectionCount": .unsignedInteger(
                    totals.coverage.notMeasuredDirectionCount
                ),
                "notApplicableDirectionCount": .unsignedInteger(
                    totals.coverage.notApplicableDirectionCount
                ),
                "measuredFraction": totals.coverage.measuredFraction.map {
                    .number($0)
                } ?? .null,
            ]),
        ])
    }

    private func trafficHistoryApplication(
        _ snapshot: TrafficHistoryApplicationSnapshot
    ) -> AutomationJSONValue {
        let identity: AutomationJSONValue
        switch snapshot.application.identity {
        case let .bundleIdentifier(value):
            identity = .object(["kind": .string("bundleIdentifier"), "value": .string(value)])
        case let .signingIdentifier(value):
            identity = .object(["kind": .string("signingIdentifier"), "value": .string(value)])
        case .unattributed:
            identity = .object(["kind": .string("unattributed"), "value": .null])
        }
        return .object([
            "identity": identity,
            "displayName": .string(snapshot.application.displayName),
            "totals": trafficHistoryTotals(snapshot.totals),
        ])
    }

    private func trafficHistoryRoute(
        _ snapshot: TrafficHistoryRouteSnapshot
    ) -> AutomationJSONValue {
        .object([
            "kind": .string(snapshot.route.kind.rawValue),
            "displayName": .string(snapshot.route.displayName),
            "ruleName": snapshot.route.ruleName.map(AutomationJSONValue.string) ?? .null,
            "proxyChain": .array(
                snapshot.route.proxyChain.map(AutomationJSONValue.string)
            ),
            "totals": trafficHistoryTotals(snapshot.totals),
        ])
    }

    private func flowLedgerTraffic(
        _ traffic: FlowLedgerTrafficAggregate
    ) -> AutomationJSONValue {
        .object([
            "exactUploadBytes": .unsignedInteger(traffic.exactUploadBytes),
            "exactDownloadBytes": .unsignedInteger(traffic.exactDownloadBytes),
            "exactTotalBytes": .unsignedInteger(traffic.exactTotalBytes),
            "notMeasuredAfterHandoffCount": .integer(
                Int64(traffic.notMeasuredAfterHandoffCount)
            ),
            "notApplicableCount": .integer(Int64(traffic.notApplicableCount)),
        ])
    }

    private func flowLedgerApplication(
        _ application: FlowLedgerApplication
    ) -> AutomationJSONValue {
        let key: AutomationJSONValue
        switch application.key {
        case let .bundleIdentifier(value):
            key = .object(["kind": .string("bundleIdentifier"), "value": .string(value)])
        case let .executablePath(value):
            key = .object(["kind": .string("executablePath"), "value": .string(value)])
        case let .processName(value):
            key = .object(["kind": .string("processName"), "value": .string(value)])
        case .unattributed:
            key = .object(["kind": .string("unattributed"), "value": .null])
        }
        return .object([
            "key": key,
            "displayName": .string(application.displayName),
            "bundleIdentifier": application.bundleIdentifier.map {
                .string($0)
            } ?? .null,
            "executablePath": application.executablePath.map {
                .string($0)
            } ?? .null,
            "processIdentifier": application.processIdentifier.map {
                .integer(Int64($0))
            } ?? .null,
            "signingIdentifier": application.signingIdentifier.map {
                .string($0)
            } ?? .null,
        ])
    }

    private func flowLedgerApplicationAggregate(
        _ aggregate: FlowLedgerApplicationAggregate
    ) -> AutomationJSONValue {
        .object([
            "application": flowLedgerApplication(aggregate.application),
            "entryCount": .integer(Int64(aggregate.entryCount)),
            "activeCount": .integer(Int64(aggregate.activeCount)),
            "traffic": flowLedgerTraffic(aggregate.traffic),
        ])
    }

    private func flowLedgerRouteAggregate(
        _ aggregate: FlowLedgerRouteAggregate
    ) -> AutomationJSONValue {
        .object([
            "route": flowLedgerRoute(aggregate.route),
            "entryCount": .integer(Int64(aggregate.entryCount)),
            "activeCount": .integer(Int64(aggregate.activeCount)),
            "traffic": flowLedgerTraffic(aggregate.traffic),
        ])
    }

    private func flowLedgerRoute(
        _ route: FlowLedgerRouteKey
    ) -> AutomationJSONValue {
        switch route {
        case let .mihomo(rule, payload, chain):
            return .object([
                "kind": .string("mihomo"),
                "rule": rule.map(AutomationJSONValue.string) ?? .null,
                "rulePayload": payload.map {
                    .string(redactedDiagnosticText(String($0.prefix(512))))
                } ?? .null,
                "chain": .array(chain.map(AutomationJSONValue.string)),
            ])
        case let .unresolvedMihomo(rule):
            return .object([
                "kind": .string("unresolvedMihomo"),
                "appRoutingRule": rule.map(AutomationJSONValue.string) ?? .null,
            ])
        case .direct: return .object(["kind": .string("direct")])
        case .rejected: return .object(["kind": .string("rejected")])
        case .failOpen: return .object(["kind": .string("failOpen")])
        case let .relayFailed(rule):
            return .object([
                "kind": .string("relayFailed"),
                "appRoutingRule": rule.map(AutomationJSONValue.string) ?? .null,
            ])
        }
    }

    private func flowLedgerEntry(_ entry: FlowLedgerEntry) -> AutomationJSONValue {
        let identifier: String = switch entry.id {
        case let .appRouting(id): "app:\(id.uuidString.lowercased())"
        case let .mihomo(id): "mihomo:\(id)"
        case let .native(id): "native:\(id)"
        }
        let state: String = switch entry.state {
        case .active: "active"
        case .completed: "completed"
        case .rejected: "rejected"
        case .failed: "failed"
        }
        return .object([
            "id": .string(identifier),
            "application": flowLedgerApplication(entry.application),
            "destination": .object([
                "hostname": entry.destination.hostname.map {
                    .string($0)
                } ?? .null,
                "ipAddress": entry.destination.ipAddress.map {
                    .string($0)
                } ?? .null,
                "port": entry.destination.port.map {
                    .integer(Int64($0))
                } ?? .null,
            ]),
            "appRoutingRule": entry.appRoutingRule.map {
                .string($0)
            } ?? .null,
            "route": flowLedgerRoute(entry.routeKey),
            "state": .string(state),
            "outcome": .string(entry.outcome.rawValue),
            "startedAt": entry.startedAt.map {
                .string($0.ISO8601Format())
            } ?? .null,
            "endedAt": entry.endedAt.map {
                .string($0.ISO8601Format())
            } ?? .null,
            "upload": flowLedgerMeasurement(entry.upload),
            "download": flowLedgerMeasurement(entry.download),
        ])
    }

    private func flowLedgerMeasurement(
        _ measurement: FlowLedgerByteMeasurement
    ) -> AutomationJSONValue {
        switch measurement {
        case let .exact(bytes):
            .object(["kind": .string("exact"), "bytes": .unsignedInteger(bytes)])
        case .notMeasuredAfterHandoff:
            .object(["kind": .string("notMeasuredAfterHandoff")])
        case .notApplicable:
            .object(["kind": .string("notApplicable")])
        }
    }

    private func ledgerFreshness() -> AutomationJSONValue {
        .object([
            "connections": freshness(.connections),
            "appRouting": freshness(.appRouting),
        ])
    }

    private func pagedJSON(
        _ values: [AutomationJSONValue],
        request: AutomationRPCRequest,
        maximumLimit: Int
    ) throws -> AutomationJSONValue {
        let page = try pageBounds(
            count: values.count,
            request: request,
            maximumLimit: maximumLimit
        )
        return page.object(items: .array(Array(values[page.range])))
    }

    private func emptyPage(
        request: AutomationRPCRequest,
        maximumLimit: Int
    ) throws -> AutomationJSONValue {
        try pagedJSON([], request: request, maximumLimit: maximumLimit)
    }

    private func diagnosticReport(
        _ request: AutomationRPCRequest
    ) throws -> AutomationJSONValue {
        let source = try request.string("source", default: "all")
        guard ["all", "stdout", "stderr", "supervisor"].contains(source) else {
            throw GatewayError.invalidParameters(
                "source must be all, stdout, stderr, or supervisor"
            )
        }
        let query = request.optionalString("query")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let filtered = model.logs.filter { line in
            let sourceMatches = switch source {
            case "all": true
            case "stdout": line.stream == .standardOutput
            case "stderr": line.stream == .standardError
            case "supervisor": line.stream == .supervisor
            default: false
            }
            return sourceMatches && (query.isEmpty
                || line.message.localizedCaseInsensitiveContains(query))
        }
        let page = try pageBounds(
            count: filtered.count,
            request: request,
            maximumLimit: 200
        )
        let lines = filtered[page.range].map { line in
            AutomationJSONValue.object([
                "timestamp": .string(line.timestamp.ISO8601Format()),
                "source": .string(line.stream.rawValue),
                "message": .string(String(
                    redactedDiagnosticText(line.message).prefix(8 * 1_024)
                )),
            ])
        }
        return page.object(items: .array(lines)).mergingObject([
            "generatedAt": .string(Date().ISO8601Format()),
            "source": .string(source),
            "searchFilterApplied": .bool(!query.isEmpty),
            "diagnostics": diagnostics(),
            "freshness": freshness(.logs),
        ])
    }

    private func destination(_ value: String) throws -> AppModel.Destination {
        guard let destination = AppModel.Destination(rawValue: value) else {
            throw GatewayError.invalidParameters("Unknown destination: \(value)")
        }
        return destination
    }

    private func redactedURL(_ url: URL) -> String {
        guard let scheme = url.scheme, let host = url.host else {
            return "https://redacted.invalid/"
        }
        var value = "\(scheme)://\(host)"
        if let port = url.port { value += ":\(port)" }
        return value + "/"
    }

    private func redactedURLString(_ value: String) -> String {
        guard let url = URL(string: value) else { return "redacted" }
        return redactedURL(url)
    }

    private func configurationGatewayError(
        _ error: Error
    ) -> GatewayError {
        if let error = error as? GatewayError {
            return error
        }
        if error is CancellationError {
            return .operationInProgress
        }
        if let error = error as? ConfigurationCompilationError {
            switch error {
            case let .invalid(diagnostics):
                return .configurationInvalid(diagnostics)
            case let .invalidText(message):
                return .operationFailed(message, false)
            }
        }
        guard let error = error as? ConfigurationAutomationError else {
            return .operationFailed(error.localizedDescription, false)
        }
        return switch error {
        case .operationInProgress:
            .operationInProgress
        case .invalidRevision:
            .invalidParameters(error.localizedDescription)
        case let .invalidInput(message):
            .invalidParameters(message)
        case let .revisionConflict(currentRevision):
            .configurationRevisionConflict(currentRevision)
        case let .invalidConfiguration(diagnostics):
            .configurationInvalid(diagnostics)
        case let .dependencies(dependencies):
            .configurationDependencies(dependencies)
        }
    }

    private static let configurationDocumentHint =
        "Compact projection from configuration.snapshot.document; preserve every top-level array. "
        + "Snapshots omit proxyGroups.memberSelectors; export them with "
        + "configuration.proxyGroup.selectors.export. "
        + "Sparse writes use nodeSettings enabled/userAliasUpdate/removeUserAlias/tagsUpdate/"
        + "regionUpdate/removeRegion, proxyGroups.membersUpdate/memberSelectors, rules.matchersUpdate, "
        + "ruleSets.rulesUpdate/sourceURLUpdate/removeSourceURL/behavior/format/pathUpdate/removePath/enabled, dnsPolicies.nameserversUpdate/"
        + "fallbackNameserversUpdate/proxyServerUpdate/removeProxyServer/rulesUpdate, and "
        + "workspaces nodeScope/nodeIDsUpdate/proxyGroupIDsUpdate/ruleIDsUpdate/ruleSetIDsUpdate/"
        + "entranceIDsUpdate/routingMode/globalProxyGroupID/removeGlobalProxyGroupID; *Count fields are read-only summaries. Enums: nodeScope="
        + "allEnabled|listed; member.kind="
        + "node|group; proxyGroups.type=select|fallback|urlTest|loadBalance|direct|reject|relay; "
        + "selector condition.kind=nameContains|nameEquals|hostContains|hostEquals|ipEquals|"
        + "source|protocolIs|tagContains; memberCount is explicit-only and selectorCount is policy count; "
        + "memberSelectors is a write-only whole replacement: omit to preserve, [] to clear; "
        + "selector include conditions are ANDed, excludes remove automatic matches, and selectors are ORed; "
        + "matcher.kind=application|processPath|processName|userID|domainExact|domainSuffix|domainWildcard|"
        + "ipCIDR|geoIP|geoIP6|geoSite|transport|port|portRange; action.kind=direct|reject|proxyGroup; "
        + "unavailableFallback=direct|reject; dnsPolicies.mode=system|fakeIP|redirHost; "
        + "entrances.kind=http|socks5|appRouting|tun"

    private static let configurationRevisionHint =
        "Exact configurationRevision returned by configuration.snapshot"

    static let capabilities: [AutomationCapability] = [
        capability("system.capabilities", "List supported automation methods", .read),
        capability("auth.pair", "Pair and authorize an external client", .write),
        capability("auth.clients.list", "List paired automation clients", .read),
        capability("auth.clients.revoke", "Revoke a paired automation client", .destructive),
        capability("system.snapshot", "Read the current application snapshot", .read),
        capability("app.ui.show", "Show a MClash window destination", .write, [
            "destination": AppModel.Destination.allCases.map(\.rawValue).joined(separator: "|")
        ]),
        capability("app.ui.hide", "Hide MClash windows while keeping it running", .write),
        capability("app.quit", "Quit MClash safely", .destructive),
        capability("app.update.status", "Read update settings", .read),
        capability("app.update.check", "Open the update checker", .write),
        capability("app.update.configure", "Change automatic update settings", .write),
        capability("settings.get", "Read application settings", .read),
        capability("settings.patch", "Change application settings", .write),
        capability("configuration.snapshot", "Read the safe editable Configuration projection", .read, [
            "nodeOffset": "0-based node offset",
            "nodeLimit": "node page size; default 100, maximum 200",
            "sourceOffset": "0-based source offset",
            "sourceLimit": "source page size; default 50, maximum 100",
        ]),
        capability("configuration.proxyGroup.selectors.export", "Export one proxy group's selector policy as byte chunks", .read, [
            "groupID": "proxy group UUID",
            "expectedRevision": configurationRevisionHint,
            "offset": "0-based byte offset; default 0",
            "limitBytes": "chunk size; default 262144, maximum 524288",
        ]),
        capability("configuration.plan", "Validate and compile a Configuration projection without saving it", .read, [
            "document": configurationDocumentHint,
            "expectedRevision": configurationRevisionHint,
        ]),
        capability("configuration.apply", "Save desired Configuration without changing the current proxy session", .destructive, [
            "document": configurationDocumentHint,
            "expectedRevision": configurationRevisionHint,
        ]),
        capability("configuration.delete", "Delete one unreferenced Configuration object", .destructive, [
            "kind": "proxyGroup|rule|ruleSet|dnsPolicy|entrance|workspace",
            "id": "object UUID",
            "expectedRevision": configurationRevisionHint,
        ]),
        capability("configuration.workspace.activate", "Compile and activate one Configuration workspace", .destructive, [
            "id": "workspace UUID",
            "expectedRevision": configurationRevisionHint,
        ]),
        capability("core.status", "Read core status", .read),
        capability("core.toggle", "Toggle the Mihomo core", .write),
        capability("core.connect", "Start the Mihomo core", .write),
        capability("core.disconnect", "Stop the Mihomo core safely", .write),
        capability("core.restart", "Restart the Mihomo core", .write),
        capability("profiles.list", "List profiles without subscription secrets (maximum page 100)", .read),
        capability("profiles.importInteractive", "Open the profile import panel", .write),
        capability("profiles.import", "Import profile YAML supplied as base64", .write),
        capability("profiles.addSubscription", "Add an HTTPS subscription", .write),
        capability("profiles.activate", "Activate a profile", .write),
        capability("profiles.update", "Update profile metadata", .write),
        capability("profiles.refresh", "Refresh a subscription profile", .write),
        capability("profiles.refreshAll", "Refresh all subscriptions", .write),
        capability("profiles.remove", "Remove a profile", .destructive),
        capability("profiles.pendingImport.get", "Read a redacted pending import", .read),
        capability("profiles.pendingImport.confirm", "Confirm a pending import", .write),
        capability("profiles.pendingImport.cancel", "Cancel a pending import", .write),
        capability("backup.exportInteractive", "Open the backup export panel", .write),
        capability("backup.restoreInteractive", "Open the backup restore panel", .destructive),
        capability("runtime.get", "Read runtime overrides", .read),
        capability("runtime.overrides.replace", "Replace runtime overrides transactionally", .write, ["overrides": "full object returned by runtime.get"]),
        capability("runtime.overrides.reset", "Reset runtime overrides", .destructive),
        capability("routing.status", "Read routing status", .read),
        capability("routing.mode.set", "Set rule, global, or direct mode", .write),
        capability("routing.groups.list", "List proxy groups", .read),
        capability("routing.group.choices.list", "List choices in one proxy group", .read),
        capability("routing.proxy.select", "Select a proxy in a group", .write),
        capability("routing.proxy.clearOverride", "Restore automatic group selection", .write),
        capability("routing.proxy.test", "Measure one proxy latency", .write),
        capability("routing.group.test", "Measure proxy group latency", .write),
        capability("mihomo.rules.list", "List loaded Mihomo rules", .read),
        capability("mihomo.rules.refresh", "Refresh Mihomo rules", .write),
        capability("providers.list", "List proxy and rule provider summaries", .read),
        capability("providers.refresh", "Refresh providers", .write),
        capability("providers.proxy.update", "Update a proxy provider", .write),
        capability("providers.proxy.healthCheck", "Health-check a proxy provider", .write),
        capability("providers.rule.update", "Update a rule provider", .write),
        capability("systemProxy.status", "Read System Proxy status", .read),
        capability("systemProxy.setEnabled", "Enable or disable System Proxy", .write),
        capability("systemProxy.preferences.get", "Read System Proxy preferences", .read),
        capability("systemProxy.preferences.replace", "Replace System Proxy preferences", .write, ["preferences": "full object returned by systemProxy.preferences.get"]),
        capability("systemProxy.guard.setPaused", "Pause or resume System Proxy guard", .write),
        capability("systemProxy.guard.verify", "Verify and repair System Proxy now", .write),
        capability("appRouting.status", "Read App Routing status", .read),
        capability("appRouting.setEnabled", "Enable or disable App Routing", .destructive),
        capability("appRouting.retry", "Retry App Routing activation", .write),
        capability("appRouting.dns.setEnabled", "Enable or disable App Routing DNS", .destructive),
        capability("appRouting.dns.retry", "Retry App Routing DNS", .write),
        capability("appRouting.rules.list", "List App Routing rules", .read),
        capability("appRouting.candidates.list", "List signed applications or running processes on demand", .read, ["kind": "applications|processes"]),
        capability("appRouting.rules.replace", "Replace App Routing rules transactionally", .destructive, ["rules": "items returned by appRouting.rules.list"]),
        capability("appRouting.proxifier.preview", "Preview a safe Proxifier PPX rule conversion", .write),
        capability("appRouting.proxifier.import", "Import explicitly selected Proxifier rules", .destructive),
        capability("appRouting.activities.clear", "Clear App Routing activities", .destructive),
        capability("appRouting.activities.list", "List cached App Routing activities", .read),
        capability("traffic.snapshot", "Read cached traffic statistics", .read),
        capability("traffic.connections.list", "List cached live connections", .read),
        capability("traffic.connections.close", "Close one connection", .write),
        capability("traffic.connections.closeAll", "Close all connections", .destructive),
        capability("traffic.closed.clear", "Clear the closed-connection session list", .destructive),
        capability("traffic.closed.list", "List recently closed connections", .read),
        capability("traffic.history.setPersistent", "Configure persistent traffic history", .write),
        capability("traffic.history.setRetention", "Set history retention", .write),
        capability("traffic.history.clear", "Clear all traffic history", .destructive),
        capability("traffic.history.summary", "Read cached persistent traffic history totals", .read),
        capability("traffic.history.applications.list", "List cached persistent traffic by application", .read),
        capability("traffic.history.routes.list", "List cached persistent traffic by route", .read),
        capability("traffic.ledger.applications.list", "List session traffic by application", .read),
        capability("traffic.ledger.routes.list", "List session traffic by route", .read),
        capability("traffic.ledger.history.list", "List completed session traffic flows", .read),
        capability("logs.list", "Read cached application logs", .read),
        capability("logs.clear", "Clear application logs", .destructive),
        capability("diagnostics.snapshot", "Read operational diagnostics", .read),
        capability("diagnostics.report.get", "Build a paged redacted diagnostic report", .read),
    ]

    private enum ParameterKind {
        case string
        case bool
        case integer
        case nullableInteger
        case object
        case array
        case stringArray

        var description: String {
            switch self {
            case .string: "string"
            case .bool: "boolean"
            case .integer: "integer"
            case .nullableInteger: "integer|null"
            case .object: "object"
            case .array: "array"
            case .stringArray: "string[]"
            }
        }

        func accepts(_ value: AutomationJSONValue) -> Bool {
            switch (self, value) {
            case (.string, .string), (.bool, .bool), (.integer, .integer),
                 (.integer, .unsignedInteger), (.object, .object), (.array, .array):
                true
            case (.nullableInteger, .integer), (.nullableInteger, .unsignedInteger),
                 (.nullableInteger, .null):
                true
            case let (.stringArray, .array(values)):
                values.allSatisfy { $0.stringValue != nil }
            default:
                false
            }
        }
    }

    private struct ParameterSpec {
        let kind: ParameterKind
        let required: Bool
        let maximumStringBytes: Int?

        static func required(
            _ kind: ParameterKind,
            maximumStringBytes: Int? = nil
        ) -> Self {
            Self(
                kind: kind,
                required: true,
                maximumStringBytes: maximumStringBytes
            )
        }

        static func optional(
            _ kind: ParameterKind,
            maximumStringBytes: Int? = nil
        ) -> Self {
            Self(
                kind: kind,
                required: false,
                maximumStringBytes: maximumStringBytes
            )
        }
    }

    private static let parameterSchemas: [String: [String: ParameterSpec]] = [
        "auth.pair": [
            "name": .required(.string, maximumStringBytes: 80),
            "scopes": .required(.stringArray),
        ],
        "auth.clients.revoke": ["id": .required(.string)],
        "app.ui.show": ["destination": .optional(.string)],
        "app.update.configure": ["automaticChecks": .optional(.bool), "automaticDownloads": .optional(.bool)],
        "settings.patch": [
            "launchAtLogin": .optional(.bool), "notificationsEnabled": .optional(.bool),
            "autoConnectOnLaunch": .optional(.bool), "autoEnableSystemProxy": .optional(.bool),
            "lightweightMode": .optional(.bool),
            "menuBarDisplayStyle": .optional(.string, maximumStringBytes: 32),
            "closeConnectionsOnRoutingChange": .optional(.bool),
        ],
        "configuration.plan": [
            "document": .required(.object),
            "expectedRevision": .required(.string, maximumStringBytes: 36),
        ],
        "configuration.snapshot": [
            "nodeOffset": .optional(.integer),
            "nodeLimit": .optional(.integer),
            "sourceOffset": .optional(.integer),
            "sourceLimit": .optional(.integer),
        ],
        "configuration.proxyGroup.selectors.export": [
            "groupID": .required(.string, maximumStringBytes: 36),
            "expectedRevision": .required(.string, maximumStringBytes: 36),
            "offset": .optional(.integer),
            "limitBytes": .optional(.integer),
        ],
        "configuration.apply": [
            "document": .required(.object),
            "expectedRevision": .required(.string, maximumStringBytes: 36),
        ],
        "configuration.delete": [
            "kind": .required(.string, maximumStringBytes: 32),
            "id": .required(.string, maximumStringBytes: 36),
            "expectedRevision": .required(.string, maximumStringBytes: 36),
        ],
        "configuration.workspace.activate": [
            "id": .required(.string, maximumStringBytes: 36),
            "expectedRevision": .required(.string, maximumStringBytes: 36),
        ],
        "profiles.list": ["offset": .optional(.integer), "limit": .optional(.integer)],
        "profiles.import": [
            "dataBase64": .required(.string, maximumStringBytes: 960 * 1_024),
            "fileName": .optional(.string, maximumStringBytes: 255),
            "activate": .optional(.bool),
        ],
        "profiles.addSubscription": ["name": .required(.string), "url": .required(.string), "activate": .optional(.bool)],
        "profiles.activate": ["id": .required(.string), "force": .optional(.bool)],
        "profiles.update": [
            "id": .required(.string), "name": .optional(.string),
            "subscriptionURL": .optional(.string), "automaticUpdatesEnabled": .optional(.bool),
            "updateIntervalHours": .optional(.nullableInteger),
        ],
        "profiles.refresh": ["id": .required(.string)],
        "profiles.remove": ["id": .required(.string)],
        "runtime.overrides.replace": ["overrides": .required(.object)],
        "routing.mode.set": ["mode": .required(.string)],
        "routing.groups.list": ["offset": .optional(.integer), "limit": .optional(.integer)],
        "routing.group.choices.list": [
            "group": .required(.string), "offset": .optional(.integer),
            "limit": .optional(.integer),
        ],
        "routing.proxy.select": ["group": .required(.string), "proxy": .required(.string)],
        "routing.proxy.clearOverride": ["group": .required(.string)],
        "routing.proxy.test": ["proxy": .required(.string), "group": .optional(.string)],
        "routing.group.test": ["group": .required(.string)],
        "mihomo.rules.list": ["offset": .optional(.integer), "limit": .optional(.integer)],
        "providers.list": ["offset": .optional(.integer), "limit": .optional(.integer)],
        "providers.proxy.update": ["name": .required(.string)],
        "providers.proxy.healthCheck": ["name": .required(.string)],
        "providers.rule.update": ["name": .required(.string)],
        "systemProxy.setEnabled": ["enabled": .required(.bool)],
        "systemProxy.preferences.replace": ["preferences": .required(.object)],
        "systemProxy.guard.setPaused": ["paused": .required(.bool)],
        "appRouting.setEnabled": ["enabled": .required(.bool)],
        "appRouting.dns.setEnabled": ["enabled": .required(.bool)],
        "appRouting.rules.list": ["offset": .optional(.integer), "limit": .optional(.integer)],
        "appRouting.candidates.list": [
            "kind": .required(.string), "offset": .optional(.integer),
            "limit": .optional(.integer),
        ],
        "appRouting.rules.replace": [
            "rules": .required(.array), "expectedRevision": .required(.integer),
            "enabled": .optional(.bool), "dnsEnabled": .optional(.bool),
        ],
        "appRouting.proxifier.preview": [
            "dataBase64": .required(.string, maximumStringBytes: 960 * 1_024),
            "sourceName": .optional(.string, maximumStringBytes: 255),
            "offset": .optional(.integer), "limit": .optional(.integer),
        ],
        "appRouting.proxifier.import": [
            "dataBase64": .required(.string, maximumStringBytes: 960 * 1_024),
            "sourceName": .optional(.string, maximumStringBytes: 255),
            "selectedItemIDs": .required(.array),
            "expectedRevision": .required(.integer),
        ],
        "appRouting.activities.list": ["offset": .optional(.integer), "limit": .optional(.integer)],
        "traffic.connections.list": ["offset": .optional(.integer), "limit": .optional(.integer)],
        "traffic.connections.close": ["id": .required(.string)],
        "traffic.closed.list": ["offset": .optional(.integer), "limit": .optional(.integer)],
        "traffic.history.setPersistent": ["enabled": .required(.bool)],
        "traffic.history.setRetention": ["days": .required(.integer)],
        "traffic.history.summary": ["period": .required(.string)],
        "traffic.history.applications.list": [
            "period": .required(.string), "offset": .optional(.integer),
            "limit": .optional(.integer),
        ],
        "traffic.history.routes.list": [
            "period": .required(.string), "offset": .optional(.integer),
            "limit": .optional(.integer),
        ],
        "traffic.ledger.applications.list": [
            "offset": .optional(.integer), "limit": .optional(.integer),
        ],
        "traffic.ledger.routes.list": [
            "offset": .optional(.integer), "limit": .optional(.integer),
        ],
        "traffic.ledger.history.list": [
            "offset": .optional(.integer), "limit": .optional(.integer),
        ],
        "logs.list": ["offset": .optional(.integer), "limit": .optional(.integer)],
        "diagnostics.report.get": [
            "source": .optional(.string), "query": .optional(.string),
            "offset": .optional(.integer), "limit": .optional(.integer),
        ],
    ]

    private static var capabilitiesForClients: [AutomationCapability] {
        capabilities.map { capability in
            let schema = parameterSchemas[capability.method] ?? [:]
            var parameters = capability.parameters
            for (name, spec) in schema {
                let type = spec.kind.description
                    + (spec.required ? " (required)" : " (optional)")
                parameters[name] = parameters[name].map { "\($0); \(type)" } ?? type
            }
            return AutomationCapability(
                method: capability.method,
                summary: capability.summary,
                risk: capability.risk,
                parameters: parameters,
                requiredScope: capability.method == "system.capabilities"
                    || capability.method == "auth.pair"
                    ? nil : requiredScope(for: capability),
                requiresInteraction: capability.risk == .destructive
                    || inherentlyInteractiveMethods.contains(capability.method)
            )
        }
    }

    private static let inherentlyInteractiveMethods: Set<String> = [
        "auth.pair",
        "app.update.check",
        "profiles.importInteractive",
        "backup.exportInteractive",
    ]

    private static func validateParameters(_ request: AutomationRPCRequest) throws {
        guard !request.id.isEmpty, request.id.utf8.count <= 128 else {
            throw GatewayError.invalidRequest("id must contain 1...128 UTF-8 bytes")
        }
        guard !request.method.isEmpty, request.method.utf8.count <= 128 else {
            throw GatewayError.invalidRequest("method must contain 1...128 UTF-8 bytes")
        }
        guard request.authorization?.utf8.count ?? 0 <= 256 else {
            throw GatewayError.invalidRequest("authorization exceeds 256 UTF-8 bytes")
        }
        guard request.params.count <= 64,
              request.params.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw GatewayError.invalidParameters("params contains too many or oversized keys")
        }
        let schema = parameterSchemas[request.method] ?? [:]
        for name in request.params.keys where schema[name] == nil {
            throw GatewayError.invalidParameters("Unknown parameter for \(request.method): \(name)")
        }
        for (name, spec) in schema {
            guard let value = request.params[name] else {
                if spec.required {
                    throw GatewayError.invalidParameters("Missing parameter: \(name)")
                }
                continue
            }
            guard spec.kind.accepts(value) else {
                throw GatewayError.invalidParameters("\(name) must be \(spec.kind.description)")
            }
            if case let .string(string) = value,
               string.utf8.count > (spec.maximumStringBytes ?? 8 * 1_024) {
                throw GatewayError.invalidParameters("\(name) is too long")
            }
            if case let .array(values) = value,
               case .stringArray = spec.kind {
                guard values.count <= AutomationClientScope.allCases.count,
                      values.allSatisfy({ ($0.stringValue?.utf8.count ?? .max) <= 128 }) else {
                    throw GatewayError.invalidParameters("\(name) contains too many or oversized values")
                }
            }
        }
        if request.method == "settings.patch",
           let value = request.params["menuBarDisplayStyle"]?.stringValue,
           AppModel.MenuBarDisplayStyle(rawValue: value) == nil {
            throw GatewayError.invalidParameters(
                "menuBarDisplayStyle must be logo or proxyStatus"
            )
        }
        if request.method == "configuration.plan"
            || request.method == "configuration.apply",
           let document = request.params["document"] {
            try validateConfigurationDocumentShape(document)
        }
    }

    private static func validateConfigurationDocumentShape(
        _ value: AutomationJSONValue
    ) throws {
        let document = try configurationObject(value, path: "document")
        try rejectUnknownConfigurationKeys(document, allowed: [
            "schemaVersion", "nodeSettings", "proxyGroups", "rules", "ruleSets",
            "dnsPolicies", "entrances", "workspaces",
        ], path: "document")

        for (index, value) in try configurationArray(document["nodeSettings"], path: "document.nodeSettings").enumerated() {
            try rejectUnknownConfigurationKeys(
                try configurationObject(value, path: "document.nodeSettings[\(index)]"),
                allowed: [
                    "id", "enabled", "userAliasUpdate", "removeUserAlias",
                    "tagsUpdate", "regionUpdate", "removeRegion",
                ],
                path: "document.nodeSettings[\(index)]"
            )
        }
        for (index, value) in try configurationArray(document["proxyGroups"], path: "document.proxyGroups").enumerated() {
            let object = try configurationObject(value, path: "document.proxyGroups[\(index)]")
            try rejectUnknownConfigurationKeys(object, allowed: [
                "id", "name", "type", "membersUpdate", "memberCount",
                "memberSelectors", "selectorCount", "enabled",
            ], path: "document.proxyGroups[\(index)]")
            if let members = object["membersUpdate"] {
                for (memberIndex, member) in try configurationArray(members, path: "document.proxyGroups[\(index)].membersUpdate").enumerated() {
                    try rejectUnknownConfigurationKeys(
                        try configurationObject(member, path: "document.proxyGroups[\(index)].membersUpdate[\(memberIndex)]"),
                        allowed: ["kind", "id"],
                        path: "document.proxyGroups[\(index)].membersUpdate[\(memberIndex)]"
                    )
                }
            }
            if let selectors = object["memberSelectors"] {
                for (selectorIndex, selector) in try configurationArray(
                    selectors,
                    path: "document.proxyGroups[\(index)].memberSelectors"
                ).enumerated() {
                    let selectorPath = "document.proxyGroups[\(index)].memberSelectors[\(selectorIndex)]"
                    let selectorObject = try configurationObject(selector, path: selectorPath)
                    try rejectUnknownConfigurationKeys(
                        selectorObject,
                        allowed: ["id", "name", "include", "exclude", "fixedNodeIDs"],
                        path: selectorPath
                    )
                    for field in ["include", "exclude"] {
                        for (conditionIndex, condition) in try configurationArray(
                            selectorObject[field],
                            path: "\(selectorPath).\(field)"
                        ).enumerated() {
                            let conditionPath = "\(selectorPath).\(field)[\(conditionIndex)]"
                            try rejectUnknownConfigurationKeys(
                                try configurationObject(condition, path: conditionPath),
                                allowed: ["kind", "value"],
                                path: conditionPath
                            )
                        }
                    }
                }
            }
        }
        for (index, value) in try configurationArray(document["rules"], path: "document.rules").enumerated() {
            let object = try configurationObject(value, path: "document.rules[\(index)]")
            try rejectUnknownConfigurationKeys(object, allowed: [
                "id", "enabled", "priority", "matchersUpdate", "matcherCount",
                "action", "unavailableFallback", "workspaceScope",
            ], path: "document.rules[\(index)]")
            if let matchers = object["matchersUpdate"] {
                for (matcherIndex, matcher) in try configurationArray(matchers, path: "document.rules[\(index)].matchersUpdate").enumerated() {
                    let path = "document.rules[\(index)].matchersUpdate[\(matcherIndex)]"
                    let object = try configurationObject(matcher, path: path)
                    try rejectUnknownConfigurationKeys(
                        object,
                        allowed: object["kind"]?.stringValue == "portRange"
                            ? ["kind", "lowerBound", "upperBound"]
                            : ["kind", "value"],
                        path: path
                    )
                }
            }
            try validateConfigurationAction(object["action"], path: "document.rules[\(index)].action")
        }
        for (index, value) in try configurationArray(document["ruleSets"], path: "document.ruleSets").enumerated() {
            let object = try configurationObject(value, path: "document.ruleSets[\(index)]")
            try rejectUnknownConfigurationKeys(object, allowed: [
                "id", "name", "rulesUpdate", "ruleCount", "defaultAction",
                "sourceURLUpdate", "removeSourceURL", "behavior", "format",
                "pathUpdate", "removePath", "enabled",
            ], path: "document.ruleSets[\(index)]")
            try validateConfigurationAction(object["defaultAction"], path: "document.ruleSets[\(index)].defaultAction")
        }
        for (index, value) in try configurationArray(document["dnsPolicies"], path: "document.dnsPolicies").enumerated() {
            try rejectUnknownConfigurationKeys(
                try configurationObject(value, path: "document.dnsPolicies[\(index)]"),
                allowed: [
                    "id", "name", "mode", "nameserversUpdate", "nameserverCount",
                    "fallbackNameserversUpdate", "fallbackNameserverCount",
                    "proxyServerUpdate", "removeProxyServer", "rulesUpdate",
                    "ruleCount", "takeoverEnabled",
                ],
                path: "document.dnsPolicies[\(index)]"
            )
        }
        for (index, value) in try configurationArray(document["entrances"], path: "document.entrances").enumerated() {
            let object = try configurationObject(value, path: "document.entrances[\(index)]")
            try rejectUnknownConfigurationKeys(object, allowed: [
                "id", "name", "kind", "enabled", "bindAddress", "port", "defaultAction",
                "workspaceOverride",
            ], path: "document.entrances[\(index)]")
            try validateConfigurationAction(object["defaultAction"], path: "document.entrances[\(index)].defaultAction")
        }
        for (index, value) in try configurationArray(document["workspaces"], path: "document.workspaces").enumerated() {
            try rejectUnknownConfigurationKeys(
                try configurationObject(value, path: "document.workspaces[\(index)]"),
                allowed: [
                    "id", "name", "nodeScope", "nodeIDsUpdate", "nodeCount",
                    "effectiveNodeCount",
                    "proxyGroupIDsUpdate", "proxyGroupCount", "ruleIDsUpdate",
                    "ruleCount", "ruleSetIDsUpdate", "ruleSetCount", "dnsPolicyID",
                    "entranceIDsUpdate", "routingMode", "globalProxyGroupID", "removeGlobalProxyGroupID",
                    "entranceCount", "revision",
                ],
                path: "document.workspaces[\(index)]"
            )
        }
    }

    private static func validateConfigurationAction(
        _ value: AutomationJSONValue?,
        path: String
    ) throws {
        let object = try configurationObject(value, path: path)
        try rejectUnknownConfigurationKeys(
            object,
            allowed: object["kind"]?.stringValue == "proxyGroup"
                ? ["kind", "proxyGroupID"] : ["kind"],
            path: path
        )
    }

    private static func configurationObject(
        _ value: AutomationJSONValue?,
        path: String
    ) throws -> [String: AutomationJSONValue] {
        guard case let .object(object)? = value else {
            throw GatewayError.invalidParameters("\(path) must be an object")
        }
        return object
    }

    private static func configurationArray(
        _ value: AutomationJSONValue?,
        path: String
    ) throws -> [AutomationJSONValue] {
        guard case let .array(array)? = value else {
            throw GatewayError.invalidParameters("\(path) must be an array")
        }
        return array
    }

    private static func rejectUnknownConfigurationKeys(
        _ object: [String: AutomationJSONValue],
        allowed: Set<String>,
        path: String
    ) throws {
        if let key = object.keys.filter({ !allowed.contains($0) }).sorted().first {
            throw GatewayError.invalidParameters("Unknown field: \(path).\(key)")
        }
    }

    private static let sensitiveReadMethods: Set<String> = [
        "configuration.plan",
        "configuration.snapshot",
        "configuration.proxyGroup.selectors.export",
        "appRouting.candidates.list",
        "appRouting.activities.list",
        "traffic.connections.list",
        "traffic.closed.list",
        "traffic.history.summary",
        "traffic.history.applications.list",
        "traffic.history.routes.list",
        "traffic.ledger.applications.list",
        "traffic.ledger.routes.list",
        "traffic.ledger.history.list",
        "logs.list",
        "diagnostics.snapshot",
        "diagnostics.report.get",
        "mihomo.rules.list",
        "routing.groups.list",
        "routing.group.choices.list",
        "routing.status",
        "providers.list",
        "auth.clients.list",
        "system.snapshot",
        "appRouting.rules.list",
        "profiles.pendingImport.get",
        "profiles.list",
        "runtime.get",
        "systemProxy.preferences.get",
    ]

    private static func capability(
        _ method: String,
        _ summary: String,
        _ risk: AutomationCommandRisk,
        _ parameters: [String: String] = [:]
    ) -> AutomationCapability {
        AutomationCapability(method: method, summary: summary, risk: risk, parameters: parameters)
    }
}

private enum GatewayError: Error, LocalizedError {
    case invalidRequest(String)
    case unsupportedVersion(Int)
    case methodNotFound(String)
    case invalidParameters(String)
    case confirmationRequired(String)
    case permissionDenied(String)
    case untrustedClient
    case operationFailed(String, Bool)
    case operationInProgress
    case revisionConflict(UInt64)
    case configurationRevisionConflict(String)
    case configurationInvalid([ConfigurationDiagnostic])
    case configurationDependencies([ConfigurationAutomationDependency])
    case pairingRateLimited
    case interactionRateLimited

    var errorDescription: String? { rpcError.message }

    var rpcError: AutomationRPCError {
        switch self {
        case let .invalidRequest(message):
            AutomationRPCError(code: -32600, type: "invalid_request", message: message)
        case let .unsupportedVersion(version):
            AutomationRPCError(code: -32010, type: "unsupported_api_version", message: "Automation API version \(version) is unsupported")
        case let .methodNotFound(method):
            AutomationRPCError(code: -32601, type: "method_not_found", message: "Unknown automation method: \(method)")
        case let .invalidParameters(message):
            AutomationRPCError(
                code: -32602,
                type: "invalid_parameters",
                message: message,
                retryable: true,
                data: retryWithNewRequestIDData
            )
        case let .confirmationRequired(method):
            AutomationRPCError(
                code: -32020,
                type: "confirmation_required",
                message: "\(method) requires one-time local confirmation; retry with allowInteraction=true",
                data: .object(["requiresUserApproval": .bool(true)])
            )
        case let .permissionDenied(method):
            AutomationRPCError(code: -32021, type: "permission_denied", message: "The local user denied \(method)")
        case .untrustedClient:
            AutomationRPCError(
                code: -32044,
                type: "untrusted_client",
                message: "Automation clients must have a valid code signature"
            )
        case let .operationFailed(message, retryable):
            AutomationRPCError(
                code: -32030,
                type: "operation_failed",
                message: redactedDiagnosticText(message),
                retryable: retryable,
                data: retryable ? retryWithNewRequestIDData : nil
            )
        case .operationInProgress:
            AutomationRPCError(
                code: -32031,
                type: "operation_in_progress",
                message: "Another external MClash operation is in progress",
                retryable: true,
                data: retryWithSameRequestIDData
            )
        case let .revisionConflict(currentRevision):
            AutomationRPCError(
                code: -32032,
                type: "revision_conflict",
                message: "App Routing rules changed before this update could be applied",
                retryable: true,
                data: .object([
                    "currentRevision": .unsignedInteger(currentRevision),
                    "retryWithNewRequestID": .bool(true),
                ])
            )
        case let .configurationRevisionConflict(currentRevision):
            AutomationRPCError(
                code: -32033,
                type: "configuration_revision_conflict",
                message: "The Configuration document changed before this operation could be applied",
                retryable: true,
                data: .object([
                    "currentRevision": .string(currentRevision),
                    "retryWithNewRequestID": .bool(true),
                ])
            )
        case let .configurationInvalid(diagnostics):
            AutomationRPCError(
                code: -32034,
                type: "configuration_invalid",
                message: "The proposed Configuration document is invalid",
                retryable: true,
                data: .object([
                    "diagnostics": .array(diagnostics.map { diagnostic in
                        .object([
                            "severity": .string(diagnostic.severity.rawValue),
                            "code": .string(diagnostic.code),
                            "subject": .string(diagnostic.subject),
                            "message": .string(redactedDiagnosticText(diagnostic.message)),
                        ])
                    }),
                    "retryWithNewRequestID": .bool(true),
                ])
            )
        case let .configurationDependencies(dependencies):
            AutomationRPCError(
                code: -32035,
                type: "configuration_dependencies",
                message: "The Configuration object is still referenced",
                retryable: true,
                data: .object([
                    "dependencies": .array(dependencies.map { dependency in
                        .object([
                            "kind": .string(dependency.kind),
                            "id": .string(dependency.id),
                        ])
                    }),
                    "retryWithNewRequestID": .bool(true),
                ])
            )
        case .pairingRateLimited:
            AutomationRPCError(
                code: -32043,
                type: "pairing_rate_limited",
                message: "Wait before showing another pairing request",
                retryable: true,
                data: retryWithSameRequestIDData
            )
        case .interactionRateLimited:
            AutomationRPCError(
                code: -32045,
                type: "interaction_rate_limited",
                message: "Wait before presenting another automation UI request",
                retryable: true,
                data: retryWithSameRequestIDData
            )
        }
    }

    private var retryWithNewRequestIDData: AutomationJSONValue {
        .object(["retryWithNewRequestID": .bool(true)])
    }

    private var retryWithSameRequestIDData: AutomationJSONValue {
        .object(["retryWithSameRequestID": .bool(true)])
    }
}

private extension AutomationRPCRequest {
    func optionalString(_ name: String) -> String? { params[name]?.stringValue }

    func string(_ name: String, default defaultValue: String? = nil) throws -> String {
        if let value = optionalString(name) { return value }
        if let defaultValue { return defaultValue }
        throw GatewayError.invalidParameters("Missing string parameter: \(name)")
    }

    func optionalBool(_ name: String) -> Bool? { params[name]?.boolValue }

    func requiredBool(_ name: String) throws -> Bool {
        guard let value = optionalBool(name) else {
            throw GatewayError.invalidParameters("Missing boolean parameter: \(name)")
        }
        return value
    }

    func bool(_ name: String, default defaultValue: Bool) -> Bool {
        optionalBool(name) ?? defaultValue
    }

    func optionalInt(_ name: String) -> Int? { params[name]?.intValue }

    func int(_ name: String, default defaultValue: Int? = nil) throws -> Int {
        if let value = optionalInt(name) { return value }
        if let defaultValue { return defaultValue }
        throw GatewayError.invalidParameters("Missing integer parameter: \(name)")
    }

    func profileID() throws -> ProfileID {
        let rawValue = try string("id")
        guard let uuid = UUID(uuidString: rawValue) else {
            throw GatewayError.invalidParameters("id must be a profile UUID")
        }
        return ProfileID(rawValue: uuid)
    }

    func configurationRevision() throws -> UUID {
        let rawValue = try string("expectedRevision")
        guard let revision = UUID(uuidString: rawValue) else {
            throw ConfigurationAutomationError.invalidRevision(rawValue)
        }
        return revision
    }

    func decode<T: Decodable>(_ name: String) throws -> T {
        guard let value = params[name] else {
            throw GatewayError.invalidParameters("Missing parameter: \(name)")
        }
        do {
            return try JSONDecoder.automation.decode(
                T.self,
                from: JSONEncoder.automation.encode(value)
            )
        } catch {
            throw GatewayError.invalidParameters("Invalid \(name): \(error.localizedDescription)")
        }
    }

    func stringArray(_ name: String) throws -> [String] {
        guard case let .array(values)? = params[name] else {
            throw GatewayError.invalidParameters("Missing string array parameter: \(name)")
        }
        return try values.map { value in
            guard let string = value.stringValue else {
                throw GatewayError.invalidParameters("\(name) must contain only strings")
            }
            return string
        }
    }
}

private extension AuthorizationError {
    var rpcError: AutomationRPCError {
        switch self {
        case .authenticationRequired, .clientIdentityChanged:
            AutomationRPCError(
                code: -32040,
                type: "authentication_required",
                message: rpcDescription,
                data: .object(["pairingMethod": .string("auth.pair")])
            )
        case let .scopeRequired(scope):
            AutomationRPCError(
                code: -32041,
                type: "scope_required",
                message: rpcDescription,
                data: .object(["requiredScope": .string(scope.rawValue)])
            )
        default:
            AutomationRPCError(
                code: -32042,
                type: "authorization_failed",
                message: rpcDescription
            )
        }
    }
}

private struct AutomationPage {
    let offset: Int
    let limit: Int
    let total: Int
    let range: Range<Int>

    func object(items: AutomationJSONValue) -> AutomationJSONValue {
        .object([
            "items": items,
            "offset": .integer(Int64(offset)),
            "limit": .integer(Int64(limit)),
            "total": .integer(Int64(total)),
            "hasMore": .bool(range.upperBound < total),
        ])
    }
}

private struct CachedMutation {
    let clientIdentifier: UUID
    let requestDigest: String
    let response: AutomationRPCResponse
    let byteCount: Int
}

private struct MutationCacheContext {
    let key: String
    let clientIdentifier: UUID
    let requestDigest: String
}

private struct CandidateCache {
    let loadedAt: Date
    let value: ApplicationCaptureCandidates
}

private extension AutomationJSONValue {
    func mergingObject(
        _ additional: [String: AutomationJSONValue]
    ) -> AutomationJSONValue {
        guard case var .object(object) = self else { return self }
        additional.forEach { object[$0.key] = $0.value }
        return .object(object)
    }
}

private extension ProfileMetadata {
    var automaticUpdatesEnabled: Bool {
        guard case let .remote(metadata) = origin else { return false }
        return metadata.automaticUpdatesEnabled
    }

    var updateIntervalHours: Int? {
        guard case let .remote(metadata) = origin else { return nil }
        return metadata.updateIntervalHours
    }
}
