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
        let failure = ProcessIdentityResolution.unavailable(
            .processNoLongerExists
        )
        var calls = 0

        cache.insert(value)
        for _ in 0..<2 {
            _ = cache.resolve(
                sourceAppAuditToken: value.auditToken.data,
                nowNanoseconds: 100,
                resolver: { _ in
                    calls += 1
                    return failure
                }
            )
        }

        #expect(cache.identity(for: value.auditToken) == nil)
        #expect(calls == 2)
    }

    @Test("Caches a failure briefly and retries after expiry")
    func negativeEntryExpires() throws {
        let token = try SourceAppAuditToken(
            Data(repeating: 4, count: SourceAppAuditToken.byteCount)
        )
        let cache = ProcessIdentityResolutionCache(capacity: 2)
        let failure = ProcessIdentityResolution.unavailable(
            .executablePathPermissionDenied(errno: 1)
        )
        var calls = 0
        let resolve: (Data) -> ProcessIdentityResolution = { _ in
            calls += 1
            return failure
        }

        #expect(
            cache.resolve(
                sourceAppAuditToken: token.data,
                nowNanoseconds: 100,
                resolver: resolve
            ) == failure
        )
        #expect(
            cache.resolve(
                sourceAppAuditToken: token.data,
                nowNanoseconds: 101,
                resolver: resolve
            ) == failure
        )
        #expect(calls == 1)
        #expect(
            cache.resolve(
                sourceAppAuditToken: token.data,
                nowNanoseconds: 2_000_000_100,
                resolver: resolve
            ) == failure
        )
        #expect(calls == 2)
    }

    @Test("Failure entries remain bounded")
    func negativeEntriesAreBounded() throws {
        let first = try SourceAppAuditToken(
            Data(repeating: 1, count: SourceAppAuditToken.byteCount)
        )
        let second = try SourceAppAuditToken(
            Data(repeating: 2, count: SourceAppAuditToken.byteCount)
        )
        let third = try SourceAppAuditToken(
            Data(repeating: 3, count: SourceAppAuditToken.byteCount)
        )
        let cache = ProcessIdentityResolutionCache(capacity: 2)
        let failure = ProcessIdentityResolution.unavailable(
            .processNoLongerExists
        )
        var calls = 0
        let resolve: (Data) -> ProcessIdentityResolution = { _ in
            calls += 1
            return failure
        }

        for token in [first, second, third] {
            _ = cache.resolve(
                sourceAppAuditToken: token.data,
                nowNanoseconds: 100,
                resolver: resolve
            )
        }
        _ = cache.resolve(
            sourceAppAuditToken: second.data,
            nowNanoseconds: 101,
            resolver: resolve
        )
        _ = cache.resolve(
            sourceAppAuditToken: first.data,
            nowNanoseconds: 102,
            resolver: resolve
        )

        #expect(calls == 4)
    }

    @Test("A successful resolution clears its previous failure")
    func successClearsFailure() throws {
        let token = try SourceAppAuditToken(
            Data(repeating: 8, count: SourceAppAuditToken.byteCount)
        )
        let value = try identity(tokenByte: 8, processIdentifier: 108)
        let replacement = try identity(tokenByte: 9, processIdentifier: 109)
        let cache = ProcessIdentityResolutionCache(capacity: 1)
        let failure = ProcessIdentityResolution.unavailable(
            .executablePathPermissionDenied(errno: 1)
        )
        var calls = 0
        let failedResolve: (Data) -> ProcessIdentityResolution = { _ in
            calls += 1
            return failure
        }
        let successfulResolve: (Data) -> ProcessIdentityResolution = { _ in
            calls += 1
            return .resolved(value)
        }

        _ = cache.resolve(
            sourceAppAuditToken: token.data,
            nowNanoseconds: 100,
            resolver: failedResolve
        )
        cache.insert(value)
        cache.insert(replacement)
        #expect(
            cache.resolve(
                sourceAppAuditToken: token.data,
                nowNanoseconds: 101,
                resolver: successfulResolve
            ) == .resolved(value)
        )
        #expect(cache.identity(for: token) == value)
        #expect(calls == 2)
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
