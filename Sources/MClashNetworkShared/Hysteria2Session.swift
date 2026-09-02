import Foundation

public enum Hysteria2SessionState: Equatable, Sendable {
    case idle
    case connecting
    case authenticating
    case ready(udpEnabled: Bool)
    case closing
    case closed
    case failed(String)
}

/// Connector-neutral Hysteria2 lifecycle reducer. QUIC/HTTP3 I/O reports
/// events into this reducer; it owns no sockets and is therefore deterministic
/// and straightforward to test.
public struct Hysteria2Session: Sendable {
    public private(set) var state: Hysteria2SessionState = .idle

    public init() {}

    public mutating func beginConnect() -> Bool {
        guard state == .idle || isRetryableFailure else { return false }
        state = .connecting
        return true
    }

    public mutating func beginAuthentication() -> Bool {
        guard state == .connecting else { return false }
        state = .authenticating
        return true
    }

    public mutating func authenticationSucceeded(udpEnabled: Bool) -> Bool {
        guard state == .authenticating else { return false }
        state = .ready(udpEnabled: udpEnabled)
        return true
    }

    public mutating func handleAuthenticationResponse(
        statusCode: Int,
        headers: [String: String]
    ) -> Bool {
        guard state == .authenticating else { return false }
        do {
            let response = try Hysteria2Codec.decodeAuthResponse(
                statusCode: statusCode,
                headers: headers
            )
            return authenticationSucceeded(udpEnabled: response.udpEnabled)
        } catch {
            fail(String(describing: error))
            return false
        }
    }

    public mutating func beginClose() -> Bool {
        guard state != .closed, state != .closing else { return false }
        state = .closing
        return true
    }

    public mutating func finishClose() -> Bool {
        guard state == .closing else { return false }
        state = .closed
        return true
    }

    public mutating func fail(_ message: String) {
        state = .failed(message)
    }

    private var isRetryableFailure: Bool {
        if case .failed = state { return true }
        return false
    }
}
