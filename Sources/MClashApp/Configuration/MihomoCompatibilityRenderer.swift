import Foundation

/// Explicit bridge from MClash's authoritative runtime plan to the legacy
/// Mihomo YAML format. Keeping this adapter separate makes the dependency
/// visible at call sites and prevents imported profile YAML from becoming a
/// hidden policy source.
public struct MihomoCompatibilityRenderer: Sendable {
    public let emitsListeners: Bool

    public init(emitsListeners: Bool = true) {
        self.emitsListeners = emitsListeners
    }

    public func render(_ plan: CompiledRuntimePlan) throws -> Data {
        try ConfigurationCompiler(emitsMihomoListeners: emitsListeners)
            .renderMihomoYAML(for: plan)
    }
}
