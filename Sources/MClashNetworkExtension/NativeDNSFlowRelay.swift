import Foundation
import MClashNetworkShared
@preconcurrency import NetworkExtension

/// Bridges an intercepted DNS flow directly to the connector-neutral socket
/// upstream. This is deliberately opt-in; the existing Mihomo SOCKS relay is
/// retained as the default until native DNS is enabled by a host bootstrap.
final class NativeDNSFlowRelay: @unchecked Sendable {
    typealias ExchangeObserver = @Sendable (_ query: Data, _ response: Data) -> Void
    private let queue = DispatchQueue(label: "one.leaper.mclash.native-dns-relay")
    private let tcpFlow: NEAppProxyTCPFlow?
    private let udpFlow: NEAppProxyUDPFlow?
    private let endpoint: DNSUpstreamEndpoint
    private let endpointSelector: (@Sendable (Data) -> DNSUpstreamEndpoint?)?
    private let completion: @Sendable () -> Void
    private let exchangeObserver: ExchangeObserver?
    private var buffer = Data()
    private var stopped = false
    private var completionCalled = false

    private init(
        tcpFlow: NEAppProxyTCPFlow? = nil,
        udpFlow: NEAppProxyUDPFlow? = nil,
        endpoint: DNSUpstreamEndpoint,
        endpointSelector: (@Sendable (Data) -> DNSUpstreamEndpoint?)? = nil,
        exchangeObserver: ExchangeObserver? = nil,
        completion: @escaping @Sendable () -> Void
    ) {
        self.tcpFlow = tcpFlow
        self.udpFlow = udpFlow
        self.endpoint = endpoint
        self.endpointSelector = endpointSelector
        self.exchangeObserver = exchangeObserver
        self.completion = completion
    }

    static func startTCP(
        flow: NEAppProxyTCPFlow,
        endpoint: DNSUpstreamEndpoint,
        endpointSelector: (@Sendable (Data) -> DNSUpstreamEndpoint?)? = nil,
        exchangeObserver: ExchangeObserver? = nil,
        completion: @escaping @Sendable () -> Void
    ) -> NativeDNSFlowRelay {
        let relay = NativeDNSFlowRelay(
            tcpFlow: flow,
            endpoint: endpoint,
            endpointSelector: endpointSelector,
            exchangeObserver: exchangeObserver,
            completion: completion
        )
        relay.queue.async { relay.openTCP() }
        return relay
    }

    static func startUDP(
        flow: NEAppProxyUDPFlow,
        endpoint: DNSUpstreamEndpoint,
        endpointSelector: (@Sendable (Data) -> DNSUpstreamEndpoint?)? = nil,
        exchangeObserver: ExchangeObserver? = nil,
        completion: @escaping @Sendable () -> Void
    ) -> NativeDNSFlowRelay {
        let relay = NativeDNSFlowRelay(
            udpFlow: flow,
            endpoint: endpoint,
            endpointSelector: endpointSelector,
            exchangeObserver: exchangeObserver,
            completion: completion
        )
        relay.queue.async { relay.openUDP() }
        return relay
    }

    func cancel() {
        queue.async {
            self.stopped = true
            self.tcpFlow?.closeReadWithError(nil)
            self.tcpFlow?.closeWriteWithError(nil)
            self.udpFlow?.closeReadWithError(nil)
            self.udpFlow?.closeWriteWithError(nil)
            self.completeOnce()
        }
    }

    private func openTCP() {
        guard let flow = tcpFlow else { return }
        AppProxyFlowCompatibility.open(flow) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard error == nil, !self.stopped else { self.finish(); return }
                self.readTCP()
            }
        }
    }

    private func readTCP() {
        guard let flow = tcpFlow, !stopped else { return }
        flow.readData { [weak self] data, error in
            guard let self else { return }
            self.queue.async {
                guard error == nil, let data, !data.isEmpty, !self.stopped else {
                    self.finish(); return
                }
                self.buffer.append(data)
                do {
                    guard self.buffer.count >= 2 else { self.readTCP(); return }
                    let length = Int(self.buffer[0]) << 8 | Int(self.buffer[1])
                    guard length > 0, length <= DNSUpstreamLimits.maximumTCPFrameBytes else {
                        self.finish(); return
                    }
                    guard self.buffer.count >= length + 2 else { self.readTCP(); return }
                    let frame = self.buffer.prefix(length + 2)
                    self.buffer.removeFirst(length + 2)
                    let query = try DNSWireMessage.message(fromTCPFrame: frame)
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            let response = try await self.exchange(query: query)
                            self.exchangeObserver?(query, response)
                            let output = try DNSWireMessage.tcpFrame(for: response)
                            self.queue.async {
                                guard !self.stopped else { return }
                                    flow.write(output) { [weak self] error in
                                        guard let self else { return }
                                        self.queue.async { [weak self] in
                                            guard let self else { return }
                                            guard error == nil else { self.finish(); return }
                                            self.readTCP()
                                        }
                                    }
                            }
                        } catch { self.queue.async { self.finish() } }
                    }
                } catch { self.finish() }
            }
        }
    }

    private func openUDP() {
        guard let flow = udpFlow else { return }
        AppProxyFlowCompatibility.open(flow) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard error == nil, !self.stopped else { self.finish(); return }
                self.readUDP()
            }
        }
    }

    private func readUDP() {
        guard let flow = udpFlow, !stopped else { return }
        UDPAppProxyFlowCompatibility.read(from: flow) { [weak self] datagrams, error in
            guard let self else { return }
            self.queue.async {
                guard error == nil, let datagrams, !datagrams.isEmpty, !self.stopped else {
                    self.finish(); return
                }
                self.processUDP(datagrams, at: 0)
            }
        }
    }

    private func processUDP(_ datagrams: [UDPFlowDatagram], at index: Int) {
        guard let flow = udpFlow, !stopped else { return }
        guard index < datagrams.count else { readUDP(); return }
        let datagram = datagrams[index]
        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.exchange(query: datagram.payload)
                self.exchangeObserver?(datagram.payload, response)
                self.queue.async {
                    guard !self.stopped else { return }
                    UDPAppProxyFlowCompatibility.write(
                        UDPFlowDatagram(payload: response, endpoint: datagram.endpoint),
                        to: flow
                    ) { [weak self] error in
                        guard let self else { return }
                        self.queue.async { [weak self] in
                            guard let self else { return }
                            guard error == nil else { self.finish(); return }
                            self.processUDP(datagrams, at: index + 1)
                        }
                    }
                }
            } catch { self.queue.async { self.finish() } }
        }
    }

    private func finish() {
        guard !stopped else {
            completeOnce()
            return
        }
        stopped = true
        tcpFlow?.closeReadWithError(nil)
        tcpFlow?.closeWriteWithError(nil)
        udpFlow?.closeReadWithError(nil)
        udpFlow?.closeWriteWithError(nil)
        completeOnce()
    }

    private func completeOnce() {
        guard !completionCalled else { return }
        completionCalled = true
        completion()
    }

    private func exchange(query: Data) async throws -> Data {
        let selected = endpointSelector?(query) ?? endpoint
        return try await SocketDNSUpstream(endpoint: selected).exchange(query: query)
    }
}
