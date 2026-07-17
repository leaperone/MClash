import Darwin
import Foundation
import MClashNetworkShared
import Security

/// Resolves `NEFlowMetaData.sourceAppAuditToken` without consulting a reusable PID.
/// All process and code-signing lookups remain tied to the original audit token.
public struct ProcessIdentityResolver: Sendable {
    public init() {}

    /// Returns `.unavailable` rather than a partially trusted identity. A transparent
    /// proxy provider must respond to that case by bypassing the flow (`return false`).
    public func resolve(sourceAppAuditToken data: Data) -> ProcessIdentityResolution {
        do {
            return .resolved(try resolveOrThrow(sourceAppAuditToken: data))
        } catch let failure as ProcessIdentityResolutionFailure {
            return .unavailable(failure)
        } catch {
            // Every operation below maps to a typed failure. This is a defensive
            // fallback that preserves fail-open behavior if that invariant changes.
            return .unavailable(.malformedSigningInformation)
        }
    }

    public func resolveOrThrow(sourceAppAuditToken data: Data) throws -> ResolvedProcessIdentity {
        let sdkTokenSize = MemoryLayout<audit_token_t>.size
        guard sdkTokenSize == SourceAppAuditToken.byteCount else {
            throw ProcessIdentityResolutionFailure.unsupportedAuditTokenLayout(
                expected: SourceAppAuditToken.byteCount,
                actual: sdkTokenSize
            )
        }
        let tokenValue = try SourceAppAuditToken(data)
        var auditToken = audit_token_t()
        _ = withUnsafeMutableBytes(of: &auditToken) { destination in
            data.copyBytes(to: destination)
        }

        let pid = audit_token_to_pid(auditToken)
        guard pid > 0 else {
            throw ProcessIdentityResolutionFailure.invalidProcessIdentifier(pid)
        }
        let effectiveUserID = audit_token_to_euid(auditToken)
        let auditUserID = audit_token_to_auid(auditToken)
        let processVersion = audit_token_to_pidversion(auditToken)
        let processStartTime = processStartTime(for: pid)
        let executablePath = try executablePath(for: &auditToken)
        let codeSigning = try codeSigningIdentity(auditTokenData: data)

        return ResolvedProcessIdentity(
            auditToken: tokenValue,
            processIdentifier: pid,
            processVersion: processVersion,
            processStartTime: processStartTime,
            effectiveUserID: effectiveUserID,
            auditUserID: auditUserID,
            executablePath: executablePath,
            codeSigning: codeSigning
        )
    }

    private func processStartTime(for processIdentifier: pid_t) -> ProcessStartTime? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let actualSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        guard actualSize == expectedSize else { return nil }
        return try? ProcessStartTime(
            seconds: info.pbi_start_tvsec,
            microseconds: UInt32(info.pbi_start_tvusec)
        )
    }

    private func executablePath(for auditToken: inout audit_token_t) throws -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let byteCount = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath_audittoken(&auditToken, pointer.baseAddress, UInt32(pointer.count))
        }
        let capturedErrno = errno
        guard byteCount > 0 else {
            switch capturedErrno {
            case ESRCH:
                throw ProcessIdentityResolutionFailure.processNoLongerExists
            case EPERM, EACCES:
                throw ProcessIdentityResolutionFailure.executablePathPermissionDenied(errno: capturedErrno)
            default:
                throw ProcessIdentityResolutionFailure.executablePathUnavailable(errno: capturedErrno)
            }
        }

        let bytes = buffer.prefix(min(Int(byteCount), buffer.count))
            .prefix { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        guard !path.isEmpty else {
            throw ProcessIdentityResolutionFailure.emptyExecutablePath
        }
        return path
    }

    private func codeSigningIdentity(auditTokenData: Data) throws -> ProcessCodeSigningIdentity {
        let attributes = [kSecGuestAttributeAudit: auditTokenData as CFData] as CFDictionary
        var dynamicCode: SecCode?
        let lookupStatus = SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &dynamicCode
        )
        guard lookupStatus == errSecSuccess, let dynamicCode else {
            throw ProcessIdentityResolutionFailure.codeObjectLookupFailed(status: lookupStatus)
        }

        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw ProcessIdentityResolutionFailure.staticCodeLookupFailed(status: staticStatus)
        }

        let validationFlags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSDoNotValidateResources
        )
        let validityStatus = SecCodeCheckValidity(dynamicCode, validationFlags, nil)
        if validityStatus != errSecSuccess, validityStatus != errSecCSUnsigned {
            throw ProcessIdentityResolutionFailure.codeSignatureInvalid(status: validityStatus)
        }

        var signingInformation: CFDictionary?
        let signingFlags = SecCSFlags(
            rawValue: kSecCSSigningInformation | kSecCSRequirementInformation
        )
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            signingFlags,
            &signingInformation
        )
        guard informationStatus == errSecSuccess, let signingInformation else {
            throw ProcessIdentityResolutionFailure.signingInformationFailed(status: informationStatus)
        }
        let information = signingInformation as NSDictionary

        guard let signingIdentifier = information[kSecCodeInfoIdentifier] as? String else {
            if validityStatus == errSecCSUnsigned {
                return .unsigned
            }
            throw ProcessIdentityResolutionFailure.malformedSigningInformation
        }

        var requirement: SecRequirement?
        let requirementStatus = SecCodeCopyDesignatedRequirement(
            staticCode,
            SecCSFlags(),
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            throw ProcessIdentityResolutionFailure.designatedRequirementFailed(status: requirementStatus)
        }

        var requirementText: CFString?
        let requirementStringStatus = SecRequirementCopyString(
            requirement,
            SecCSFlags(),
            &requirementText
        )
        guard requirementStringStatus == errSecSuccess,
              let designatedRequirement = requirementText as String?,
              !designatedRequirement.isEmpty
        else {
            throw ProcessIdentityResolutionFailure.requirementStringFailed(status: requirementStringStatus)
        }

        let securedInfo = information[kSecCodeInfoPList] as? NSDictionary
        let securedBundleIdentifier = securedInfo?["CFBundleIdentifier"] as? String
        let mainExecutablePath = (information[kSecCodeInfoMainExecutable] as? URL)?.path
        let teamIdentifier = information[kSecCodeInfoTeamIdentifier] as? String
        let codeDirectoryHash = information[kSecCodeInfoUnique] as? Data
        let isApplePlatformCode = information[kSecCodeInfoPlatformIdentifier] != nil

        return .signed(SignedCodeIdentity(
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier,
            designatedRequirement: designatedRequirement,
            codeDirectoryHash: codeDirectoryHash,
            securedBundleIdentifier: securedBundleIdentifier,
            mainExecutablePath: mainExecutablePath,
            isApplePlatformCode: isApplePlatformCode
        ))
    }
}
