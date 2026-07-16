import Foundation

struct CoreBinaryLocator: Sendable {
    private let environment: [String: String]
    private let applicationSupportDirectory: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL? = nil
    ) {
        self.environment = environment
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "MClash", directoryHint: .isDirectory)
    }

    func locate(explicitURL: URL? = nil) throws -> URL {
        let candidates = candidateURLs(explicitURL: explicitURL)

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
                throw CoreSupervisorError.binaryNotExecutable(candidate.path)
            }
            return candidate
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

        if let environmentPath = environment["MCLASH_CORE_PATH"], !environmentPath.isEmpty {
            candidates.append(URL(filePath: environmentPath))
        }

        #if SWIFT_PACKAGE
        if let packaged = Bundle.module.url(
            forResource: Self.bundledResourceName,
            withExtension: nil,
            subdirectory: "Core"
        ) {
            candidates.append(packaged)
        }
        #endif

        if let bundled = Bundle.main.url(
            forResource: Self.bundledResourceName,
            withExtension: nil,
            subdirectory: "Core"
        ) {
            candidates.append(bundled)
        }

        candidates.append(
            applicationSupportDirectory
                .appending(path: "Core", directoryHint: .isDirectory)
                .appending(path: "mihomo-alpha")
        )

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
