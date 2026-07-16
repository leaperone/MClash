import Testing
@testable import MClashApp

@Suite("Local proxy listener probe")
struct LocalPortProbeTests {
    @Test("The operating system can allocate an eligible loopback port")
    func allocatesLocalPort() throws {
        let port = try LocalPortProbe().availableTCPPort()

        #expect((1...65_535).contains(port))
    }

    @Test("Invalid ports are never reported as listening")
    func rejectsInvalidPorts() {
        let probe = LocalPortProbe()

        #expect(!probe.isListening(port: 0))
        #expect(!probe.isListening(port: 65_536))
    }
}
