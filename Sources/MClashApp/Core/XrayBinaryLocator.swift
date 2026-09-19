import Foundation

struct XrayBinaryLocator: Sendable {
    private let environment: [String: String]
    private let bundledURL: URL?

    init(environment: [String: String] = ProcessInfo.processInfo.environment, bundledURL: URL? = nil) {
        self.environment = environment
        self.bundledURL = bundledURL ?? Bundle.main.url(forResource: "mclash-xray", withExtension: nil, subdirectory: "Core")
    }

    func locate() throws -> URL {
        if let bundledURL, FileManager.default.isExecutableFile(atPath: bundledURL.path) { return bundledURL }
        if environment["MCLASH_ALLOW_CORE_OVERRIDE"] == "1" || environment["MCLASH_TEST_MODE"] == "1",
           let path = environment["MCLASH_XRAY_BINARY"], FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw CoreSupervisorError.binaryNotFound("MClash.app/Contents/Resources/Core/mclash-xray")
    }
}
