import CryptoKit
import Foundation

/// Seeds mihomo's private homes with the release-bundled GEO databases.
/// Existing non-empty files are preserved so mihomo or the user can update
/// them independently after installation.
struct BundledGeoDataInstaller: Sendable {
    static let requiredFileNames = [
        "geoip.metadb",
        "GeoIP.dat",
        "GeoSite.dat",
        "ASN.mmdb",
    ]

    private let sourceDirectory: URL?

    init(sourceDirectory: URL?) {
        self.sourceDirectory = sourceDirectory?.standardizedFileURL
    }

    static func applicationBundle() -> BundledGeoDataInstaller {
        var candidates: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appending(path: "GeoData", directoryHint: .isDirectory))
        }

        #if SWIFT_PACKAGE
        if let resourceURL = Bundle.module.resourceURL {
            candidates.append(resourceURL.appending(path: "GeoData", directoryHint: .isDirectory))
            candidates.append(resourceURL)
        }
        #endif

        let source = candidates.first {
            FileManager.default.fileExists(
                atPath: $0.appending(path: "SHA256SUMS").path
            )
        }
        return BundledGeoDataInstaller(sourceDirectory: source)
    }

    func installIfNeeded(
        into homeDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        // SwiftPM development and focused unit-test builds intentionally do
        // not download release assets. A production .app is required by the
        // build script to contain this directory.
        guard let sourceDirectory else { return }

        let expectedHashes = try readManifest(
            at: sourceDirectory.appending(path: "SHA256SUMS")
        )
        guard Set(expectedHashes.keys) == Set(Self.requiredFileNames) else {
            throw BundledGeoDataError.incompleteManifest
        }

        // Validate the complete bundled snapshot before changing either home.
        for fileName in Self.requiredFileNames {
            let source = sourceDirectory.appending(path: fileName)
            guard fileManager.fileExists(atPath: source.path) else {
                throw BundledGeoDataError.missingBundledFile(fileName)
            }
            let actualHash = try Self.sha256(at: source)
            guard actualHash == expectedHashes[fileName] else {
                throw BundledGeoDataError.integrityMismatch(fileName)
            }
        }

        try fileManager.createDirectory(
            at: homeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        for fileName in Self.requiredFileNames {
            let destination = homeDirectory.appending(path: fileName)
            if fileManager.fileExists(atPath: destination.path) {
                let attributes = try fileManager.attributesOfItem(atPath: destination.path)
                if (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 {
                    continue
                }
                try fileManager.removeItem(at: destination)
            }

            let staged = homeDirectory.appending(
                path: ".mclash-\(fileName)-\(UUID().uuidString).tmp"
            )
            do {
                try fileManager.copyItem(
                    at: sourceDirectory.appending(path: fileName),
                    to: staged
                )
                try fileManager.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: staged.path
                )
                try fileManager.moveItem(at: staged, to: destination)
            } catch {
                try? fileManager.removeItem(at: staged)
                throw error
            }
        }
    }

    static func sha256(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func readManifest(at url: URL) throws -> [String: String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw BundledGeoDataError.manifestMissing
        }

        var result: [String: String] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2 else {
                throw BundledGeoDataError.invalidManifest
            }
            let hash = String(fields[0]).lowercased()
            let fileName = String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard hash.count == 64,
                  hash.allSatisfy(\.isHexDigit),
                  Self.requiredFileNames.contains(fileName),
                  result[fileName] == nil else {
                throw BundledGeoDataError.invalidManifest
            }
            result[fileName] = hash
        }
        return result
    }
}

enum BundledGeoDataError: Error, Equatable {
    case manifestMissing
    case invalidManifest
    case incompleteManifest
    case missingBundledFile(String)
    case integrityMismatch(String)
}

extension BundledGeoDataError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .manifestMissing:
            "The bundled GEO database manifest is missing."
        case .invalidManifest:
            "The bundled GEO database manifest is invalid."
        case .incompleteManifest:
            "The bundled GEO database snapshot is incomplete."
        case let .missingBundledFile(fileName):
            "The bundled GEO database \(fileName) is missing."
        case let .integrityMismatch(fileName):
            "The bundled GEO database \(fileName) failed its integrity check."
        }
    }
}
