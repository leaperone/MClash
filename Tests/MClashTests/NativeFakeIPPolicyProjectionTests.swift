import Foundation
import Testing
import MClashNetworkShared
@testable import MClashApp

@Suite("DNS policy Fake-IP projection")
struct NativeFakeIPPolicyProjectionTests {
    @Test("Only fake-IP policies project a native configuration")
    func projection() throws {
        let fake = DNSPolicy(name: "Fake", mode: .fakeIP, nameservers: ["1.1.1.1"], fakeIPFilter: ["+.lan"])
        #expect(fake.nativeFakeIPConfiguration?.mappingScope == .runtimeGlobal)
        let redir = DNSPolicy(name: "Redir", mode: .redirHost)
        #expect(redir.nativeFakeIPConfiguration == nil)
        let data = try JSONEncoder().encode(fake)
        let decoded = try JSONDecoder().decode(DNSPolicy.self, from: data)
        #expect(decoded.nativeFakeIPConfiguration == fake.nativeFakeIPConfiguration)
    }

    @Test("Old DNS policy payload receives safe Fake-IP defaults")
    func oldPolicyDefaults() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","name":"DNS","mode":"redirHost","nameservers":[],"fallbackNameservers":[],"rules":[],"takeoverEnabled":true}
        """
        let decoded = try JSONDecoder().decode(DNSPolicy.self, from: Data(json.utf8))
        #expect(decoded.fakeIPRange == nil)
        #expect(decoded.fakeIPFilter.isEmpty)
        #expect(decoded.nativeFakeIPConfiguration == nil)
    }
}
