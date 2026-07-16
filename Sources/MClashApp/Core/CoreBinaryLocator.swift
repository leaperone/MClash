import Foundation

struct CoreBinaryLocator: Sendable {
    private let environment: [String: String]
    private let applicationSupportDirectory: URL
    private let bundledBinaryURLs: [URL]
    private let developmentOverridesEnabled: Bool

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL? = nil,
        bundledBinaryURLs: [URL]? = nil,
        developmentOverridesEnabled: Bool? = nil
    ) {
        self.environment = environment
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "MClash", directoryHint: .isDirectory)
        self.bundledBinaryURLs = bundledBinaryURLs ?? Self.discoverBundledBinaryURLs()
        self.developmentOverridesEnabled = developmentOverridesEnabled
            ?? (environment["MCLASH_ALLOW_CORE_OVERRIDE"] == "1")
    }

    func locate(explicitURL: URL? = nil) throws -> URL {
        let candidates = candidateURLs(explicitURL: explicitURL)
        var firstNonExecutablePath: String?

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            ) else {
                continue
            }

            if !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            firstNonExecutablePath = firstNonExecutablePath ?? candidate.path
        }

        if let firstNonExecutablePath {
            throw CoreSupervisorError.binaryNotExecutable(firstNonExecutablePath)
        }

        throw CoreSupervisorError.binaryNotFound(
            candidates.map(\.path).joined(separator: ", ")
        )
    }

    func candidateURLs(explicitURL: URL? = nil) -> [URL] {
        var candidates: [URL] = []

        if let explicitURL {
            candidates.append(explicitURL)
        }

        // A release build is self-contained. Hidden development overrides must
        // never shadow a valid, signed core shipped inside the application.
        candidates.append(contentsOf: bundledBinaryURLs)

        if developmentOverridesEnabled {
            if let environmentPath = environment["MCLASH_CORE_PATH"], !environmentPath.isEmpty {
                candidates.append(URL(filePath: environmentPath))
            }

            candidates.append(
                applicationSupportDirectory
                    .appending(path: "Core", directoryHint: .isDirectory)
                    .appending(path: "mihomo-alpha")
            )
        }

        return candidates
    }

    private static func discoverBundledBinaryURLs() -> [URL] {
        var candidates: [URL] = []

        #if SWIFT_PACKAGE
        if let packaged = Bundle.module.url(
            forResource: bundledResourceName,
            withExtension: nil,
            subdirectory: "Core"
        ) {
            candidates.append(packaged)
        }
        #endif

        if let bundled = Bundle.main.url(
            forResource: bundledResourceName,
            withExtension: nil,
            subdirectory: "Core"
        ) {
            candidates.append(bundled)
        }

        return candidates
    }

    static var bundledResourceName: String {
        #if arch(arm64)
        "mihomo-alpha-darwin-arm64"
        #elseif arch(x86_64)
        "mihomo-alpha-darwin-amd64-compatible"
        #else
        "mihomo-alpha-darwin-unsupported"
        #endif
    }
}
