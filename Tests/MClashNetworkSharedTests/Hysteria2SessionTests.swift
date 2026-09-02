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
}
