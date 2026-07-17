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
        let previousProfileID = try await profileStore.activeProfileID()
        let sourceData = try await profileStore.configurationData(for: id)
        let currentOverrides = try await overrideStore.load()
        let runtimeData = try composer.applying(currentOverrides, to: sourceData)
        let stagedURL = try await profileStore.stageRuntimeConfiguration(
            data: runtimeData,
            preferredName: "config.yaml"
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
