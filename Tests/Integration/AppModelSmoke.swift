import Darwin
import Foundation
import MClashNetworkShared

@main
struct AppModelSmoke {
    @MainActor
    static func main() async throws {
        let repository = URL(filePath: FileManager.default.currentDirectoryPath)
        guard let corePath = ProcessInfo.processInfo.environment["MCLASH_TEST_CORE"] else {
            throw SmokeFailure.corePathMissing
        }
        let coreURL = URL(filePath: corePath)
        let locator = CoreBinaryLocator(
            environment: [:],
            applicationSupportDirectory: repository.appending(path: ".build/unused-core-support"),
            bundledBinaryURLs: [coreURL]
        )
        let stateRoot = FileManager.default.temporaryDirectory.appending(
            path: "mclash-app-smoke-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let layout = ProfileDirectoryLayout(rootDirectory: stateRoot)
        try layout.createDirectories()
        defer { try? FileManager.default.removeItem(at: stateRoot) }

        let preferencesSuiteName = "MClash.AppModelSmoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: preferencesSuiteName) else {
            throw SmokeFailure.preferencesUnavailable
        }
        defaults.set(false, forKey: AppModel.autoEnableSystemProxyKey)
        // This smoke fixture intentionally exercises the legacy profile fleet
        // (including per-profile route listeners). Mark the one-time unified
        // migration as already completed so startup does not auto-adopt this
        // synthetic legacy scenario.
        defaults.set(
            AppModel.unifiedConfigurationMigrationVersion,
            forKey: AppModel.unifiedConfigurationMigrationVersionKey
        )
        defer { defaults.removePersistentDomain(forName: preferencesSuiteName) }

        let appRoutingFixtureURL = stateRoot.appending(
            path: "app-routing-routes.yaml",
            directoryHint: .notDirectory
        )
        try Data(
            """
            mixed-port: 17890
            allow-lan: false
            mode: rule
            log-level: info
            ipv6: false

            proxies:
              - name: Test Node
                type: socks5
                server: 127.0.0.1
                port: 9
            proxy-groups:
              - name: Pinned Node
                type: select
                proxies:
                  - Test Node
                  - DIRECT
              - name: Reject Group
                type: select
                proxies:
                  - REJECT
            sub-rules:
              reject-entry:
                - MATCH,REJECT
            rules:
              - MATCH,DIRECT
            """.utf8
        ).write(to: appRoutingFixtureURL, options: .atomic)

        let profileStore = try ProfileStore(layout: layout)
        let startupProfile = try await profileStore.importProfile(
            from: appRoutingFixtureURL,
            name: "Startup profile"
        )
        let auxiliaryProfile = try await profileStore.importProfile(
            from: appRoutingFixtureURL,
            name: "Auxiliary profile"
        )
        _ = try await profileStore.activateProfile(
            startupProfile.id,
            validator: AcceptingProfileValidator()
        )

        let systemProxyBackend = try IsolatedSystemProxyBackend()
        // This smoke test exercises the mutually exclusive macOS System Proxy
        // path. Persist that explicit opt-out so the new App Routing product
        // default does not attempt to load a real Network Extension manager in
        // this command-line test host.
        _ = try await NetworkCaptureConfigurationStore(
            profileLayout: layout
        ).replaceRules([], enabled: false, dnsEnabled: true)
        let networkExtensionControl = InertNetworkExtensionControl()
        let model = AppModel(
            binaryLocator: locator,
            secretStore: StaticSecretProvider(),
            systemProxyManager: SystemProxyManager(backend: systemProxyBackend),
            profileDirectoryLayout: layout,
            profileStoreOverride: profileStore,
            preferenceDefaults: defaults,
            networkExtensionControl: networkExtensionControl,
            networkEnvironmentMonitor: InertNetworkEnvironmentMonitor()
        )

        do {
            await model.prepare()

            for _ in 0..<30 where !model.isConnected || model.runtimeConfig == nil {
                try await Task.sleep(for: .milliseconds(100))
            }

            let initialMixedPort = model.profileRuntimePlan.defaultMixedPort
            guard model.isConnected,
                  model.runningSession?.version.hasPrefix("alpha-") == true,
                  model.runtimeConfig?.mixedPort == initialMixedPort,
                  model.localHTTPListenerPort == nil,
                  model.localSOCKSListenerPort == nil,
                  model.localMixedListenerPort == initialMixedPort,
                  model.localHTTPProxyPort == initialMixedPort,
                  model.localSOCKSProxyPort == initialMixedPort,
                  model.localListenerEndpoints == [
                      AppModel.LocalListenerEndpoint(
                          kind: .mixed,
                          host: "127.0.0.1",
                          port: initialMixedPort,
                          source: .profile
                      )
                  ],
                  model.systemProxyState == .off else {
                let details = [
                    "state=\(String(describing: model.coreState))",
                    "error=\(model.errorMessage ?? "none")",
                    "runtime=\(model.runtimeConfig?.mixedPort.description ?? "none")",
                    "lastLog=\(model.logs.last?.message ?? "none")"
                ].joined(separator: ", ")
                throw SmokeFailure.didNotConnect(details)
            }

            try verifyProxyProtocols(model: model)
            let stableDefaultMixedPort = model.profileRuntimePlan.defaultMixedPort

            let routePorts = try LocalPortProbe().availableTCPAndUDPPorts(
                count: 6,
                excluding: Set(
                    model.profileRuntimePlan.sessions.map(\.mixedPort)
                        + [model.profileRuntimePlan.defaultMixedPort]
                )
            )
            let routeListeners = [
                ProfileRouteListenerSpec(
                    profileID: startupProfile.id,
                    name: "HTTP Rules",
                    protocolType: .http,
                    port: routePorts[0],
                    target: .profileRules
                ),
                ProfileRouteListenerSpec(
                    profileID: startupProfile.id,
                    name: "SOCKS Direct",
                    protocolType: .socks,
                    port: routePorts[1],
                    target: .proxyNode("DIRECT")
                ),
                ProfileRouteListenerSpec(
                    profileID: startupProfile.id,
                    name: "Mixed Rules",
                    protocolType: .mixed,
                    port: routePorts[2],
                    target: .profileRules
                ),
                ProfileRouteListenerSpec(
                    profileID: startupProfile.id,
                    name: "Sub-rule Reject",
                    protocolType: .http,
                    port: routePorts[3],
                    target: .subRule("reject-entry")
                ),
                ProfileRouteListenerSpec(
                    profileID: startupProfile.id,
                    name: "GLOBAL Reject",
                    protocolType: .http,
                    port: routePorts[4],
                    target: .global
                ),
                ProfileRouteListenerSpec(
                    profileID: startupProfile.id,
                    name: "Policy Reject",
                    protocolType: .http,
                    port: routePorts[5],
                    target: .policyGroup("Reject Group")
                ),
            ]
            for _ in 0..<100 where !model.canPerform(.changeRuntimeSettings) {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard model.canPerform(.changeRuntimeSettings) else {
                throw SmokeFailure.profileRuntimeUpdateStayedBusy(
                    "\(model.operations)"
                )
            }
            let routeApplyOutcome = try await model.applyProfileRouteListeners(
                routeListeners
            )
            guard routeApplyOutcome == .savedAndRestarted,
                  model.isConnected,
                  model.controllerIsReady,
                  model.profileRuntimePlan.routeListeners == routeListeners,
                  model.profileSessionSpec(for: startupProfile.id)?.enabled == true,
                  try await ProfileRuntimePlanStore(layout: layout).load()
                    .routeListeners == routeListeners else {
                throw SmokeFailure.routeListenersDidNotRestart
            }
            try verifyHTTPProxy(port: routePorts[0])
            try verifySOCKSProxy(port: routePorts[1])
            try verifyProxyProtocols(port: routePorts[2])
            try verifyHTTPProxyRejected(port: routePorts[3])
            guard let runningSession = model.runningSession else {
                throw SmokeFailure.appRoutingContinuitySetupFailed(
                    "The primary controller disappeared before GLOBAL verification."
                )
            }
            let primaryClient = try MihomoAPIClient(
                baseURL: runningSession.endpoint,
                secret: runningSession.secret
            )
            try await primaryClient.selectProxy(group: "GLOBAL", proxy: "REJECT")
            try verifyHTTPProxyRejected(port: routePorts[4])
            try verifyHTTPProxyRejected(port: routePorts[5])

            let routePlanBeforeRejectedUpdate = model.profileRuntimePlan
            let routeStartedAtBeforeRejectedUpdate = model.runningSession?.startedAt
            let occupiedRoutePort = try OccupiedIPv6TCPPort()
            var occupiedRouteListeners = routeListeners
            occupiedRouteListeners[0].port = occupiedRoutePort.port
            do {
                _ = try await model.applyProfileRouteListeners(
                    occupiedRouteListeners
                )
                throw SmokeFailure.occupiedRouteListenerPortWasAccepted
            } catch let error as SmokeFailure {
                throw error
            } catch {
                // The candidate must fail before the healthy route listeners
                // or core session are replaced.
            }
            guard model.profileRuntimePlan == routePlanBeforeRejectedUpdate,
                  model.runningSession?.startedAt
                    == routeStartedAtBeforeRejectedUpdate else {
                throw SmokeFailure.routeListenerRollbackFailed
            }
            try verifyHTTPProxy(port: routePorts[0])
            try verifySOCKSProxy(port: routePorts[1])

            var invalidTargetListeners = routeListeners
            invalidTargetListeners[1].target = .proxyNode("Missing Provider Node")
            do {
                _ = try await model.applyProfileRouteListeners(
                    invalidTargetListeners
                )
                throw SmokeFailure.invalidRouteListenerTargetWasAccepted
            } catch let error as SmokeFailure {
                throw error
            } catch {
                // Target validation must reject the candidate transaction.
            }
            guard model.profileRuntimePlan == routePlanBeforeRejectedUpdate,
                  model.runningSession?.startedAt
                    == routeStartedAtBeforeRejectedUpdate else {
                throw SmokeFailure.routeListenerRollbackFailed
            }
            try verifySOCKSProxy(port: routePorts[1])

            let auxiliaryMixedPort = try LocalPortProbe()
                .availableTCPAndUDPPorts(count: 1)[0]
            for _ in 0..<100
            where !model.canPerform(.updateProfile(auxiliaryProfile.id)) {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard model.canPerform(.updateProfile(auxiliaryProfile.id)) else {
                throw SmokeFailure.profileRuntimeUpdateStayedBusy(
                    "\(model.operations)"
                )
            }
            try await model.updateProfileRuntime(
                profileID: auxiliaryProfile.id,
                enabled: true,
                mixedPort: auxiliaryMixedPort
            )
            for _ in 0..<100 {
                if case .running = model.auxiliaryCoreStates[auxiliaryProfile.id] {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard case .running = model.auxiliaryCoreStates[auxiliaryProfile.id] else {
                throw SmokeFailure.auxiliaryProfileDidNotStart
            }
            try verifyProxyProtocols(port: auxiliaryMixedPort)

            // App Routing rule mutations must not use the disconnect path as a
            // configuration mechanism. A new route can require a listener
            // update on one profile, but it must not stop the primary core or
            // every unrelated auxiliary core. Deleting or disabling the last
            // reference to a route can safely retain the private listener as a
            // superset and should not stop any core at all.
            let baselineRule = try CaptureRule(
                id: "continuity-baseline",
                priority: 10,
                action: .mihomo(.profileRules)
            )
            try await model.applyNetworkCaptureRules(
                [baselineRule],
                enabled: true,
                dnsEnabled: false
            )
            guard case .on = model.networkCaptureState,
                  model.isConnected,
                  model.controllerIsReady else {
                throw SmokeFailure.appRoutingContinuitySetupFailed(
                    model.errorMessage ?? "App Routing did not become ready."
                )
            }
            guard let profileRulesEndpoint = await networkExtensionControl
                .routeEndpoint(.profileRules),
                let smokeURLString = ProcessInfo.processInfo.environment[
                    "MCLASH_PROXY_SMOKE_URL"
                ],
                let smokeURL = URL(string: smokeURLString) else {
                throw SmokeFailure.appRoutingContinuitySetupFailed(
                    "The private profile-rules endpoint was not published."
                )
            }
            let persistentRelay = try PersistentAuthenticatedSOCKSTunnel(
                endpoint: profileRulesEndpoint,
                target: smokeURL
            )

            var continuityFailures: [String] = []
            let groupRule = try CaptureRule(
                id: "continuity-first-node-group",
                priority: 20,
                action: .mihomo(.group("Pinned Node"))
            )
            let beforeFirstGroup = coreContinuitySnapshot(
                model: model,
                auxiliaryProfileID: auxiliaryProfile.id
            )
            try await model.applyNetworkCaptureRules(
                [baselineRule, groupRule],
                enabled: true,
                dnsEnabled: false
            )
            recordUnexpectedCoreStops(
                operation: "adding the first node-backed group route",
                before: beforeFirstGroup,
                after: coreContinuitySnapshot(
                    model: model,
                    auxiliaryProfileID: auxiliaryProfile.id
                ),
                requireAuxiliaryContinuity: true,
                into: &continuityFailures
            )
            try persistentRelay.verifyHTTPResponse()

            let beforeLastGroupDeletion = coreContinuitySnapshot(
                model: model,
                auxiliaryProfileID: auxiliaryProfile.id
            )
            try await model.applyNetworkCaptureRules(
                [baselineRule],
                enabled: true,
                dnsEnabled: false
            )
            recordUnexpectedCoreStops(
                operation: "deleting the last node-backed group route",
                before: beforeLastGroupDeletion,
                after: coreContinuitySnapshot(
                    model: model,
                    auxiliaryProfileID: auxiliaryProfile.id
                ),
                requireAuxiliaryContinuity: true,
                into: &continuityFailures
            )

            // Re-add the route to establish the precondition for the distinct
            // enabled -> disabled regression. Its own continuity is covered by
            // the first-add assertion above.
            try await model.applyNetworkCaptureRules(
                [baselineRule, groupRule],
                enabled: true,
                dnsEnabled: false
            )
            let disabledGroupRule = try CaptureRule(
                id: groupRule.id,
                enabled: false,
                priority: groupRule.priority,
                sources: groupRule.sources,
                destinations: groupRule.destinations,
                protocols: groupRule.protocols,
                portRanges: groupRule.portRanges,
                action: groupRule.action,
                unavailableFallback: groupRule.unavailableFallback
            )
            let beforeLastGroupDisable = coreContinuitySnapshot(
                model: model,
                auxiliaryProfileID: auxiliaryProfile.id
            )
            try await model.applyNetworkCaptureRules(
                [baselineRule, disabledGroupRule],
                enabled: true,
                dnsEnabled: false
            )
            recordUnexpectedCoreStops(
                operation: "disabling the last node-backed group route",
                before: beforeLastGroupDisable,
                after: coreContinuitySnapshot(
                    model: model,
                    auxiliaryProfileID: auxiliaryProfile.id
                ),
                requireAuxiliaryContinuity: true,
                into: &continuityFailures
            )

            let failedLiveRule = try CaptureRule(
                id: "continuity-failed-live-route",
                priority: 25,
                action: .mihomo(.global)
            )
            let rulesBeforeFailedLiveUpdate = model.networkCapturePreferences
                .snapshot.rules
            let beforeFailedLiveUpdate = coreContinuitySnapshot(
                model: model,
                auxiliaryProfileID: auxiliaryProfile.id
            )
            await networkExtensionControl.failNextRuntimeUpdate()
            do {
                try await model.applyNetworkCaptureRules(
                    [baselineRule, disabledGroupRule, failedLiveRule],
                    enabled: true,
                    dnsEnabled: false
                )
                throw SmokeFailure.failedLiveRouteWasAccepted
            } catch let error as SmokeFailure {
                throw error
            } catch {
                // The provider rejects one candidate revision; AppModel must
                // restore the previous rules through a newer live revision.
            }
            recordUnexpectedCoreStops(
                operation: "rolling back a rejected live route update",
                before: beforeFailedLiveUpdate,
                after: coreContinuitySnapshot(
                    model: model,
                    auxiliaryProfileID: auxiliaryProfile.id
                ),
                requireAuxiliaryContinuity: true,
                into: &continuityFailures
            )
            guard model.networkCapturePreferences.snapshot.rules
                    == rulesBeforeFailedLiveUpdate,
                  case .on = model.networkCaptureState else {
                throw SmokeFailure.liveRouteRollbackFailed
            }

            let auxiliaryRoute = MihomoRoute.profile(
                RoutingProfileID(auxiliaryProfile.id.rawValue),
                target: .rules
            )
            let auxiliaryProfileRule = try CaptureRule(
                id: "continuity-first-profile-route",
                priority: 30,
                action: .mihomo(auxiliaryRoute)
            )
            let beforeFirstProfileRoute = coreContinuitySnapshot(
                model: model,
                auxiliaryProfileID: auxiliaryProfile.id
            )
            try await model.applyNetworkCaptureRules(
                [baselineRule, disabledGroupRule, auxiliaryProfileRule],
                enabled: true,
                dnsEnabled: false
            )
            recordUnexpectedCoreStops(
                operation: "adding the first auxiliary-profile route",
                before: beforeFirstProfileRoute,
                after: coreContinuitySnapshot(
                    model: model,
                    auxiliaryProfileID: auxiliaryProfile.id
                ),
                // The affected auxiliary profile must reload its listener in
                // place; neither it nor the primary core may restart.
                requireAuxiliaryContinuity: true,
                into: &continuityFailures
            )
            guard let auxiliaryRouteEndpoint = await networkExtensionControl
                .routeEndpoint(auxiliaryRoute) else {
                throw SmokeFailure.appRoutingContinuitySetupFailed(
                    "The auxiliary private route endpoint was not published."
                )
            }
            let persistentAuxiliaryRelay = try PersistentAuthenticatedSOCKSTunnel(
                endpoint: auxiliaryRouteEndpoint,
                target: smokeURL
            )

            let beforeLastAuxiliaryRouteDeletion = coreContinuitySnapshot(
                model: model,
                auxiliaryProfileID: auxiliaryProfile.id
            )
            try await model.applyNetworkCaptureRules(
                [baselineRule],
                enabled: true,
                dnsEnabled: false
            )
            recordUnexpectedCoreStops(
                operation: "deleting the last auxiliary-profile route",
                before: beforeLastAuxiliaryRouteDeletion,
                after: coreContinuitySnapshot(
                    model: model,
                    auxiliaryProfileID: auxiliaryProfile.id
                ),
                requireAuxiliaryContinuity: true,
                into: &continuityFailures
            )
            try persistentAuxiliaryRelay.verifyHTTPResponse()
            guard await networkExtensionControl.routeEndpoint(auxiliaryRoute)
                    == auxiliaryRouteEndpoint else {
                throw SmokeFailure.liveRouteRollbackFailed
            }

            try await model.applyNetworkCaptureRules(
                [baselineRule],
                enabled: false,
                dnsEnabled: false
            )
            guard model.networkCaptureState == .off else {
                throw SmokeFailure.appRoutingContinuitySetupFailed(
                    "App Routing did not turn off after continuity checks."
                )
            }
            if !continuityFailures.isEmpty {
                throw SmokeFailure.appRoutingRuleChangeRestartedCores(
                    continuityFailures.joined(separator: " | ")
                )
            }

            let occupiedAuxiliaryPort = try OccupiedIPv6TCPPort()
            let auxiliaryStateBeforeRejectedUpdate =
                model.auxiliaryCoreStates[auxiliaryProfile.id]
            do {
                try await model.updateProfileRuntime(
                    profileID: auxiliaryProfile.id,
                    enabled: true,
                    mixedPort: occupiedAuxiliaryPort.port
                )
                throw SmokeFailure.occupiedAuxiliaryRuntimePortWasAccepted
            } catch let error as SmokeFailure {
                throw error
            } catch {
                // The occupied candidate must be rejected before reconcile
                // stops or replaces the healthy session on its old port.
            }
            guard model.profileSessionSpec(for: auxiliaryProfile.id)?.mixedPort
                    == auxiliaryMixedPort,
                  case .running = model.auxiliaryCoreStates[auxiliaryProfile.id],
                  model.auxiliaryCoreStates[auxiliaryProfile.id]
                    == auxiliaryStateBeforeRejectedUpdate else {
                throw SmokeFailure.auxiliaryRuntimePortRollbackFailed
            }
            try verifyProxyProtocols(port: auxiliaryMixedPort)

            try await model.updateProfileRuntime(
                profileID: auxiliaryProfile.id,
                enabled: false,
                mixedPort: auxiliaryMixedPort
            )
            for _ in 0..<100 {
                if case .running = model.auxiliaryCoreStates[auxiliaryProfile.id] {
                    try await Task.sleep(for: .milliseconds(50))
                } else {
                    break
                }
            }
            guard model.profileSessionSpec(for: auxiliaryProfile.id)?.enabled == false,
                  !LocalPortProbe().isListening(port: auxiliaryMixedPort) else {
                throw SmokeFailure.auxiliaryProfileDidNotStop
            }

            // A Profile whose dedicated port is closed can still become the
            // source of the virtual Default Profile. The stable Default port
            // stays open while that real Profile's own port remains closed.
            try await model.activateProfile(auxiliaryProfile.id)
            guard model.activeProfileID == auxiliaryProfile.id,
                  model.profileRuntimePlan.primaryProfileID == auxiliaryProfile.id,
                  model.profileSessionSpec(for: auxiliaryProfile.id)?.enabled == false,
                  model.isConnected,
                  model.localMixedListenerPort == stableDefaultMixedPort,
                  !LocalPortProbe().isListening(port: auxiliaryMixedPort) else {
                throw SmokeFailure.disabledProfileDidNotBecomeDefault
            }
            try verifyProxyProtocols(model: model)

            for _ in 0..<100 where !model.canPerform(.changeSystemProxy) {
                try await Task.sleep(for: .milliseconds(50))
            }
            await model.enableSystemProxy()
            guard model.systemProxyState == .on,
                  systemProxyBackend.applyCount == 1,
                  model.runningSession?.startedAt != nil else {
                throw SmokeFailure.isolatedSystemProxyDidNotEnable(
                    "state=\(model.systemProxyState), "
                        + "applyCount=\(systemProxyBackend.applyCount), "
                        + "canChange=\(model.canPerform(.changeSystemProxy)), "
                        + "preparing=\(model.preparationInProgress), "
                        + "operations=\(model.operations), "
                        + "error=\(model.errorMessage ?? "none")"
                )
            }

            let requestedMixedPort = try LocalPortProbe().availableTCPPort()
            let runtimeApplyOutcome = try await model.applyRuntimeOverrides(
                RuntimeOverrides(
                    ports: RuntimePortOverrides(mixedPort: requestedMixedPort)
                )
            )
            guard runtimeApplyOutcome == .savedAndRestarted,
                  model.runtimeSettingsApplyState == .completed(.savedAndRestarted),
                  model.isConnected,
                  model.controllerIsReady,
                  model.systemProxyState == .on,
                  model.localMixedListenerPort == requestedMixedPort,
                  model.localHTTPProxyPort == requestedMixedPort,
                  model.localSOCKSProxyPort == requestedMixedPort,
                  model.localListenerEndpoints.first?.source == .override,
                  let successfulSettingsStartedAt = model.runningSession?.startedAt else {
                throw SmokeFailure.runtimeSettingsDidNotRestart(
                    model.errorMessage ?? "No additional error was reported."
                )
            }

            let unchangedOutcome = try await model.applyRuntimeOverrides(model.runtimeOverrides)
            guard unchangedOutcome == .unchanged,
                  model.runtimeSettingsApplyState == .completed(.unchanged),
                  model.runningSession?.startedAt == successfulSettingsStartedAt else {
                throw SmokeFailure.unchangedRuntimeSettingsRestarted
            }

            let previousOverrides = model.runtimeOverrides
            let previousRuntime = try Data(contentsOf: layout.runtimeConfigurationURL)
            let occupiedPort = try OccupiedTCPPort()
            do {
                _ = try await model.applyRuntimeOverrides(
                    RuntimeOverrides(
                        ports: RuntimePortOverrides(mixedPort: occupiedPort.port)
                    )
                )
                throw SmokeFailure.occupiedRuntimePortWasAccepted
            } catch let error as SmokeFailure {
                throw error
            } catch {
                // Port ownership must fail before the healthy core is
                // replaced, leaving every durable and live surface unchanged.
            }
            let persistedOverrides = try await RuntimeOverrideStore(profileLayout: layout).load()
            guard model.runtimeOverrides == previousOverrides,
                  persistedOverrides == previousOverrides,
                  try Data(contentsOf: layout.runtimeConfigurationURL) == previousRuntime,
                  model.isConnected,
                  model.controllerIsReady,
                  model.systemProxyState == .on,
                  model.localMixedListenerPort == requestedMixedPort,
                  case .failed = model.runtimeSettingsApplyState,
                  let startedAt = model.runningSession?.startedAt,
                  startedAt == successfulSettingsStartedAt else {
                throw SmokeFailure.runtimeSettingsRollbackFailed(
                    [
                        "error=\(model.errorMessage ?? "none")",
                        "state=\(model.runtimeSettingsApplyState)",
                        "connected=\(model.isConnected)",
                        "controller=\(model.controllerIsReady)",
                        "systemProxy=\(model.systemProxyState)",
                        "mixed=\(model.localMixedListenerPort?.description ?? "none")",
                        "startedAt=\(model.runningSession?.startedAt.description ?? "none")",
                        "expectedStartedAt=\(successfulSettingsStartedAt)",
                        "modelOverrides=\(model.runtimeOverrides == previousOverrides)",
                        "storedOverrides=\(persistedOverrides == previousOverrides)",
                        "runtimeBytes=\((try? Data(contentsOf: layout.runtimeConfigurationURL)) == previousRuntime)",
                    ].joined(separator: ", ")
                )
            }

            let corePID = try processID(containing: layout.rootDirectory.path)
            guard Darwin.kill(corePID, SIGKILL) == 0 else {
                throw SmokeFailure.coreTerminationFailed(errno)
            }

            for _ in 0..<180 {
                if model.isConnected,
                   model.controllerIsReady,
                   model.systemProxyState == .on,
                   model.runningSession?.startedAt != startedAt,
                   systemProxyBackend.applyCount >= 3 {
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }

            guard model.isConnected,
                  model.controllerIsReady,
                  model.systemProxyState == .on,
                  model.runningSession?.startedAt != startedAt,
                  systemProxyBackend.applyCount >= 3 else {
                throw SmokeFailure.crashRecoveryDidNotRestoreSystemProxy(
                    model.errorMessage ?? "No additional error was reported."
                )
            }

            try verifyProxyProtocols(model: model)

            await model.disconnect()
            guard !model.isConnected else { throw SmokeFailure.didNotDisconnect }

            _ = try await model.resetRuntimeOverrides()

            _ = try await model.importProfile(
                data: Data(
                    contentsOf: repository.appending(
                        path: "Tests/Fixtures/no-listener.yaml"
                    )
                ),
                suggestedFileName: "no-listener.yaml",
                activate: true
            )
            await model.connect()

            guard model.isConnected,
                  model.controllerIsReady,
                  let managedPort = model.runtimeConfig?.mixedPort,
                  managedPort > 0,
                  model.localMixedListenerPort == managedPort,
                  model.localHTTPProxyPort == managedPort,
                  model.localSOCKSProxyPort == managedPort,
                  model.localListenerEndpoints.first(where: { $0.kind == .mixed })?.source
                    == .managedFallback,
                  model.systemProxyState == .off else {
                throw SmokeFailure.runtimeListenerWasNotCreated(
                    model.errorMessage ?? "No additional error was reported."
                )
            }

            try verifyProxyProtocols(model: model)

            let finalMixedPort = model.localMixedListenerPort
            guard await model.shutdown() else {
                throw SmokeFailure.gracefulShutdownFailed
            }
            guard try processIDs(containing: layout.rootDirectory.path).isEmpty else {
                throw SmokeFailure.gracefulShutdownLeftCoreProcesses
            }
            guard !LocalPortProbe().isListening(port: auxiliaryMixedPort),
                  routePorts.allSatisfy({
                      !LocalPortProbe().isListening(port: $0)
                  }),
                  finalMixedPort.map({
                      !LocalPortProbe().isListening(port: $0)
                  }) ?? true else {
                throw SmokeFailure.gracefulShutdownLeftPortsOccupied
            }

            print("App model dual-profile, HTTP/SOCKS, runtime-listener, crash-recovery, and graceful-shutdown smoke passed")
        } catch {
            await model.shutdown()
            throw error
        }
    }

    @MainActor
    private static func verifyProxyProtocols(model: AppModel) throws {
        guard let target = ProcessInfo.processInfo.environment["MCLASH_PROXY_SMOKE_URL"],
              let httpPort = model.localHTTPProxyPort,
              let socksPort = model.localSOCKSProxyPort else {
            throw SmokeFailure.proxyTestConfigurationUnavailable
        }

        try verifyProxyProtocols(port: httpPort, socksPort: socksPort, target: target)
    }

    private static func verifyProxyProtocols(port: Int) throws {
        guard let target = ProcessInfo.processInfo.environment["MCLASH_PROXY_SMOKE_URL"] else {
            throw SmokeFailure.proxyTestConfigurationUnavailable
        }
        try verifyProxyProtocols(port: port, socksPort: port, target: target)
    }

    private static func verifyHTTPProxy(port: Int) throws {
        guard let target = ProcessInfo.processInfo.environment["MCLASH_PROXY_SMOKE_URL"] else {
            throw SmokeFailure.proxyTestConfigurationUnavailable
        }
        try runCurl([
            "--noproxy", "", "--fail", "--silent", "--show-error", "--max-time", "10",
            "--proxy", "http://127.0.0.1:\(port)", target
        ])
    }

    private static func verifySOCKSProxy(port: Int) throws {
        guard let target = ProcessInfo.processInfo.environment["MCLASH_PROXY_SMOKE_URL"] else {
            throw SmokeFailure.proxyTestConfigurationUnavailable
        }
        try runCurl([
            "--noproxy", "", "--fail", "--silent", "--show-error", "--max-time", "10",
            "--socks5-hostname", "127.0.0.1:\(port)", target
        ])
    }

    private static func verifyHTTPProxyRejected(port: Int) throws {
        guard let target = ProcessInfo.processInfo.environment["MCLASH_PROXY_SMOKE_URL"] else {
            throw SmokeFailure.proxyTestConfigurationUnavailable
        }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/curl")
        process.arguments = [
            "--noproxy", "", "--fail", "--silent", "--show-error",
            "--max-time", "5", "--proxy", "http://127.0.0.1:\(port)", target,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else {
            throw SmokeFailure.proxyRequestWasNotRejected
        }
    }

    private static func verifyProxyProtocols(
        port: Int,
        socksPort: Int,
        target: String
    ) throws {
        try runCurl([
            "--noproxy", "", "--fail", "--silent", "--show-error", "--max-time", "10",
            "--proxy", "http://127.0.0.1:\(port)", target
        ])
        try runCurl([
            "--noproxy", "", "--fail", "--silent", "--show-error", "--max-time", "10",
            "--socks5-hostname", "127.0.0.1:\(socksPort)", target
        ])
    }

    private static func runCurl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/curl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SmokeFailure.proxyRequestFailed(process.terminationStatus)
        }
    }

    private static func processID(containing marker: String) throws -> pid_t {
        guard let first = try processIDs(containing: marker).first else {
            throw SmokeFailure.coreProcessNotFound
        }
        return first
    }

    private static func processIDs(containing marker: String) throws -> [pid_t] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/pgrep")
        process.arguments = ["-f", marker]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let values = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) }
            .filter { $0 != getpid() }
        return values
    }

    @MainActor
    private static func coreContinuitySnapshot(
        model: AppModel,
        auxiliaryProfileID: ProfileID
    ) -> CoreContinuitySnapshot {
        CoreContinuitySnapshot(
            primaryStartedAt: model.runningSession?.startedAt,
            auxiliaryStartedAt: runningStartedAt(
                model.auxiliaryCoreStates[auxiliaryProfileID]
            )
        )
    }

    private static func runningStartedAt(_ state: CoreRunState?) -> Date? {
        guard case let .running(session)? = state else { return nil }
        return session.startedAt
    }

    private static func recordUnexpectedCoreStops(
        operation: String,
        before: CoreContinuitySnapshot,
        after: CoreContinuitySnapshot,
        requireAuxiliaryContinuity: Bool,
        into failures: inout [String]
    ) {
        if before.primaryStartedAt == nil
            || after.primaryStartedAt != before.primaryStartedAt {
            failures.append(
                "\(operation) restarted or stopped the primary core "
                    + "(before=\(before.primaryStartedAt?.description ?? "none"), "
                    + "after=\(after.primaryStartedAt?.description ?? "none"))"
            )
        }
        if requireAuxiliaryContinuity,
           (before.auxiliaryStartedAt == nil
                || after.auxiliaryStartedAt != before.auxiliaryStartedAt) {
            failures.append(
                "\(operation) restarted or stopped an unrelated auxiliary core "
                    + "(before=\(before.auxiliaryStartedAt?.description ?? "none"), "
                    + "after=\(after.auxiliaryStartedAt?.description ?? "none"))"
            )
        }
    }
}

private final class PersistentAuthenticatedSOCKSTunnel {
    private let descriptor: Int32
    private let target: URL

