import Foundation
import MClashNetworkShared
import Testing
@testable import MClashNetworkExtension

@Suite("Process identity resolution cache")
struct ProcessIdentityResolutionCacheTests {
    @Test("Reuses verified identities and evicts the oldest token")
    func boundedFIFO() throws {
        let first = try identity(tokenByte: 1, processIdentifier: 101)
        let second = try identity(tokenByte: 2, processIdentifier: 102)
        let third = try identity(tokenByte: 3, processIdentifier: 103)
        let cache = ProcessIdentityResolutionCache(capacity: 2)

        cache.insert(first)
        cache.insert(second)
        cache.insert(first)

        #expect(cache.identity(for: first.auditToken) == first)
        #expect(cache.identity(for: second.auditToken) == second)

        cache.insert(third)

        #expect(cache.identity(for: first.auditToken) == nil)
        #expect(cache.identity(for: second.auditToken) == second)
        #expect(cache.identity(for: third.auditToken) == third)
    }

    @Test("Zero capacity disables caching")
    func zeroCapacity() throws {
        let value = try identity(tokenByte: 9, processIdentifier: 109)
        let cache = ProcessIdentityResolutionCache(capacity: 0)

        cache.insert(value)

        #expect(cache.identity(for: value.auditToken) == nil)
    }

    private func identity(
        tokenByte: UInt8,
        processIdentifier: Int32
    ) throws -> ResolvedProcessIdentity {
        ResolvedProcessIdentity(
            auditToken: try SourceAppAuditToken(
                Data(repeating: tokenByte, count: SourceAppAuditToken.byteCount)
            ),
            processIdentifier: processIdentifier,
            processVersion: processIdentifier,
            effectiveUserID: 501,
            auditUserID: 501,
            executablePath: "/Applications/Test-\(processIdentifier).app/Contents/MacOS/Test",
            codeSigning: .unsigned
        )
    }
}
