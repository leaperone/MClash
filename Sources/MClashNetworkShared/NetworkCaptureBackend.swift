/// Explicit control-plane ownership marker shared by host and providers.
/// Missing values remain legacy for historical payloads.
public enum NetworkCaptureBackend: String, Codable, Equatable, Sendable {
    case legacy
    case native
}
