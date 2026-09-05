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
        let original = DNSPolicy(name: "DNS", mode: .redirHost, takeoverEnabled: true)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original))
                as? [String: Any]
        )
        object.removeValue(forKey: "fakeIPRange")
        object.removeValue(forKey: "fakeIPFilter")
        object.removeValue(forKey: "fakeIPMaximumEntries")
        object.removeValue(forKey: "fakeIPMaximumEntriesPerSource")
        object.removeValue(forKey: "fakeIPMinimumTTL")
        object.removeValue(forKey: "fakeIPMaximumTTL")
        let decoded = try JSONDecoder().decode(
            DNSPolicy.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.fakeIPRange == nil)
        #expect(decoded.fakeIPFilter.isEmpty)
        #expect(decoded.nativeFakeIPConfiguration == nil)
    }
}
