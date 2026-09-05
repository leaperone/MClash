import Foundation
import Testing
@testable import MClashNetworkShared

@Suite("Native fake IP configuration")
struct NativeFakeIPConfigurationTests {
    @Test("Round trips bounded configuration and constructs allocator")
    func roundTrip() throws {
        let config = try NativeFakeIPConfiguration(filters: ["+.lan", "*.internal"], maximumEntries: 100, maximumEntriesPerSource: 20, mappingScope: .runtimeGlobal)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(NativeFakeIPConfiguration.self, from: data)
        #expect(decoded == config)
        #expect(try NativeFakeIPAllocator(configuration: decoded).maximumEntries == 100)
    }

    @Test("Rejects unsafe pools, filters, capacities and TTLs")
    func bounds() throws {
        #expect(throws: NativeFakeIPConfigurationError.unsupportedPool) { _ = try NativeFakeIPConfiguration(pool: IPNetwork("10.0.0.0/16")) }
        #expect(throws: NativeFakeIPConfigurationError.invalidCapacity) { _ = try NativeFakeIPConfiguration(maximumEntries: 0) }
        #expect(throws: NativeFakeIPConfigurationError.invalidTTL) { _ = try NativeFakeIPConfiguration(minimumTTL: 10, maximumTTL: 5) }
        #expect(throws: NativeFakeIPConfigurationError.invalidFilter) { _ = try NativeFakeIPConfiguration(filters: ["bad host.example"]) }
    }
}