    init(endpoint: MihomoRouteProxyEndpoint, target: URL) throws {
        guard endpoint.host == "127.0.0.1",
              let username = endpoint.username,
              let password = endpoint.password,
              target.host == "127.0.0.1",
              let targetPort = target.port,
              (1...65_535).contains(targetPort)
        else {
            throw SmokeFailure.persistentAppRoutingRelayDisconnected
        }
        self.target = target

        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw SmokeFailure.persistentAppRoutingRelayDisconnected
        }
        descriptor = socketDescriptor
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            Darwin.setsockopt(
                socketDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(
                socketDescriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(
                socketDescriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = endpoint.port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        } == 0
        guard connected,
              Self.send(Data([0x05, 0x01, 0x02]), to: socketDescriptor),
              Self.receive(count: 2, from: socketDescriptor) == [0x05, 0x02]
        else {
            Darwin.close(socketDescriptor)
            throw SmokeFailure.persistentAppRoutingRelayDisconnected
        }

        let usernameBytes = Array(username.utf8)
        let passwordBytes = Array(password.utf8)
        var authentication = Data([0x01, UInt8(usernameBytes.count)])
        authentication.append(contentsOf: usernameBytes)
        authentication.append(UInt8(passwordBytes.count))
        authentication.append(contentsOf: passwordBytes)
        guard Self.send(authentication, to: socketDescriptor),
              Self.receive(count: 2, from: socketDescriptor) == [0x01, 0x00]
        else {
            Darwin.close(socketDescriptor)
            throw SmokeFailure.persistentAppRoutingRelayDisconnected
        }

        let highPort = UInt8((targetPort >> 8) & 0xff)
        let lowPort = UInt8(targetPort & 0xff)
        let connectRequest = Data([
            0x05, 0x01, 0x00, 0x01,
            127, 0, 0, 1,
            highPort, lowPort,
        ])
        guard Self.send(connectRequest, to: socketDescriptor),
              let responsePrefix = Self.receive(count: 4, from: socketDescriptor),
              responsePrefix[0] == 0x05,
              responsePrefix[1] == 0x00,
              let remainderCount = Self.socksAddressRemainderCount(
                  addressType: responsePrefix[3],
                  descriptor: socketDescriptor
              ),
              Self.receive(count: remainderCount, from: socketDescriptor) != nil
        else {
            Darwin.close(socketDescriptor)
            throw SmokeFailure.persistentAppRoutingRelayDisconnected
        }
    }

    deinit {
        Darwin.close(descriptor)
    }

    func verifyHTTPResponse() throws {
        let path = target.path.isEmpty ? "/" : target.path
        let request = Data(
            "GET \(path) HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8
        )
        guard Self.send(request, to: descriptor) else {
            throw SmokeFailure.persistentAppRoutingRelayDisconnected
        }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while response.count < 64 * 1_024 {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            if count == 0 { break }
            guard count > 0 else {
                throw SmokeFailure.persistentAppRoutingRelayDisconnected
            }
            response.append(contentsOf: buffer.prefix(count))
        }
        let text = String(decoding: response, as: UTF8.self)
        guard text.hasPrefix("HTTP/1.0 200")
                || text.hasPrefix("HTTP/1.1 200") else {
            throw SmokeFailure.persistentAppRoutingRelayDisconnected
        }
    }

    private static func socksAddressRemainderCount(
        addressType: UInt8,
        descriptor: Int32
    ) -> Int? {
        switch addressType {
        case 0x01: return 4 + 2
        case 0x04: return 16 + 2
        case 0x03:
            guard let length = receive(count: 1, from: descriptor)?.first else {
                return nil
            }
            return Int(length) + 2
        default:
            return nil
        }
    }

    private static func send(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            return Darwin.send(descriptor, baseAddress, buffer.count, 0)
                == buffer.count
        }
    }

