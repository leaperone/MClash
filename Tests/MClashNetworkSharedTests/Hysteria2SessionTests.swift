import Testing
@testable import MClashNetworkShared

@Suite("Hysteria2 session lifecycle")
struct Hysteria2SessionTests {
    @Test("Accepts connect, authentication, ready, and close transitions")
    func lifecycle() {
        var session = Hysteria2Session()
        let connected = session.beginConnect()
        #expect(connected)
        let authenticating = session.beginAuthentication()
        #expect(authenticating)
        let ready = session.authenticationSucceeded(udpEnabled: true)
        #expect(ready)
        let closing = session.beginClose()
        #expect(closing)
        let closed = session.finishClose()
        #expect(closed)
        #expect(session.state == .closed)
    }

    @Test("Rejects invalid transitions and permits retry after failure")
    func invalidTransitions() {
        var session = Hysteria2Session()
        let invalidAuthentication = session.beginAuthentication()
        #expect(!invalidAuthentication)
        session.fail("timeout")
        let retry = session.beginConnect()
        #expect(retry)
        let invalidReady = session.authenticationSucceeded(udpEnabled: false)
        #expect(!invalidReady)
        let authenticating = session.beginAuthentication()
        #expect(authenticating)
    }

    @Test("Only a valid 233 auth response enters ready")
    func authenticationResponse() {
        var session = Hysteria2Session()
        let connected = session.beginConnect()
        #expect(connected)
        let authenticating = session.beginAuthentication()
        #expect(authenticating)
        let handled = session.handleAuthenticationResponse(
            statusCode: 233,
            headers: ["Hysteria-UDP": "true"]
        )
        #expect(handled)
        #expect(session.state == .ready(udpEnabled: true))
    }

    @Test("Does not allow authentication or ready transitions out of order")
    func rejectsOutOfOrderEvents() {
        var session = Hysteria2Session()
        #expect(!session.beginAuthentication())
        #expect(!session.authenticationSucceeded(udpEnabled: true))
        #expect(session.state == .idle)

        #expect(session.beginConnect())
        #expect(session.beginAuthentication())
        #expect(!session.beginConnect())
        #expect(session.authenticationSucceeded(udpEnabled: false))
        #expect(session.state == .ready(udpEnabled: false))
        // A second response cannot move an already-ready session again.
        #expect(!session.authenticationSucceeded(udpEnabled: true))
        #expect(!session.beginAuthentication())
    }

    @Test("Invalid authentication response fails closed and can be retried")
    func invalidAuthenticationFailsClosed() {
        var session = Hysteria2Session()
        #expect(session.beginConnect())
        #expect(session.beginAuthentication())
        #expect(!session.handleAuthenticationResponse(
            statusCode: 233,
            headers: ["Hysteria-UDP": "not-a-boolean"]
        ))
        if case .failed = session.state {
            // Expected: malformed capability headers never produce ready.
        } else {
            Issue.record("malformed authentication response must fail the session")
        }
        #expect(session.beginConnect())
        #expect(session.beginAuthentication())
        #expect(session.handleAuthenticationResponse(
            statusCode: 233,
            headers: ["Hysteria-UDP": "false", "Hysteria-CC-RX": "auto"]
        ))
        #expect(session.state == .ready(udpEnabled: false))
    }
}
