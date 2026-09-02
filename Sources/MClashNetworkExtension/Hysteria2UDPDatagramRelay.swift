import Foundation
@preconcurrency import NetworkExtension
import MClashNetworkShared

/// Bridges one NEAppProxyUDPFlow to an authenticated Hysteria2 QUIC session.
/// Session/fragment accounting remains in shared value types; this class only
/// owns I/O scheduling and cancellation.
final class Hysteria2UDPDatagramRelay: @unchecked Sendable {
    private let flow: NEAppProxyUDPFlow
    private let session: Hysteria2QUICSession
    private let connector: NativeHysteria2OutboundConnector
    private let queue = DispatchQueue(label: "one.leaper.mclash.hysteria2-udp-relay")
    private var stopped = false

    init(flow: NEAppProxyUDPFlow, session: Hysteria2QUICSession, connector: NativeHysteria2OutboundConnector) {
        self.flow = flow
        self.session = session
        self.connector = connector
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            AppProxyFlowCompatibility.open(self.flow) { [weak self] error in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, error == nil, !self.stopped else { self?.finish(); return }
                    self.readFromApp()
                    self.readFromHysteria()
                }
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in self?.finish() }
    }

    private func readFromApp() {
        guard !stopped else { return }
        UDPAppProxyFlowCompatibility.read(from: flow) { [weak self] datagrams, error in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                guard error == nil, let datagrams, !datagrams.isEmpty else { self.finish(); return }
                for datagram in datagrams {
                    guard let packetID = self.packetID() else { self.finish(); return }
                    do {
                        let payload = try self.connector.udpMessage(
                            sessionID: 1,
                            packetID: packetID,
                            destination: datagram.endpoint,
                            payload: datagram.payload
                        )
                        self.session.sendUDPMessage(payload) { [weak self] error in
                            guard error != nil, let self else { return }
                            self.queue.async { [weak self] in self?.finish() }
                        }
                    } catch { self.finish(); return }
                }
                self.readFromApp()
            }
        }
    }

    private func readFromHysteria() {
        guard !stopped else { return }
        session.receiveReassembledUDPMessage { [weak self] result in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                switch result {
                case .failure:
                    self.finish()
                case let .success(message):
                    guard let endpoint = try? SOCKS5Endpoint(
                        address: message.host.contains(":")
                            ? SOCKS5Address(ipAddress: try IPAddress(message.host))
                            : SOCKS5Address(domain: message.host),
                        port: message.port
                    ) else { self.finish(); return }
                    UDPAppProxyFlowCompatibility.write(
                        UDPFlowDatagram(payload: message.payload, endpoint: endpoint),
                        to: self.flow
                    ) { [weak self] error in
                        guard error != nil, let self else { return }
                        self.queue.async { [weak self] in self?.finish() }
                    }
                    self.readFromHysteria()
                }
            }
        }
    }

    private var nextPacket: UInt16 = 0
    private func packetID() -> UInt16? {
        let id = nextPacket
        nextPacket &+= 1
        return id
    }

    private func finish() {
        guard !stopped else { return }
        stopped = true
        session.cancel()
        flow.closeReadWithError(nil)
        flow.closeWriteWithError(nil)
    }
}
