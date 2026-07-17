import Foundation
import Testing
@testable import MClashApp

@Suite("Bundled GEO data installer")
struct BundledGeoDataInstallerTests {
    @Test("Missing GEO files are seeded while existing updates are preserved")
    func installsOnlyMissingFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let existing = fixture.home.appending(path: "GeoSite.dat")
        try Data("user-updated-geosite".utf8).write(to: existing)

        try fixture.installer.installIfNeeded(into: fixture.home)

        for fileName in BundledGeoDataInstaller.requiredFileNames {
            let destination = fixture.home.appending(path: fileName)
            #expect(FileManager.default.fileExists(atPath: destination.path))
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "user-updated-geosite")
        #expect(
            try String(
                contentsOf: fixture.home.appending(path: "geoip.metadb"),
                encoding: .utf8
            ) == "bundled-geoip.metadb"
        )
    }

    @Test("An empty destination is repaired from the bundle")
    func replacesEmptyDestination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let empty = fixture.home.appending(path: "GeoIP.dat")
        FileManager.default.createFile(atPath: empty.path, contents: Data())

        try fixture.installer.installIfNeeded(into: fixture.home)

        #expect(try Data(contentsOf: empty) == Data("bundled-GeoIP.dat".utf8))
    }

    @Test("A tampered bundled snapshot fails before changing the core home")
    func rejectsTamperedBundle() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("tampered".utf8).write(
            to: fixture.source.appending(path: "ASN.mmdb")
        )

        #expect(throws: BundledGeoDataError.integrityMismatch("ASN.mmdb")) {
            try fixture.installer.installIfNeeded(into: fixture.home)
        }
        for fileName in BundledGeoDataInstaller.requiredFileNames {
            #expect(!FileManager.default.fileExists(
                atPath: fixture.home.appending(path: fileName).path
            ))
        }
    }

    @Test("Development builds without bundled release data remain usable")
    func missingDevelopmentBundleIsNoOp() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try BundledGeoDataInstaller(sourceDirectory: nil).installIfNeeded(into: root)

        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "mclash-geodata-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let home: URL
        let installer: BundledGeoDataInstaller

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "mclash-geodata-test-\(UUID().uuidString)", directoryHint: .isDirectory)
            source = root.appending(path: "bundle", directoryHint: .isDirectory)
            home = root.appending(path: "home", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

            var manifest: [String] = []
            for fileName in BundledGeoDataInstaller.requiredFileNames {
                let file = source.appending(path: fileName)
                try Data("bundled-\(fileName)".utf8).write(to: file)
                manifest.append("\(try BundledGeoDataInstaller.sha256(at: file))  \(fileName)")
            }
            try Data((manifest.joined(separator: "\n") + "\n").utf8).write(
                to: source.appending(path: "SHA256SUMS")
            )
            installer = BundledGeoDataInstaller(sourceDirectory: source)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
