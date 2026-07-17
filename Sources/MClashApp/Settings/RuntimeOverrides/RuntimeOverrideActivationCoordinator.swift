import Foundation

/// Integration boundary for AppModel. It composes the active profile with the
/// durable override layer, validates the exact generated YAML, and then uses
/// ProfileStore's existing atomic replacement/rollback transaction.
public actor RuntimeOverrideActivationCoordinator {
    private let overrideStore: RuntimeOverrideStore
    private let composer: RuntimeConfigurationComposer

    public init(
        overrideStore: RuntimeOverrideStore,
        composer: RuntimeConfigurationComposer = RuntimeConfigurationComposer()
    ) {
        self.overrideStore = overrideStore
        self.composer = composer
    }

    public func overrides() async throws -> RuntimeOverrides {
        try await overrideStore.load()
    }

    public func save(_ overrides: RuntimeOverrides) async throws {
        try await overrideStore.save(overrides)
    }

    @discardableResult
    public func activateProfile(
        _ id: ProfileID,
        in profileStore: ProfileStore,
        validator: any ProfileValidating
    ) async throws -> RuntimeConfigurationActivation {
        let currentOverrides = try await overrideStore.load()
        return try await activateProfile(
            id,
            overrides: currentOverrides,
            in: profileStore,
            validator: validator
        )
    }

    /// Validates the exact candidate runtime configuration without changing
    /// either the active runtime file or the durable override document. This
    /// lets AppModel keep a healthy core running while a settings edit is
    /// checked by mihomo.
    public func validateProfile(
        _ id: ProfileID,
        overrides: RuntimeOverrides,
        in profileStore: ProfileStore,
        validator: any ProfileValidating
    ) async throws {
        let stagedURL = try await stagedRuntimeConfiguration(
            for: id,
            overrides: overrides,
            in: profileStore
        )
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        try await validator.validate(configurationAt: stagedURL)
    }

    /// Activates a caller-supplied override candidate. The durable override
    /// store is deliberately not read or written here: AppModel commits it
    /// only after the candidate core has reached readiness, and can therefore
    /// reactivate the previous overrides during rollback.
    @discardableResult
    public func activateProfile(
        _ id: ProfileID,
        overrides: RuntimeOverrides,
        in profileStore: ProfileStore,
        validator: any ProfileValidating
    ) async throws -> RuntimeConfigurationActivation {
        let previousProfileID = try await profileStore.activeProfileID()
        let stagedURL = try await stagedRuntimeConfiguration(
            for: id,
            overrides: overrides,
            in: profileStore
        )

        do {
            try await validator.validate(configurationAt: stagedURL)
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }

        let runtimeReceipt: FileReplacementReceipt
        do {
            runtimeReceipt = try await profileStore.replaceRuntimeConfiguration(
                withStagedFile: stagedURL
            )
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }
        do {
            try await profileStore.setActiveProfile(id)
            try await profileStore.commitReplacement(runtimeReceipt)
        } catch {
            try? await profileStore.rollbackReplacement(runtimeReceipt)
            try? await profileStore.setActiveProfile(previousProfileID)
            throw error
        }

        return RuntimeConfigurationActivation(
            profileID: id,
            previousProfileID: previousProfileID,
            configurationURL: profileStore.layout.runtimeConfigurationURL
        )
    }

    private func stagedRuntimeConfiguration(
        for id: ProfileID,
        overrides: RuntimeOverrides,
        in profileStore: ProfileStore
    ) async throws -> URL {
        let sourceData = try await profileStore.configurationData(for: id)
        let runtimeData = try composer.applying(overrides, to: sourceData)
        return try await profileStore.stageRuntimeConfiguration(
            data: runtimeData,
            preferredName: "config.yaml"
        )
    }
}

public extension ProfileStore {
    /// Stages already-composed runtime bytes without mutating the stored
    /// profile. This small API is also useful to future DNS/TUN composers.
    func stageRuntimeConfiguration(
        data: Data,
        preferredName: String = "config.yaml"
    ) async throws -> URL {
        let replacer = AtomicFileReplacer()
        return try await replacer.stage(
            data: data,
            in: layout.runtimeStagingDirectory,
            preferredName: preferredName
        )
    }
}
