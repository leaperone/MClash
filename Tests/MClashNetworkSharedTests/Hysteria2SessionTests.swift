import Testing
@testable import MClashNetworkShared

@Suite("Hysteria2 session lifecycle")
struct Hysteria2SessionTests {
    @Test("Accepts connect, authentication, ready, and close transitions")
    func lifecycle() {
        var session = Hysteria2Session()
        #expect(session.beginConnect())
        #expect(session.beginAuthentication())
        #expect(session.authenticationSucceeded(udpEnabled: true))
        #expect(session.beginClose())
        #expect(session.finishClose())
        #expect(session.state == .closed)
    }

    @Test("Rejects invalid transitions and permits retry after failure")
    func invalidTransitions() {
        var session = Hysteria2Session()
        #expect(!session.beginAuthentication())
        session.fail("timeout")
        #expect(session.beginConnect())
        #expect(!session.authenticationSucceeded(udpEnabled: false))
        #expect(session.beginAuthentication())
    }
}
