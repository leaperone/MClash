import AppKit
import Darwin
import Foundation
import MClashNetworkShared
import Security

struct ApplicationCaptureCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let bundleIdentifier: String?
    let executablePath: String
    let runningProcessIdentifiers: [Int32]
    let matcher: ApplicationSourceMatcher
    /// Exact identifiers that macOS may publish for this application and its
    /// app-specific helper executables when full process inspection is not
    /// available. These are deliberately exact values, never wildcards.
    let fallbackIdentifierPatterns: [String]

    init(
        id: String,
        displayName: String,
        bundleIdentifier: String?,
        executablePath: String,
        runningProcessIdentifiers: [Int32],
        matcher: ApplicationSourceMatcher,
        fallbackIdentifierPatterns: [String]? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.runningProcessIdentifiers = runningProcessIdentifiers
        self.matcher = matcher
        self.fallbackIdentifierPatterns = Self.normalizedFallbackPatterns(
            fallbackIdentifierPatterns ?? [bundleIdentifier, matcher.signingIdentifier].compactMap { $0 }
        )
    }

    private static func normalizedFallbackPatterns(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty,
                  (try? ApplicationIdentifierPatternMatcher(pattern: normalized)) != nil,
                  seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }
}

struct RunningProcessCaptureCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let processIdentifier: Int32
    let executablePath: String
    let matcher: ProcessInstanceSourceMatcher
}

struct ApplicationCaptureCandidates: Equatable, Sendable {
    let applications: [ApplicationCaptureCandidate]
    let processes: [RunningProcessCaptureCandidate]
}

private struct RunningApplicationCaptureSnapshot: Sendable {
    let bundleURL: URL
    let displayName: String?
    let processIdentifiers: [pid_t]
}

enum ApplicationCaptureCandidateError: Error, Equatable, LocalizedError, Sendable {
    case missingExecutable(URL)
    case codeObjectLookupFailed(status: Int32)
    case invalidCodeSignature(status: Int32)
    case signingInformationFailed(status: Int32)
    case unsignedApplication(URL)
    case designatedRequirementFailed(status: Int32)
    case requirementStringFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case let .missingExecutable(url):
            "No executable was found for \(url.lastPathComponent)."
        case let .codeObjectLookupFailed(status):
            "The application code object could not be opened (OSStatus \(status))."
        case let .invalidCodeSignature(status):
            "The application code signature is invalid (OSStatus \(status))."
        case let .signingInformationFailed(status):
            "The application signing identity could not be read (OSStatus \(status))."
        case let .unsignedApplication(url):
            "\(url.lastPathComponent) is unsigned and cannot be selected as an application rule. Use an executable-path rule instead."
        case let .designatedRequirementFailed(status):
            "The application designated requirement could not be read (OSStatus \(status))."
        case let .requirementStringFailed(status):
            "The application designated requirement could not be serialized (OSStatus \(status))."
        }
    }
}

/// Produces security-stable application matchers. Bundle identifiers are only
/// labels; the designated requirement remains the primary matching identity.
struct ApplicationCaptureCandidateProvider: Sendable {
    @MainActor
    func loadRunningCandidates() async -> ApplicationCaptureCandidates {
        let snapshots = runningApplicationSnapshots()
        let discoveryTask = Task.detached(priority: .userInitiated) {
            let applications = applications(from: snapshots)
            guard !Task.isCancelled else {
                return ApplicationCaptureCandidates(applications: [], processes: [])
            }
            return ApplicationCaptureCandidates(
                applications: applications,
                processes: runningProcesses(from: applications)
            )
        }
        return await withTaskCancellationHandler {
            await discoveryTask.value
        } onCancel: {
            discoveryTask.cancel()
        }
    }

    @MainActor
    func runningApplications() -> [ApplicationCaptureCandidate] {
        applications(from: runningApplicationSnapshots())
    }

    @MainActor
    private func runningApplicationSnapshots() -> [RunningApplicationCaptureSnapshot] {
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited && $0.bundleURL != nil
        }
        let grouped = Dictionary(grouping: applications) { application in
            application.bundleURL?.standardizedFileURL.path ?? ""
        }

