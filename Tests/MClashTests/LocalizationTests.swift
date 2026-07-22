import Foundation
@testable import MClashApp
import Testing

@Suite("Localization resources")
struct LocalizationTests {
    private let languageIdentifiers = [
        "en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es",
    ]

    @Test("Language picker and bundle declare the same eight languages")
    func declaredLanguagesMatchPicker() throws {
        #expect(
            Set(AppLanguage.allCases.compactMap { language in
                language == .system ? nil : language.rawValue
            }) == Set(languageIdentifiers)
        )

        let info = try dictionary(
            at: repositoryRoot.appendingPathComponent("Support/Info.plist")
        )
        let declared = try #require(info["CFBundleLocalizations"] as? [String])
        #expect(Set(declared) == Set(languageIdentifiers))
        #expect(info["CFBundleDevelopmentRegion"] as? String == "en")
    }

    @Test("Every localization has the complete non-empty English key set")
    func localizationKeysAreComplete() throws {
        let resourceRoot = repositoryRoot.appendingPathComponent(
            "Sources/MClashApp/Resources"
        )
        let english = try strings(
            at: resourceRoot.appendingPathComponent("en.lproj/Localizable.strings")
        )
        let englishInfo = try strings(
            at: resourceRoot.appendingPathComponent("en.lproj/InfoPlist.strings")
        )
        #expect(!english.isEmpty)
        #expect(!englishInfo.isEmpty)

        for identifier in languageIdentifiers {
            let localizationURL = resourceRoot.appendingPathComponent(
                "\(identifier).lproj/Localizable.strings"
            )
            let localized = try strings(at: localizationURL)
            #expect(Set(localized.keys) == Set(english.keys), "Incomplete \(identifier) localization")
            #expect(
                localized.values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                "Empty \(identifier) localization"
            )
            #expect(
                try localizationEntryCount(at: localizationURL) == localized.count,
                "Duplicate \(identifier) localization key"
            )
            for (key, englishValue) in english {
                #expect(
                    formatSpecifiers(in: localized[key] ?? "")
                        == formatSpecifiers(in: englishValue),
                    "Invalid format specifiers for \(identifier): \(key)"
                )
            }

            let localizedInfo = try strings(
                at: resourceRoot.appendingPathComponent(
                    "\(identifier).lproj/InfoPlist.strings"
                )
            )
            #expect(
                Set(localizedInfo.keys) == Set(englishInfo.keys),
                "Incomplete \(identifier) Info.plist localization"
            )
        }
    }

    @Test("Manual application assembly copies localization bundles")
    func buildScriptCopiesLocalizations() throws {
        let script = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        #expect(script.contains("Sources/MClashApp/Resources/*.lproj"))
        #expect(script.contains("${contents}/Resources/${localization_source:t}"))
    }

    @Test("SwiftPM declares English as the default localization")
    func packageDeclaresDefaultLocalization() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        #expect(manifest.contains("defaultLocalization: \"en\""))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func dictionary(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
    }

    private func strings(at url: URL) throws -> [String: String] {
        try #require(dictionary(at: url) as? [String: String])
    }

    private func localizationEntryCount(at url: URL) throws -> Int {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { $0.hasPrefix("\"") && $0.contains("\" = \"") }
            .count
    }

    private func formatSpecifiers(in value: String) -> [String] {
        let expression = try? NSRegularExpression(pattern: "%(?:@|d)")
        let range = NSRange(value.startIndex..., in: value)
        return expression?.matches(in: value, range: range).compactMap { match in
            Range(match.range, in: value).map { String(value[$0]) }
        } ?? []
    }
}
