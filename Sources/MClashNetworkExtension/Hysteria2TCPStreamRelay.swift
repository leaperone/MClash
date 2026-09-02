import Foundation
@preconcurrency import Network
@preconcurrency import NetworkExtension

/// Relays one authenticated Hysteria2 TCP stream to an intercepted flow.
/// Exactly one read is outstanding per direction, so the NE flow and QUIC
/// stream provide natural bounded backpressure instead of unbounded buffering.
final class Hysteria2TCPStreamRelay: @unchecked Sendable {
    private let flow: NEAppProxyTCPFlow
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let completion: (@Sendable () -> Void)?
    private var stopped = false
    private var opened = false

    init(
        flow: NEAppProxyTCPFlow,
        connection: NWConnection,
        queue: DispatchQueue = DispatchQueue(label: "one.leaper.mclash.hysteria2-tcp-relay"),
        completion: (@Sendable () -> Void)? = nil
    ) {
        self.flow = flow
        self.connection = connection
        self.queue = queue
        self.completion = completion
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            AppProxyFlowCompatibility.open(self.flow) { [weak self] error in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self, error == nil, !self.stopped else { self?.finish(); return }
                    self.opened = true
                    self.readFromApp()
                    self.readFromStream()
                }
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.connection.cancel()
            self.flow.closeReadWithError(nil)
            self.flow.closeWriteWithError(nil)
        }
    }

    private func readFromApp() {
        guard opened, !stopped else { return }
        flow.readData { [weak self] data, error in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                if let error {
                    self.finish(error: error)
                    return
                }
                guard let data, !data.isEmpty else {
                    self.connection.send(
                        content: nil,
                        contentContext: .finalMessage,
                        isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.finish() }
                    )
                    return
                }
                self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    self.queue.async { [weak self] in
                        guard let self, !self.stopped else { return }
                        if let error { self.finish(error: error) }
                        else { self.readFromApp() }
                    }
                })
            }
        }
    }

    private func readFromStream() {
        guard opened, !stopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                if let error {
                    self.finish(error: error)
                    return
                }
                if let data, !data.isEmpty {
                    self.flow.write(data) { [weak self] error in
                        guard let self else { return }
                        self.queue.async { [weak self] in
                            guard let self, !self.stopped else { return }
                            if let error { self.finish(error: error) }
                            else { self.readFromStream() }
                        }
                    }
                } else if isComplete {
                    self.flow.closeWriteWithError(nil)
                    self.finish()
                } else {
                    self.readFromStream()
                }
            }
        }
    }

    private func finish(error: Error? = nil) {
        guard !stopped else { return }
        stopped = true
        connection.cancel()
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        completion?()
    }
}
