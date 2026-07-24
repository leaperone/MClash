import Foundation
import MClashNetworkShared
@testable import MClashApp

/// Command-line tests must never construct the live Network Extension manager
/// graph. On macOS 15, `NEDNSProxyManager.shared()` can surface an opaque null
/// Objective-C wrapper outside an entitled application host.
@MainActor
func makeTestAppModel(
    supervisor: CoreSupervisor = CoreSupervisor(),
    binaryLocator: CoreBinaryLocator = CoreBinaryLocator(),
    secretStore: any CoreSecretProviding = EphemeralCoreSecretProvider(),
    systemProxyManager: SystemProxyManager = SystemProxyManager(),
    localPortProbe: LocalPortProbe = LocalPortProbe(),
    profileDirectoryLayout: ProfileDirectoryLayout? = nil,
    profileStoreOverride: ProfileStore? = nil,
    geoDataInstaller: BundledGeoDataInstaller = .applicationBundle(),
    preferenceDefaults: UserDefaults = .standard,
    networkExtensionControl: any NetworkExtensionControlling =
        InertAppModelNetworkExtensionControl(),
    networkEnvironmentMonitor: any NetworkEnvironmentMonitoring =
        InertAppModelNetworkEnvironmentMonitor()
) -> AppModel {
    AppModel(
        supervisor: supervisor,
        binaryLocator: binaryLocator,
        secretStore: secretStore,
        systemProxyManager: systemProxyManager,
        localPortProbe: localPortProbe,
        profileDirectoryLayout: profileDirectoryLayout,
        profileStoreOverride: profileStoreOverride,
        geoDataInstaller: geoDataInstaller,
        preferenceDefaults: preferenceDefaults,
        networkExtensionControl: networkExtensionControl,
        networkEnvironmentMonitor: networkEnvironmentMonitor
    )
}

private actor InertAppModelNetworkExtensionControl:
    NetworkExtensionControlling
{
    func enable(
        _ configuration: NetworkExtensionRuntimeConfiguration,
        progress reportProgress: @escaping @Sendable (
            NetworkExtensionEnableProgress
        ) -> Void
    ) async throws -> NetworkExtensionEnableOutcome {
        .running
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
private final class InertAppModelNetworkEnvironmentMonitor:
    NetworkEnvironmentMonitoring
{
    func start() -> AsyncStream<NetworkEnvironmentEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func stop() {}
}