    private static func receive(count: Int, from descriptor: Int32) -> [UInt8]? {
        var result: [UInt8] = []
        while result.count < count {
            var buffer = [UInt8](repeating: 0, count: count - result.count)
            let received = buffer.withUnsafeMutableBytes {
                Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
            }
            guard received > 0 else { return nil }
            result.append(contentsOf: buffer.prefix(received))
        }
        return result
    }
}

private struct CoreContinuitySnapshot {
    let primaryStartedAt: Date?
    let auxiliaryStartedAt: Date?
}

/// The command-line integration host is not an entitled container for the
/// system Network Extension. Startup still exercises the production cold-host
/// cleanup call, while this inert boundary makes that cleanup deterministic
/// instead of asking NetworkExtension.framework to load user preferences.
private actor InertNetworkExtensionControl: NetworkExtensionControlling {
    private var shouldFailNextRuntimeUpdate = false
    private var latestConfiguration: NetworkExtensionRuntimeConfiguration?

    func enable(
        _ configuration: NetworkExtensionRuntimeConfiguration,
        progress reportProgress: @escaping @Sendable (
            NetworkExtensionEnableProgress
        ) -> Void
    ) async throws -> NetworkExtensionEnableOutcome {
        latestConfiguration = configuration
        return .running
    }

    func updateRuntimeConfiguration(
        _ configuration: NetworkExtensionRuntimeConfiguration
    ) async throws -> NetworkExtensionEnableOutcome {
        if shouldFailNextRuntimeUpdate {
            shouldFailNextRuntimeUpdate = false
            throw URLError(.cannotConnectToHost)
        }
        latestConfiguration = configuration
        return .running
    }

    func failNextRuntimeUpdate() {
        shouldFailNextRuntimeUpdate = true
    }

    func routeEndpoint(_ route: MihomoRoute) -> MihomoRouteProxyEndpoint? {
        guard let data = latestConfiguration?.encodedOutboundConnectorCatalog,
              let endpoints = try? MihomoRouteProxyCatalog.decode(data)
        else { return nil }
        return MihomoRouteProxyCatalog.endpoint(for: route, in: endpoints)
    }

    func disable() async throws {}

    func uninstall() async throws -> NetworkExtensionUninstallOutcome {
        .uninstalled
    }

    func currentState() async -> NetworkExtensionControlState {
        .inactive
    }

    func providerRuntimeStatus() async throws -> TransparentProxyProviderStatus {
        throw URLError(.unsupportedURL)
    }

    func appRoutingActivity(
        after cursor: UInt64,
        limit: Int
    ) async throws -> AppRoutingActivityBatch {
        AppRoutingActivityBatch(
            activities: [],
            nextCursor: cursor,
            droppedBeforeSequence: nil,
            hasMore: false
        )
    }

    func clearAppRoutingActivity() async throws {}
}

@MainActor
private final class InertNetworkEnvironmentMonitor: NetworkEnvironmentMonitoring {
    func start() -> AsyncStream<NetworkEnvironmentEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func stop() {}
}

private enum SmokeFailure: Error {
    case corePathMissing
    case didNotConnect(String)
    case didNotDisconnect
    case preferencesUnavailable
    case runtimeListenerWasNotCreated(String)
    case proxyTestConfigurationUnavailable
    case proxyRequestFailed(Int32)
    case isolatedSystemProxyDidNotEnable(String)
    case runtimeSettingsDidNotRestart(String)
    case unchangedRuntimeSettingsRestarted
    case occupiedRuntimePortWasAccepted
    case runtimeSettingsRollbackFailed(String)
    case coreProcessNotFound
    case coreTerminationFailed(Int32)
    case crashRecoveryDidNotRestoreSystemProxy(String)
    case auxiliaryProfileDidNotStart
    case auxiliaryProfileDidNotStop
    case disabledProfileDidNotBecomeDefault
    case occupiedAuxiliaryRuntimePortWasAccepted
    case auxiliaryRuntimePortRollbackFailed
    case profileRuntimeUpdateStayedBusy(String)
    case routeListenersDidNotRestart
    case occupiedRouteListenerPortWasAccepted
    case invalidRouteListenerTargetWasAccepted
    case routeListenerRollbackFailed
    case proxyRequestWasNotRejected
    case failedLiveRouteWasAccepted
    case liveRouteRollbackFailed
    case persistentAppRoutingRelayDisconnected
    case appRoutingContinuitySetupFailed(String)
    case appRoutingRuleChangeRestartedCores(String)
    case gracefulShutdownFailed
    case gracefulShutdownLeftCoreProcesses
    case gracefulShutdownLeftPortsOccupied
}

private final class OccupiedIPv6TCPPort {
    let descriptor: Int32
    let port: Int

