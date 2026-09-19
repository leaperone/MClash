import Foundation
import Testing
@testable import MClashApp

@Suite("Bundled GEO data installer")
struct BundledGeoDataInstallerTests {
    @Test("Application bundle discovery installs the Xray-only resource manifest")
    func discoversXrayApplicationResources() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Fixture.app")
        let source = app.appending(path: "Contents/Resources/GeoData")
        let runtime = root.appending(path: "runtime")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "one.leaper.mclash.geodata-fixture", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        var manifest: [String] = []
        for name in BundledGeoDataInstaller.xrayFileNames {
            let file = source.appending(path: name)
            try Data(name.utf8).write(to: file)
            manifest.append("\(try BundledGeoDataInstaller.sha256(at: file))  \(name)")
        }
        try Data(manifest.joined(separator: "\n").utf8).write(to: source.appending(path: "XRAY-SHA256SUMS"))
        let bundle = try #require(Bundle(url: app))

        try BundledGeoDataInstaller.applicationBundle(bundle).installIfNeeded(into: runtime)

        for name in BundledGeoDataInstaller.xrayFileNames {
            #expect(FileManager.default.fileExists(atPath: runtime.appending(path: name).path))
        }
    }

    @Test("Packaged Xray builds report missing GEO resources instead of skipping installation")
    func missingPackagedResourcesFail() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "MissingResources.app")
        try FileManager.default.createDirectory(
            at: app.appending(path: "Contents/Resources"),
            withIntermediateDirectories: true
        )
        let info = [
            "CFBundleIdentifier": "one.leaper.mclash.geodata-missing-fixture",
            "CFBundlePackageType": "APPL",
            "MClashRuntimeBackend": "xray",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        let bundle = try #require(Bundle(url: app))

        #expect(throws: BundledGeoDataError.manifestMissing) {
            try BundledGeoDataInstaller.applicationBundle(bundle)
                .installIfNeeded(into: root.appending(path: "runtime"))
        }
    }

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

    @Test("Xray snapshots install lowercase GEO databases without legacy aliases")
    func installsXraySnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-xray-geodata-test-\(UUID().uuidString)")
        let source = root.appending(path: "bundle")
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var manifest: [String] = []
        for fileName in BundledGeoDataInstaller.xrayFileNames {
            let file = source.appending(path: fileName)
            try Data("xray-\(fileName)".utf8).write(to: file)
            manifest.append("\(try BundledGeoDataInstaller.sha256(at: file))  \(fileName)")
        }
        try Data((manifest.joined(separator: "\n") + "\n").utf8)
            .write(to: source.appending(path: "XRAY-SHA256SUMS"))

        try BundledGeoDataInstaller(sourceDirectory: source).installIfNeeded(into: home)

        for fileName in BundledGeoDataInstaller.xrayFileNames {
            #expect(FileManager.default.fileExists(atPath: home.appending(path: fileName).path))
        }
        let names = try Set(FileManager.default.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent))
        #expect(names == Set(BundledGeoDataInstaller.xrayFileNames))
    }

    @Test("Xray snapshot replaces stale capitalized databases from an older runtime")
    func replacesStaleXrayDatabase() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mclash-xray-geodata-migration-\(UUID().uuidString)")
        let source = root.appending(path: "bundle")
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var manifest: [String] = []
        for fileName in BundledGeoDataInstaller.xrayFileNames {
            let file = source.appending(path: fileName)
            try Data("new-\(fileName)".utf8).write(to: file)
            manifest.append("\(try BundledGeoDataInstaller.sha256(at: file))  \(fileName)")
        }
        try Data((manifest.joined(separator: "\n") + "\n").utf8)
            .write(to: source.appending(path: "XRAY-SHA256SUMS"))
        try Data("old-mihomo-data".utf8).write(to: home.appending(path: "GeoIP.dat"))

        try BundledGeoDataInstaller(sourceDirectory: source).installIfNeeded(into: home)

        #expect(try Data(contentsOf: home.appending(path: "geoip.dat")) == Data("new-geoip.dat".utf8))
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
