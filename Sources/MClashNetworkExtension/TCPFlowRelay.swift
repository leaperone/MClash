import Foundation
import MClashNetworkShared
@preconcurrency import Network
@preconcurrency import NetworkExtension

enum TCPFlowRelayError: Error, LocalizedError, Sendable {
    case handshakeTimedOut
    case upstreamClosedDuringHandshake
    case upstreamFailed(String)
    case flowOpenFailed(String)
    case flowReadFailed(String)
    case flowWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .handshakeTimedOut:
            "The local mihomo SOCKS5 handshake timed out."
        case .upstreamClosedDuringHandshake:
            "The local mihomo SOCKS5 listener closed during handshake."
        case let .upstreamFailed(message):
            "The local mihomo SOCKS5 connection failed: \(message)"
        case let .flowOpenFailed(message):
            "The intercepted TCP flow could not be opened: \(message)"
        case let .flowReadFailed(message):
            "Reading the intercepted TCP flow failed: \(message)"
        case let .flowWriteFailed(message):
            "Writing the intercepted TCP flow failed: \(message)"
        }
    }
}

enum AppProxyFlowCompatibility {
    static func open(
        _ flow: NEAppProxyFlow,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        if #available(macOS 15.0, *) {
            flow.open(withLocalFlowEndpoint: nil, completionHandler: completion)
            return
        }

        // The macOS 14 Objective-C selector remains public and supported, but
        // Swift 6 hides its deprecated NWHostEndpoint parameter when compiling
        // against the macOS 15+ SDK. Invoke that exact selector only on 14.
        let selector = NSSelectorFromString("openWithLocalEndpoint:completionHandler:")
        let block: @convention(block) (NSError?) -> Void = { error in
            completion(error)
        }
        _ = flow.perform(selector, with: nil, with: block)
    }
}

/// Owns one intercepted TCP flow from the synchronous provider callback until
/// both halves close. Reads are issued only after the previous write completes,
/// providing bounded backpressure in both directions.
final class TCPFlowRelay: @unchecked Sendable {
    let id = UUID()

    private let flow: NEAppProxyTCPFlow
    private let proxy: ProviderSOCKSConfiguration
    private let destination: SOCKS5Endpoint
    private let queue: DispatchQueue
    private let completion: @Sendable (UUID) -> Void
    private let activityObserver: @Sendable (AppRoutingRelaySnapshot) -> Void

    private var connection: NWConnection?
    private var handshakeTimeout: DispatchWorkItem?
    private var methodDecoder = SOCKS5MethodSelectionDecoder()
    private var authenticationDecoder = SOCKS5UsernamePasswordResponseDecoder()
    private var commandDecoder = SOCKS5CommandReplyDecoder()
    private var openedFlow = false
    private var clientReadFinished = false
    private var upstreamReadFinished = false
    private var finished = false
    private var uploadBytes: UInt64 = 0
    private var downloadBytes: UInt64 = 0
    private var relayLocalPort: UInt16?

    init(
        flow: NEAppProxyTCPFlow,
        proxy: ProviderSOCKSConfiguration,
        destination: SOCKS5Endpoint,
        activityObserver: @escaping @Sendable (AppRoutingRelaySnapshot) -> Void,
        completion: @escaping @Sendable (UUID) -> Void
    ) {
        self.flow = flow
        self.proxy = proxy
        self.destination = destination
        self.activityObserver = activityObserver
        self.completion = completion
        queue = DispatchQueue(label: "one.leaper.mclash.tcp-relay.\(id.uuidString)")
    }

