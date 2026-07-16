import Testing
@testable import MClashApp

@Suite("Ephemeral core secret")
struct CoreSecretProviderTests {
    @Test("A provider reuses one secret for the current app launch")
    func reusesSecretInMemory() throws {
        let provider = EphemeralCoreSecretProvider()

        let first = try provider.loadOrCreate()
        let second = try provider.loadOrCreate()

        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test("Separate app launches receive separate controller secrets")
    func separatesProviderInstances() throws {
        let first = try EphemeralCoreSecretProvider().loadOrCreate()
        let second = try EphemeralCoreSecretProvider().loadOrCreate()

        #expect(first != second)
    }
}
