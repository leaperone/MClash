import Foundation
import Testing
@testable import MClashNetworkExtension
import MClashNetworkShared

@Suite("Native fake-IP DNS relay seam")
struct NativeFakeIPDNSRelayIntegrationTests {
    @Test("A missing replacement preserves upstream bytes")
    func preservesBytesWhenDisabled() {
        let response = Data([0x01, 0x02, 0x03])
        #expect(NativeDNSFlowRelay.responseAfterObservation(
            query: Data([0x01]), response: response, observer: nil
        ) == response)
        #expect(NativeDNSFlowRelay.responseAfterObservation(
            query: Data([0x01]), response: response, observer: { _, _ in nil }
        ) == response)
    }

    @Test("A replacement is selected immediately before relay write")
    func selectsReplacement() {
        let response = Data([0x01, 0x02])
        let replacement = Data([0x09, 0x08])
        #expect(NativeDNSFlowRelay.responseAfterObservation(
            query: Data([0x01]), response: response, observer: { _, _ in replacement }
        ) == replacement)
    }

    @Test("Allocator registry swaps and clears atomically")
    func registryLifecycle() throws {
        let registry = NativeFakeIPAllocatorRegistry()
        let first = try NativeFakeIPAllocator(configuration: NativeFakeIPConfiguration())
        let second = try NativeFakeIPAllocator(configuration: NativeFakeIPConfiguration(maximumEntries: 32))
        #expect(registry.snapshot() == nil)
        #expect(registry.replace(with: first) == nil)
        #expect(registry.snapshot() === first)
        #expect(registry.replace(with: second) === first)
        #expect(registry.snapshot() === second)
        registry.clear()
        #expect(registry.snapshot() == nil)
    }
}