    init() throws {
        let socketDescriptor = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw SmokeFailure.coreTerminationFailed(errno)
        }

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = 0
        address.sin6_addr = in6addr_loopback
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in6>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(socketDescriptor, 128) == 0 else {
            Darwin.close(socketDescriptor)
            throw SmokeFailure.coreTerminationFailed(errno)
        }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let lookupResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socketDescriptor, $0, &addressLength)
            }
        }
        guard lookupResult == 0 else {
            Darwin.close(socketDescriptor)
            throw SmokeFailure.coreTerminationFailed(errno)
        }
        descriptor = socketDescriptor
        port = Int(UInt16(bigEndian: address.sin6_port))
    }

    deinit {
        Darwin.close(descriptor)
    }
}

private final class OccupiedTCPPort {
    let descriptor: Int32
    let port: Int

    init() throws {
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw SmokeFailure.coreTerminationFailed(errno) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0, Darwin.listen(socketDescriptor, 128) == 0 else {
            Darwin.close(socketDescriptor)
            throw SmokeFailure.coreTerminationFailed(errno)
        }

        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let lookupResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socketDescriptor, $0, &addressLength)
            }
        }
        guard lookupResult == 0 else {
            Darwin.close(socketDescriptor)
            throw SmokeFailure.coreTerminationFailed(errno)
        }
        descriptor = socketDescriptor
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    deinit {
        Darwin.close(descriptor)
    }
}

