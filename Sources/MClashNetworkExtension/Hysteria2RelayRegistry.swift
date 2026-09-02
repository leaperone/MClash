import Foundation
@preconcurrency import NetworkExtension

/// Owns native Hysteria2 sessions and relays for the lifetime of the Provider.
/// The registry is intentionally transport-neutral at its public boundary so
/// AppModel can cancel one flow or all flows during a configuration update.
final class Hysteria2RelayRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [UUID: Hysteria2QUICSession] = [:]
    private var tcpRelays: [UUID: Hysteria2TCPStreamRelay] = [:]
    private var udpRelays: [UUID: Hysteria2UDPDatagramRelay] = [:]

    func retain(session: Hysteria2QUICSession, for flowID: UUID) {
        lock.lock()
        sessions[flowID] = session
        lock.unlock()
    }

    func retain(tcp relay: Hysteria2TCPStreamRelay, for flowID: UUID) {
        lock.lock()
        tcpRelays[flowID] = relay
        lock.unlock()
    }

    func retain(udp relay: Hysteria2UDPDatagramRelay, for flowID: UUID) {
        lock.lock()
        udpRelays[flowID] = relay
        lock.unlock()
    }

    func remove(flowID: UUID) {
        lock.lock()
        let session = sessions.removeValue(forKey: flowID)
        let tcp = tcpRelays.removeValue(forKey: flowID)
        let udp = udpRelays.removeValue(forKey: flowID)
        lock.unlock()
        tcp?.cancel()
        udp?.cancel()
        session?.cancel()
    }

    /// Releases ownership after a relay has finished itself. Unlike
    /// `remove`, this does not call cancel again (which would race the
    /// relay's completion callback).
    func release(flowID: UUID) {
        lock.lock()
        sessions.removeValue(forKey: flowID)
        tcpRelays.removeValue(forKey: flowID)
        udpRelays.removeValue(forKey: flowID)
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let allSessions = Array(sessions.values)
        let allTCP = Array(tcpRelays.values)
        let allUDP = Array(udpRelays.values)
        sessions.removeAll()
        tcpRelays.removeAll()
        udpRelays.removeAll()
        lock.unlock()
        allTCP.forEach { $0.cancel() }
        allUDP.forEach { $0.cancel() }
        allSessions.forEach { $0.cancel() }
    }
}