    func start() {
        queue.async { [self] in
            guard !finished else { return }
            let connection = NWConnection(
                host: proxy.networkHost,
                port: proxy.networkPort,
                using: .tcp
            )
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async { self.handleConnectionState(state) }
            }
            scheduleHandshakeTimeout()
            connection.start(queue: queue)
        }
    }

    func cancel() {
        queue.async { [self] in
            finish(error: nil)
        }
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        guard !finished else { return }
        switch state {
        case .ready:
            relayLocalPort = Self.localPort(of: connection)
            beginSOCKSHandshake()
        case let .failed(error):
            finish(error: TCPFlowRelayError.upstreamFailed(error.localizedDescription))
        case .cancelled:
            finish(error: nil)
        default:
            break
        }
    }

    private func scheduleHandshakeTimeout() {
        let work = DispatchWorkItem { [weak self] in
            self?.finish(error: TCPFlowRelayError.handshakeTimedOut)
        }
        handshakeTimeout = work
        queue.asyncAfter(deadline: .now() + .seconds(10), execute: work)
    }

    private func beginSOCKSHandshake() {
        do {
            let negotiator = SOCKS5ClientAuthenticationNegotiator(
                credentials: proxy.credentials
            )
            try send(negotiator.greeting()) { [weak self] in
                self?.receiveMethodSelection(negotiator: negotiator)
            }
        } catch {
            finish(error: error)
        }
    }

    private func receiveMethodSelection(
        negotiator: SOCKS5ClientAuthenticationNegotiator
    ) {
        receiveHandshakeChunk { [weak self] data in
            guard let self else { return }
            do {
                guard let selection = try methodDecoder.append(data) else {
                    receiveMethodSelection(negotiator: negotiator)
                    return
                }
                switch try negotiator.handle(selection) {
                case .authenticated:
                    sendConnectRequest()
                case let .sendUsernamePassword(request):
                    try send(request) { [weak self] in
                        self?.receiveAuthenticationResponse()
                    }
                }
            } catch {
                finish(error: error)
            }
        }
    }

    private func receiveAuthenticationResponse() {
        receiveHandshakeChunk { [weak self] data in
            guard let self else { return }
            do {
                guard let response = try authenticationDecoder.append(data) else {
                    receiveAuthenticationResponse()
                    return
                }
                try response.requireSuccess()
                sendConnectRequest()
            } catch {
                finish(error: error)
            }
        }
    }

    private func sendConnectRequest() {
        do {
            let request = try SOCKS5CommandRequest(
                command: .connect,
                endpoint: destination
            )
            try send(SOCKS5Codec.encodeCommandRequest(request)) { [weak self] in
                self?.receiveCommandResponse()
            }
        } catch {
            finish(error: error)
        }
    }

    private func receiveCommandResponse() {
        receiveHandshakeChunk { [weak self] data in
            guard let self else { return }
            do {
                guard let response = try commandDecoder.append(data) else {
                    receiveCommandResponse()
                    return
                }
                try response.requireSuccess()
                handshakeTimeout?.cancel()
                handshakeTimeout = nil
                openFlow(initialUpstreamPayload: commandDecoder.remainingData)
            } catch {
                finish(error: error)
            }
        }
    }

    private func send(_ data: Data, then next: @escaping @Sendable () -> Void) throws {
        guard let connection else {
            throw TCPFlowRelayError.upstreamClosedDuringHandshake
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.finish(error: TCPFlowRelayError.upstreamFailed(
                        error.localizedDescription
                    ))
                } else if !self.finished {
                    next()
                }
            }
        })
    }

    private func receiveHandshakeChunk(
        _ consume: @escaping @Sendable (Data) -> Void
    ) {
        guard let connection else {
            finish(error: TCPFlowRelayError.upstreamClosedDuringHandshake)
            return
        }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.finish(error: TCPFlowRelayError.upstreamFailed(
                        error.localizedDescription
                    ))
                    return
                }
                if let data, !data.isEmpty {
                    consume(data)
                    return
                }
                if isComplete {
                    self.finish(error: TCPFlowRelayError.upstreamClosedDuringHandshake)
                } else {
                    self.receiveHandshakeChunk(consume)
                }
            }
        }
    }

    private func openFlow(initialUpstreamPayload: Data) {
        let completion: @Sendable (Error?) -> Void = { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.finish(error: TCPFlowRelayError.flowOpenFailed(
                        error.localizedDescription
                    ))
                    return
                }
                self.openedFlow = true
                self.report(.ready)
                if initialUpstreamPayload.isEmpty {
                    self.startPumps()
                } else {
                    self.downloadBytes &+= UInt64(initialUpstreamPayload.count)
                    self.report(.relaying)
                    self.writeToFlow(initialUpstreamPayload) { [weak self] in
                        self?.startPumps()
                    }
                }
            }
        }
        AppProxyFlowCompatibility.open(flow, completion: completion)
    }

    private func startPumps() {
        readFromFlow()
        readFromUpstream()
    }

    private func readFromFlow() {
        guard !finished, !clientReadFinished else { return }
        flow.readData { [weak self] data, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.finish(error: TCPFlowRelayError.flowReadFailed(
                        error.localizedDescription
                    ))
                    return
                }
                guard let data, !data.isEmpty else {
                    self.clientReadFinished = true
                    self.connection?.send(
                        content: nil,
                        contentContext: .defaultMessage,
                        isComplete: true,
                        completion: .contentProcessed { [weak self] error in
                            guard let self else { return }
                            self.queue.async {
                                if let error {
                                    self.finish(error: TCPFlowRelayError.upstreamFailed(
                                        error.localizedDescription
                                    ))
                                } else {
                                    self.finishIfBothHalvesClosed()
                                }
                            }
                        }
                    )
                    return
                }
                self.uploadBytes &+= UInt64(data.count)
                self.report(.relaying)
                self.connection?.send(
                    content: data,
                    completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        self.queue.async {
                            if let error {
                                self.finish(error: TCPFlowRelayError.upstreamFailed(
                                    error.localizedDescription
                                ))
                            } else {
                                self.readFromFlow()
                            }
                        }
                    }
                )
            }
        }
    }

    private func readFromUpstream() {
        guard !finished, !upstreamReadFinished, let connection else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.finish(error: TCPFlowRelayError.upstreamFailed(
                        error.localizedDescription
                    ))
                    return
                }
                if let data, !data.isEmpty {
                    self.downloadBytes &+= UInt64(data.count)
                    self.report(.relaying)
                    self.writeToFlow(data) { [weak self] in
                        guard let self else { return }
                        if isComplete {
                            self.markUpstreamReadFinished()
                        } else {
                            self.readFromUpstream()
                        }
                    }
                } else if isComplete {
                    self.markUpstreamReadFinished()
                } else {
                    self.readFromUpstream()
                }
            }
        }
    }

    private func writeToFlow(_ data: Data, then next: @escaping @Sendable () -> Void) {
        flow.write(data) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                if let error {
                    self.finish(error: TCPFlowRelayError.flowWriteFailed(
                        error.localizedDescription
                    ))
                } else if !self.finished {
                    next()
                }
            }
        }
    }

    private func markUpstreamReadFinished() {
        upstreamReadFinished = true
        flow.closeWriteWithError(nil)
        finishIfBothHalvesClosed()
    }

    private func finishIfBothHalvesClosed() {
        if clientReadFinished && upstreamReadFinished {
            finish(error: nil)
        }
    }

    private func finish(error: Error?) {
        guard !finished else { return }
        finished = true
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil

        if let error {
            flow.closeReadWithError(error)
            flow.closeWriteWithError(error)
        } else if openedFlow {
            if !clientReadFinished { flow.closeReadWithError(nil) }
            if !upstreamReadFinished { flow.closeWriteWithError(nil) }
        }
        report(
            error == nil ? .completed : .failed,
            error: error?.localizedDescription
        )
        completion(id)
    }

    private func report(_ state: AppRoutingRelayState, error: String? = nil) {
        activityObserver(AppRoutingRelaySnapshot(
            state: state,
            uploadBytes: uploadBytes,
            downloadBytes: downloadBytes,
            error: error,
            localPort: relayLocalPort
        ))
    }

    private static func localPort(of connection: NWConnection?) -> UInt16? {
        guard case let .hostPort(_, port) = connection?.currentPath?.localEndpoint else {
            return nil
        }
        return port.rawValue
    }
}

final class TCPFlowRelayRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var relays: [UUID: TCPFlowRelay] = [:]

    func start(
        flow: NEAppProxyTCPFlow,
        proxy: ProviderSOCKSConfiguration,
        destination: SOCKS5Endpoint,
        activityObserver: @escaping @Sendable (AppRoutingRelaySnapshot) -> Void
    ) {
        let relay = TCPFlowRelay(
            flow: flow,
            proxy: proxy,
            destination: destination,
            activityObserver: activityObserver
        ) { [weak self] identifier in
            self?.remove(identifier)
        }
        lock.lock()
        relays[relay.id] = relay
        lock.unlock()
        relay.start()
    }

    func cancelAll() {
        lock.lock()
        let current = Array(relays.values)
        relays.removeAll(keepingCapacity: false)
        lock.unlock()
        current.forEach { $0.cancel() }
    }

    private func remove(_ identifier: UUID) {
        lock.lock()
        relays.removeValue(forKey: identifier)
        lock.unlock()
    }
}