private struct StaticSecretProvider: CoreSecretProviding {
    func loadOrCreate() throws -> String {
        "app-model-smoke-secret"
    }
}

private final class IsolatedSystemProxyBackend: SystemProxyBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let service = SystemProxyNetworkService(id: "isolated", name: "Integration")
    private var currentState: SystemProxyServiceState
    private var storedApplyCount = 0

    init() throws {
        currentState = try SystemProxyServiceState(
            service: service,
            protocolExists: true,
            configuration: [
                SystemProxyKeys.httpEnable: .integer(0),
                SystemProxyKeys.httpsEnable: .integer(0),
                SystemProxyKeys.socksEnable: .integer(0)
            ]
        )
    }

    var applyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedApplyCount
    }

    func enabledNetworkServices() throws -> [SystemProxyNetworkService] { [service] }

    func proxyStates(
        for services: [SystemProxyNetworkService]
    ) throws -> [SystemProxyServiceState] {
        lock.lock()
        defer { lock.unlock() }
        return try services.map { requested in
            guard requested == service else {
                throw SystemProxyError.serviceNotFound(requested.id)
            }
            return currentState
        }
    }

    func applyProxyStates(_ states: [SystemProxyServiceState]) throws {
        guard let state = states.first, states.count == 1 else {
            throw SystemProxyError.applyFailed
        }
        lock.lock()
        currentState = state
        storedApplyCount += 1
        lock.unlock()
    }
}
