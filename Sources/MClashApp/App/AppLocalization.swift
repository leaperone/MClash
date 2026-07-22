import Foundation

enum AppLocalization {
    static func string(_ key: String) -> String {
        NSLocalizedString(
            key,
            tableName: nil,
            bundle: selectedBundle,
            value: key,
            comment: ""
        )
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(
            format: string(key),
            locale: selectedLanguage.locale,
            arguments: arguments
        )
    }

    private static var selectedLanguage: AppLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: AppLanguage.storageKey) else {
            return .system
        }
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    private static var selectedBundle: Bundle {
        guard selectedLanguage != .system,
              let path = Bundle.main.path(
                forResource: selectedLanguage.rawValue,
                ofType: "lproj"
              ),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }
}