        return grouped.compactMap { path, applications in
            guard !path.isEmpty,
                  let bundleURL = applications.first?.bundleURL
            else {
                return nil
            }
            return RunningApplicationCaptureSnapshot(
                bundleURL: bundleURL,
                displayName: applications.first?.localizedName,
                processIdentifiers: applications.map(\.processIdentifier)
            )
        }
    }

    private func applications(
        from snapshots: [RunningApplicationCaptureSnapshot]
    ) -> [ApplicationCaptureCandidate] {
        snapshots.compactMap { snapshot in
            guard !Task.isCancelled else { return nil }
            return try? candidate(
                bundleURL: snapshot.bundleURL,
                displayName: snapshot.displayName,
                processIdentifiers: snapshot.processIdentifiers
            )
        }
        .sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func candidate(
        bundleURL: URL,
        displayName: String? = nil,
        processIdentifiers: [pid_t] = []
    ) throws -> ApplicationCaptureCandidate {
        let canonicalBundleURL = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard let executableURL = Bundle(url: canonicalBundleURL)?.executableURL else {
            throw ApplicationCaptureCandidateError.missingExecutable(canonicalBundleURL)
        }
        let identity = try codeIdentity(at: canonicalBundleURL)
        let bundleIdentifier = Bundle(url: canonicalBundleURL)?.bundleIdentifier
            ?? identity.securedBundleIdentifier
        let fallbackIdentifierPatterns = applicationIdentifierPatterns(
            bundleURL: canonicalBundleURL,
            primaryIdentity: identity,
            bundleIdentifier: bundleIdentifier
        )
        let matcher = ApplicationSourceMatcher(
            designatedRequirement: identity.designatedRequirement,
            signingIdentifier: identity.signingIdentifier,
            teamIdentifier: identity.teamIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String
        if let name, !name.isEmpty {
            resolvedName = name
        } else {
            resolvedName = (Bundle(url: canonicalBundleURL)?.object(
                forInfoDictionaryKey: "CFBundleDisplayName"
            ) as? String) ?? canonicalBundleURL.deletingPathExtension().lastPathComponent
        }

        return ApplicationCaptureCandidate(
            id: canonicalBundleURL.path,
            displayName: resolvedName,
            bundleIdentifier: bundleIdentifier,
            executablePath: executableURL.resolvingSymlinksInPath().standardizedFileURL.path,
            runningProcessIdentifiers: Array(Set(processIdentifiers.map { Int32($0) })).sorted(),
            matcher: matcher,
            fallbackIdentifierPatterns: fallbackIdentifierPatterns
        )
    }

    /// Returns exact, app-owned signing identifiers for the main application
    /// and a bounded set of conventional helper locations. This covers tools
    /// such as an app-bundled CLI without creating generic `node`/shell rules
    /// that could capture unrelated applications.
    private func applicationIdentifierPatterns(
        bundleURL: URL,
        primaryIdentity: SignedCodeIdentity,
        bundleIdentifier: String?
    ) -> [String] {
        var values = [bundleIdentifier, primaryIdentity.signingIdentifier].compactMap { $0 }
        guard let teamIdentifier = primaryIdentity.teamIdentifier, !teamIdentifier.isEmpty else {
            return values
        }

        for executableURL in helperExecutableURLs(in: bundleURL) {
            guard let identity = try? codeIdentity(at: executableURL),
                  identity.teamIdentifier == teamIdentifier,
                  Self.isAppSpecificHelperIdentifier(identity.signingIdentifier) else {
                continue
            }
            values.append(identity.signingIdentifier)
            if let securedBundleIdentifier = identity.securedBundleIdentifier {
                values.append(securedBundleIdentifier)
            }
        }
        return values
    }

    private func helperExecutableURLs(in bundleURL: URL) -> [URL] {
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let fileManager = FileManager.default
        var result: [URL] = []
        var seen: Set<String> = []

        // CLI-style helpers are commonly placed directly in one of these
        // folders. Keep the scan shallow and bounded so opening the editor does
        // not walk an application's dependency tree.
        for directoryName in ["MacOS", "Helpers", "Resources"] {
            let directory = contentsURL.appendingPathComponent(directoryName, isDirectory: true)
            let children = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children.prefix(256) {
                let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile == true,
                      values?.isSymbolicLink != true,
                      fileManager.isExecutableFile(atPath: child.path),
                      seen.insert(child.standardizedFileURL.path).inserted else {
                    continue
                }
                result.append(child)
            }
        }

        // Also include the main executable of conventional nested code
        // bundles, while avoiding recursive inspection of their resources.
        let packageContainers = ["Frameworks", "PlugIns", "XPCServices", "Library/LoginItems"]
        let packageExtensions: Set<String> = ["app", "appex", "plugin", "xpc"]
        for relativePath in packageContainers {
            let container = contentsURL.appendingPathComponent(relativePath, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: container,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }
            var inspectedPackages = 0
            while let candidate = enumerator.nextObject() as? URL, inspectedPackages < 128 {
                guard packageExtensions.contains(candidate.pathExtension.lowercased()) else {
                    continue
                }
                enumerator.skipDescendants()
                inspectedPackages += 1
                guard let executable = Bundle(url: candidate)?.executableURL,
                      seen.insert(executable.standardizedFileURL.path).inserted else {
                    continue
                }
                result.append(executable)
            }
        }
        return result
    }

    private static func isAppSpecificHelperIdentifier(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let genericIdentifiers: Set<String> = [
            "bash", "bun", "corepack", "curl", "dash", "deno", "fish", "git", "helper",
            "node", "npm", "npx", "perl", "php", "python", "python3", "rg", "ruby",
            "sh", "ssh", "wget", "zsh",
        ]
        return !normalized.isEmpty && !genericIdentifiers.contains(normalized)
    }

    func runningProcesses(
        from applications: [ApplicationCaptureCandidate]
    ) -> [RunningProcessCaptureCandidate] {
        let applicationByPID = Dictionary(uniqueKeysWithValues: applications.flatMap { application in
            application.runningProcessIdentifiers.map { ($0, application) }
        })
        return allProcessIdentifiers().compactMap { processIdentifier in
            guard !Task.isCancelled,
                  let firstStartTime = processStartTime(for: processIdentifier),
                  let executablePath = executablePath(for: processIdentifier),
                  processStartTime(for: processIdentifier) == firstStartTime else {
                return nil
            }
            let path = URL(fileURLWithPath: executablePath)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            let matcher = ProcessInstanceSourceMatcher(
                processIdentifier: processIdentifier,
                startTime: firstStartTime,
                canonicalExecutablePath: path
            )
            let name = applicationByPID[processIdentifier]?.displayName
                ?? URL(fileURLWithPath: path).lastPathComponent
            return RunningProcessCaptureCandidate(
                id: "\(processIdentifier):\(firstStartTime.seconds):\(firstStartTime.microseconds)",
                displayName: "\(name) · PID \(processIdentifier)",
                processIdentifier: processIdentifier,
                executablePath: path,
                matcher: matcher
            )
        }
        .sorted {
            let nameOrder = $0.displayName.localizedStandardCompare($1.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.processIdentifier < $1.processIdentifier
        }
    }

    private func allProcessIdentifiers() -> [pid_t] {
        let requiredBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requiredBytes > 0 else { return [] }
        let elementSize = MemoryLayout<pid_t>.size
        // Leave headroom for processes created between the sizing and fill calls.
        var identifiers = [pid_t](
            repeating: 0,
            count: (Int(requiredBytes) / elementSize) + 64
        )
        let capacity = identifiers.count * elementSize
        let actualBytes = identifiers.withUnsafeMutableBytes { buffer in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buffer.baseAddress,
                Int32(capacity)
            )
        }
        guard actualBytes > 0 else { return [] }
        return Array(identifiers.prefix(Int(actualBytes) / elementSize)).filter { $0 > 0 }
    }

    private func executablePath(for processIdentifier: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let byteCount = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(processIdentifier, pointer.baseAddress, UInt32(pointer.count))
        }
        guard byteCount > 0 else { return nil }
        let bytes = buffer.prefix(min(Int(byteCount), buffer.count))
            .prefix { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        return path.isEmpty ? nil : path
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

    private func codeIdentity(at bundleURL: URL) throws -> SignedCodeIdentity {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw ApplicationCaptureCandidateError.codeObjectLookupFailed(status: createStatus)
        }

        let validationFlags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSDoNotValidateResources
        )
        let validityStatus = SecStaticCodeCheckValidity(staticCode, validationFlags, nil)
        if validityStatus == errSecCSUnsigned {
            throw ApplicationCaptureCandidateError.unsignedApplication(bundleURL)
        }
        guard validityStatus == errSecSuccess else {
            throw ApplicationCaptureCandidateError.invalidCodeSignature(status: validityStatus)
        }

        var signingInformation: CFDictionary?
        let signingStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation),
            &signingInformation
        )
        guard signingStatus == errSecSuccess,
              let information = signingInformation as NSDictionary?,
              let signingIdentifier = information[kSecCodeInfoIdentifier] as? String
        else {
            throw ApplicationCaptureCandidateError.signingInformationFailed(status: signingStatus)
        }

        var requirement: SecRequirement?
        let requirementStatus = SecCodeCopyDesignatedRequirement(
            staticCode,
            SecCSFlags(),
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            throw ApplicationCaptureCandidateError.designatedRequirementFailed(
                status: requirementStatus
            )
        }
        var requirementText: CFString?
        let stringStatus = SecRequirementCopyString(
            requirement,
            SecCSFlags(),
            &requirementText
        )
        guard stringStatus == errSecSuccess,
              let designatedRequirement = requirementText as String?,
              !designatedRequirement.isEmpty
        else {
            throw ApplicationCaptureCandidateError.requirementStringFailed(status: stringStatus)
        }

        let securedInfo = information[kSecCodeInfoPList] as? NSDictionary
        return SignedCodeIdentity(
            signingIdentifier: signingIdentifier,
            teamIdentifier: information[kSecCodeInfoTeamIdentifier] as? String,
            designatedRequirement: designatedRequirement,
            codeDirectoryHash: information[kSecCodeInfoUnique] as? Data,
            securedBundleIdentifier: securedInfo?["CFBundleIdentifier"] as? String,
            mainExecutablePath: (information[kSecCodeInfoMainExecutable] as? URL)?.path,
            isApplePlatformCode: information[kSecCodeInfoPlatformIdentifier] != nil
        )
    }
}
