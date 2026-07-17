import Foundation
@testable import MClashNetworkShared
import Testing

@Suite("Process identity values")
struct ProcessIdentityValueTests {
    @Test
    func auditTokenRequiresExactDarwinSize() throws {
        #expect(SourceAppAuditToken.byteCount == 32)
        #expect(throws: ProcessIdentityResolutionFailure.invalidAuditTokenLength(expected: 32, actual: 0)) {
            try SourceAppAuditToken(Data())
        }
        #expect(throws: ProcessIdentityResolutionFailure.invalidAuditTokenLength(expected: 32, actual: 31)) {
            try SourceAppAuditToken(Data(repeating: 0, count: 31))
        }
        #expect(throws: ProcessIdentityResolutionFailure.invalidAuditTokenLength(expected: 32, actual: 33)) {
            try SourceAppAuditToken(Data(repeating: 0, count: 33))
        }
        _ = try SourceAppAuditToken(Data(repeating: 7, count: 32))
    }

    @Test
    func malformedEncodedAuditTokenIsRejected() throws {
        let encodedShortData = try JSONEncoder().encode(Data(repeating: 1, count: 8))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SourceAppAuditToken.self, from: encodedShortData)
        }
    }

    @Test
    func signedIdentityRoundTripsWithoutLosingSecurityFields() throws {
        let token = try SourceAppAuditToken(Data((0 ..< 32).map(UInt8.init)))
        let signing = SignedCodeIdentity(
            signingIdentifier: "one.leaper.mclash",
            teamIdentifier: "5UAHRS482C",
            designatedRequirement: "identifier one.leaper.mclash and anchor apple generic",
            codeDirectoryHash: Data([0xAA, 0xBB]),
            securedBundleIdentifier: "one.leaper.mclash",
            mainExecutablePath: "/Applications/MClash.app/Contents/MacOS/MClash",
            isApplePlatformCode: false
        )
        let identity = ResolvedProcessIdentity(
            auditToken: token,
            processIdentifier: 456,
            processVersion: 12,
            effectiveUserID: 501,
            auditUserID: 501,
            executablePath: "/Applications/MClash.app/Contents/MacOS/MClash",
            codeSigning: .signed(signing)
        )
        let result = ProcessIdentityResolution.resolved(identity)

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ProcessIdentityResolution.self, from: data)
        #expect(decoded == result)
        #expect(decoded.identity == identity)
        #expect(!decoded.shouldFailOpen)
    }

    @Test
    func unavailableResolutionAlwaysRequiresFailOpen() throws {
        let failures: [ProcessIdentityResolutionFailure] = [
            .invalidAuditTokenLength(expected: 32, actual: 4),
            .processNoLongerExists,
            .executablePathPermissionDenied(errno: 1),
            .codeObjectLookupFailed(status: -67_050),
            .codeSignatureInvalid(status: -67_061),
            .malformedSigningInformation,
        ]

        for failure in failures {
            #expect(failure.requiresFailOpen)
            let result = ProcessIdentityResolution.unavailable(failure)
            #expect(result.shouldFailOpen)
            #expect(result.identity == nil)
            let encoded = try JSONEncoder().encode(result)
            #expect(try JSONDecoder().decode(ProcessIdentityResolution.self, from: encoded) == result)
        }
    }

    @Test
    func unsignedIdentityIsExplicitRatherThanSpoofingBundleIdentity() throws {
        let identity = ResolvedProcessIdentity(
            auditToken: try SourceAppAuditToken(Data(repeating: 3, count: 32)),
            processIdentifier: 900,
            processVersion: 2,
            effectiveUserID: 501,
            auditUserID: 501,
            executablePath: "/tmp/tool",
            codeSigning: .unsigned
        )
        guard case .unsigned = identity.codeSigning else {
            Issue.record("Expected an explicit unsigned identity")
            return
        }
    }
}
