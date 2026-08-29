import Foundation

enum AppLocalization {
    static var selectedLocale: Locale {
        selectedLanguage.locale
    }

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
            locale: selectedLocale,
            arguments: arguments
        )
    }

    static func number(_ value: Int) -> String {
        value.formatted(
            .number
                .grouping(.automatic)
                .locale(selectedLocale)
        )
    }

    static func date(
        _ date: Date,
        dateStyle: Date.FormatStyle.DateStyle = .abbreviated,
        timeStyle: Date.FormatStyle.TimeStyle = .standard
    ) -> String {
        date.formatted(
            Date.FormatStyle(date: dateStyle, time: timeStyle)
                .locale(selectedLocale)
        )
    }

    static func relativeDate(_ date: Date) -> String {
        date.formatted(
            .relative(presentation: .named)
                .locale(selectedLocale)
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
