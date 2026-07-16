import Foundation

/// Serializes snapshot, apply, restore, and persistence operations across concurrent callers.
public actor SystemProxyManager {
    private let backend: any SystemProxyBackend

    public init(backend: any SystemProxyBackend) {
        self.backend = backend
    }

    #if os(macOS)
    public init() {
        self.backend = SystemConfigurationProxyBackend()
    }
    #endif

    public func enabledNetworkServices() throws -> [SystemProxyNetworkService] {
        try backend.enabledNetworkServices()
    }

    public func captureSnapshot(at date: Date = Date()) throws -> SystemProxySnapshot {
        let services = try backend.enabledNetworkServices()
        let states = try backend.proxyStates(for: services)
        return SystemProxySnapshot(capturedAt: date, services: states)
    }

    /// Captures the exact previous state, optionally saves it, and then applies local proxies.
    @discardableResult
    public func activate(
        endpoints: LocalSystemProxyEndpoints,
        savingSnapshotTo snapshotURL: URL? = nil
    ) throws -> SystemProxySnapshot {
        let snapshot = try captureSnapshot()
        if let snapshotURL {
            try save(snapshot: snapshot, to: snapshotURL)
        }
        try apply(endpoints: endpoints, to: snapshot.services)
        return snapshot
    }

    /// Applies endpoints to all network services that are enabled at call time.
    public func apply(endpoints: LocalSystemProxyEndpoints) throws {
        let services = try backend.enabledNetworkServices()
        let currentStates = try backend.proxyStates(for: services)
        try apply(endpoints: endpoints, to: currentStates)
    }

    /// Restores every captured dictionary verbatim, including a missing proxy protocol.
    public func restore(snapshot: SystemProxySnapshot) throws {
        guard snapshot.formatVersion == SystemProxySnapshot.currentFormatVersion else {
            throw SystemProxyError.unsupportedSnapshotVersion(snapshot.formatVersion)
        }
        try backend.applyProxyStates(snapshot.services)
    }

    public func restoreSnapshot(from url: URL) throws {
        try restore(snapshot: loadSnapshot(from: url))
    }

    /// Restores and removes a persisted snapshot as one serialized manager operation.
    public func restoreSnapshotAndRemove(from url: URL) throws {
        let snapshot = try loadSnapshot(from: url)
        try restore(snapshot: snapshot)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw SystemProxyError.persistenceFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    public func save(snapshot: SystemProxySnapshot, to url: URL) throws {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            throw SystemProxyError.persistenceFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    public func loadSnapshot(from url: URL) throws -> SystemProxySnapshot {
        do {
            let decoder = JSONDecoder()
            let snapshot = try decoder.decode(
                SystemProxySnapshot.self,
                from: Data(contentsOf: url)
            )
            guard snapshot.formatVersion == SystemProxySnapshot.currentFormatVersion else {
                throw SystemProxyError.unsupportedSnapshotVersion(snapshot.formatVersion)
            }
            return snapshot
        } catch let error as SystemProxyError {
            throw error
        } catch {
            throw SystemProxyError.persistenceFailed(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    private func apply(
        endpoints: LocalSystemProxyEndpoints,
        to currentStates: [SystemProxyServiceState]
    ) throws {
        guard !currentStates.isEmpty else {
            throw SystemProxyError.noEnabledNetworkServices
        }
        let updatedStates = try currentStates.map { state in
            var configuration = state.configuration ?? [:]
            configuration[SystemProxyKeys.httpEnable] = .integer(1)
            configuration[SystemProxyKeys.httpHost] = .string(endpoints.http.host)
            configuration[SystemProxyKeys.httpPort] = .integer(Int64(endpoints.http.port))

            configuration[SystemProxyKeys.httpsEnable] = .integer(1)
            configuration[SystemProxyKeys.httpsHost] = .string(endpoints.https.host)
            configuration[SystemProxyKeys.httpsPort] = .integer(Int64(endpoints.https.port))

            configuration[SystemProxyKeys.socksEnable] = .integer(1)
            configuration[SystemProxyKeys.socksHost] = .string(endpoints.socks.host)
            configuration[SystemProxyKeys.socksPort] = .integer(Int64(endpoints.socks.port))

            // Explicit proxies and PAC should never race for ownership of the same service.
            configuration[SystemProxyKeys.pacEnable] = .integer(0)
            configuration[SystemProxyKeys.autoDiscoveryEnable] = .integer(0)

            return try SystemProxyServiceState(
                service: state.service,
                protocolExists: true,
                configuration: configuration
            )
        }
        try backend.applyProxyStates(updatedStates)
    }
}
