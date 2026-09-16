import Foundation
@testable import MClashApp
import Testing
import UniformTypeIdentifiers

@Suite("Release packaging")
struct ReleasePackagingTests {
    private let teamIdentifier = "5UAHRS482C"

    @Test("CI serializes process-wide Apple manager tests")
    func ciDisablesSwiftTestingParallelism() throws {
        let testScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "scripts/test-direct.sh"
            ),
            encoding: .utf8
        )
        #expect(
            testScript.contains(
                "swift test --configuration debug --no-parallel"
            )
        )
    }

    @Test("AppModel tests never construct live Network Extension managers")
    func appModelTestsUseInertDependencies() throws {
        let testsDirectory = repositoryRoot.appendingPathComponent(
            "Tests/MClashTests",
            isDirectory: true
        )
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: testsDirectory,
                includingPropertiesForKeys: nil
            )
        )
        let rawInitializer = "App" + "Model("
        var violations: [String] = []
        for case let fileURL as URL in enumerator
        where fileURL.pathExtension == "swift"
            && fileURL.lastPathComponent != "AppModelTestSupport.swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let sourceWithoutFactoryCalls = source.replacingOccurrences(
                of: "makeTest" + rawInitializer,
                with: ""
            )
            if sourceWithoutFactoryCalls.contains(rawInitializer) {
                violations.append(fileURL.lastPathComponent)
            }
        }
        #expect(
            violations.isEmpty,
            "Use makeTestAppModel so command-line tests never construct live Apple managers: \(violations)"
        )
    }

    @Test("Mach service is a child of the shared macOS App Group")
    func machServiceUsesSharedAppGroupPrefix() throws {
        let hostEntitlements = try plist(
            at: repositoryRoot.appendingPathComponent(
                "Support/Signing/MClash-DeveloperID.entitlements"
            )
        )
        let extensionEntitlements = try plist(
            at: repositoryRoot.appendingPathComponent(
                "Support/NetworkExtension/MClashNetworkExtension.DeveloperID.entitlements"
            )
        )
        let extensionInfo = try plist(
            at: repositoryRoot.appendingPathComponent("Support/NetworkExtension/Info.plist")
        )

        let expectedAppGroup = "\(teamIdentifier).one.leaper.mclash"
        let hostGroups = try #require(
            hostEntitlements["com.apple.security.application-groups"] as? [String]
        )
        let extensionGroups = try #require(
            extensionEntitlements["com.apple.security.application-groups"] as? [String]
        )
        #expect(hostGroups.contains(expectedAppGroup))
        #expect(extensionGroups.contains(expectedAppGroup))

        let networkExtension = try #require(
            extensionInfo["NetworkExtension"] as? [String: Any]
        )
        let machService = try #require(networkExtension["NEMachServiceName"] as? String)
        #expect(machService == "$(TeamIdentifierPrefix)one.leaper.mclash.network-extension")
        #expect(networkExtension["NEProviderClasses"] != nil)
    }

    @Test("Developer ID signatures declare identities required for provider IPC")
    func developerIDProviderIPCIdentities() throws {
        let hostEntitlements = try plist(
            at: repositoryRoot.appendingPathComponent(
                "Support/Signing/MClash-DeveloperID.entitlements"
            )
        )
        let extensionEntitlements = try plist(
            at: repositoryRoot.appendingPathComponent(
                "Support/NetworkExtension/MClashNetworkExtension.DeveloperID.entitlements"
            )
        )

        #expect(
            hostEntitlements["com.apple.application-identifier"] as? String
                == "\(teamIdentifier).one.leaper.mclash"
        )
        #expect(
            extensionEntitlements["com.apple.application-identifier"] as? String
                == "\(teamIdentifier).one.leaper.mclash.network-extension"
        )
        #expect(
            hostEntitlements["com.apple.developer.team-identifier"] as? String
                == teamIdentifier
        )
        let keychainGroups = try #require(
            hostEntitlements["keychain-access-groups"] as? [String]
        )
        #expect(keychainGroups.contains(
            "\(teamIdentifier).one.leaper.mclash.authorization"
        ))
        #expect(
            extensionEntitlements["com.apple.developer.team-identifier"] as? String
                == teamIdentifier
        )
    }

    @Test("Host bundle registers the Proxifier PPX file type")
    func hostRegistersProxifierProfileType() throws {
        #expect(
            UTType.proxifierProfile.identifier
                == "one.leaper.mclash.proxifier-profile"
        )

        let hostInfo = try plist(at: repositoryRoot.appendingPathComponent("Support/Info.plist"))
        let declarations = try #require(
            hostInfo["UTImportedTypeDeclarations"] as? [[String: Any]]
        )
        let declaration = try #require(declarations.first(where: {
            $0["UTTypeIdentifier"] as? String
                == "one.leaper.mclash.proxifier-profile"
        }))
        let conformsTo = try #require(declaration["UTTypeConformsTo"] as? [String])
        #expect(conformsTo.contains("public.xml"))

        let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
        let extensions = try #require(tags["public.filename-extension"] as? [String])
        #expect(extensions.contains("ppx"))
    }

    @Test("Automation CLI is bundled and signed before the host application")
    func automationCLIPackagingIsInsideOut() throws {
        let buildScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        let releaseScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/release-app.sh"),
            encoding: .utf8
        )
        let cliEntitlements = try plist(
            at: repositoryRoot.appendingPathComponent(
                "Support/Signing/MClashCLI-DeveloperID.entitlements"
            )
        )
        #expect(cliEntitlements["com.apple.application-identifier"] == nil)
        #expect(cliEntitlements["com.apple.developer.team-identifier"] == nil)
        #expect(cliEntitlements["keychain-access-groups"] == nil)
        #expect(buildScript.contains("Signed mclashctl must not claim restricted entitlement"))
        #expect(releaseScript.contains("verify_unrestricted_cli_entitlements"))

        let adHocHelperSign = try #require(
            buildScript.range(
                of: "codesign --force --sign - \"${contents}/Helpers/mclashctl\""
            )
        )
        let adHocHostSign = try #require(
            buildScript.range(of: "--sign - \"${app_bundle}\"")
        )
        #expect(adHocHelperSign.lowerBound < adHocHostSign.lowerBound)
        let developerHelperSign = try #require(
            buildScript.range(
                of: "--sign \"${code_sign_identity}\" \"${contents}/Helpers/mclashctl\""
            )
        )
        let developerHostSign = try #require(
            buildScript.range(
                of: "--sign \"${code_sign_identity}\" \"${app_bundle}\""
            )
        )
        #expect(developerHelperSign.lowerBound < developerHostSign.lowerBound)
        #expect(releaseScript.contains("local automation_cli="))
        let releaseHelperSign = try #require(
            releaseScript.range(
                of: "sign_path \"${automation_cli}\" --entitlements \"${cli_devid_entitlements}\""
            )
        )
        let releaseHostSign = try #require(
            releaseScript.range(of: "sign_path \"${app}\" --entitlements")
        )
        #expect(releaseHelperSign.lowerBound < releaseHostSign.lowerBound)
    }

    @Test("Legacy login agent remains packaged only for safe migration")
    func legacyLoginAgentCanBeUnregisteredAfterUpgrade() throws {
        let agent = try plist(
            at: repositoryRoot.appendingPathComponent(
                "Support/LaunchAgents/one.leaper.mclash.login.plist"
            )
        )
        #expect(agent["BundleProgram"] as? String == "Contents/MacOS/MClash")
        let arguments = try #require(agent["ProgramArguments"] as? [String])
        #expect(arguments.contains("--mclash-background"))

        let buildScript = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        #expect(buildScript.contains("${contents}/Library/LaunchAgents"))
        #expect(buildScript.contains("one.leaper.mclash.login.plist"))

        let manager = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/MClashApp/App/LoginItemManager.swift"
            ),
            encoding: .utf8
        )
        #expect(manager.contains("SMAppService.mainApp.register()"))
        #expect(manager.contains("legacyBackgroundAgent.unregister()"))

        let hostInfo = try plist(
            at: repositoryRoot.appendingPathComponent("Support/Info.plist")
        )
        #expect(hostInfo["LSMultipleInstancesProhibited"] as? Bool == true)
    }

    @Test("Sparkle deltas are verified and published with a full fallback")
    func sparkleDeltaReleasePipeline() throws {
        let deltaScript = try source("scripts/generate-delta-updates.sh")
        let appcastScript = try source("scripts/generate-appcast.sh")
        let releaseScript = try source("scripts/release-app.sh")
        let workflow = try source(".github/workflows/release.yml")
        let toolsScript = try source("scripts/fetch-sparkle-tools.sh")

        #expect(toolsScript.contains("BinaryDelta"))
        #expect(deltaScript.contains("\"${binary_delta}\" create"))
        #expect(deltaScript.contains("\"${binary_delta}\" apply"))
        #expect(deltaScript.contains("codesign --verify --deep --strict"))
        #expect(deltaScript.contains("The full Sparkle update remains available"))
        #expect(
            deltaScript.contains(
                "target_bundle_version=\"${MCLASH_BUNDLE_VERSION:-${target_version%%[-+]*}}\""
            )
        )
        #expect(
            deltaScript.contains(
                "\"${actual_target_version}\" != \"${target_bundle_version}\""
            )
        )
        #expect(
            !deltaScript.contains(
                "\"${actual_target_version}\" != \"${target_version}\""
            )
        )
        #expect(appcastScript.contains("attach-appcast-deltas.py"))
        #expect(releaseScript.contains("xattr -cr \"${app}\""))
        #expect(releaseScript.contains("generate-delta-updates.sh"))
        #expect(releaseScript.contains("macos-arm64.delta(N)"))
        #expect(workflow.contains("macos-arm64.delta(N)"))
    }

    @Test("Xray package layout rejects every extra core")
    func xrayPackageLayoutRejectsLegacyCore() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("mclash-xray-layout-\(UUID().uuidString)")
        let app = temporary.appendingPathComponent("MClash.app")
        let core = app.appendingPathComponent("Contents/Resources/Core")
        let thirdParty = app.appendingPathComponent("Contents/Resources/ThirdParty")
        let geo = app.appendingPathComponent("Contents/Resources/GeoData")
        try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thirdParty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: geo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let info: [String: Any] = ["MClashRuntimeBackend": "xray"]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let xray = core.appendingPathComponent("mclash-xray")
        try Data("fixture".utf8).write(to: xray)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: xray.path
        )
        try Data("license".utf8).write(to: geo.appendingPathComponent("LICENSE.txt"))
        var geoManifest: [String] = []
        for name in ["geoip.dat", "geosite.dat"] {
            let file = geo.appendingPathComponent(name)
            try Data(name.utf8).write(to: file)
            let hash = try BundledGeoDataInstaller.sha256(at: file)
            geoManifest.append("\(hash)  \(name)")
        }
        try Data((geoManifest.joined(separator: "\n") + "\n").utf8)
            .write(to: geo.appendingPathComponent("XRAY-SHA256SUMS"))

        let accepted = try run(
            "/usr/bin/python3",
            [repositoryRoot.appendingPathComponent("scripts/test-xray-package-layout.py").path, app.path]
        )
        #expect(accepted.status == 0, Comment(rawValue: accepted.output))

        try Data("legacy".utf8).write(
            to: core.appendingPathComponent("mclash-mihomo")
        )
        let rejected = try run(
            "/usr/bin/python3",
            [repositoryRoot.appendingPathComponent("scripts/test-xray-package-layout.py").path, app.path]
        )
        #expect(rejected.status != 0)
        #expect(rejected.output.contains("must contain only mclash-xray"))

        let workflow = try source(".github/workflows/release.yml")
        #expect(workflow.contains("test-xray-package-layout.py"))
        #expect(workflow.contains("checksums must not contain legacy core source"))
        #expect(workflow.contains("!startsWith(needs.prepare.outputs.version, '1.6.')"))
        let buildScript = try source("scripts/build-app.sh")
        #expect(buildScript.contains("XRAY_GEOIP_RESOURCE_PATH"))
        #expect(buildScript.contains("verify-xray-geodata.sh"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func plist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> (
        status: Int32,
        output: String
    ) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        return (process.terminationStatus, output)
    }
}
