import Foundation

/// UI language of the app. Persisted in `UserDefaults`; switching it updates the
/// interface live (no restart) and also picks the spell-checker dictionary.
enum AppLanguage: String, CaseIterable, Identifiable {
    case pl, en

    var id: String { rawValue }

    /// Native name shown in the language picker.
    var displayName: String {
        switch self {
        case .pl: return "Polski"
        case .en: return "English"
        }
    }

    /// Prefix used to find the matching `NSSpellChecker` language (e.g. "pl", "en").
    var spellPrefix: String { self == .pl ? "pl" : "en" }
}

/// Lightweight runtime localization shared across the app.
///
/// SwiftUI views should call `AppSettings.t(_:_:)` so they re-render when the
/// language changes; non-SwiftUI code (AppKit menus, panels) reads `Loc.t(_:_:)`,
/// whose `language` mirror is kept in sync by `AppSettings`.
enum Loc {
    static let key = "appLanguage"

    static var language: AppLanguage =
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? AppLanguage.pl.rawValue) ?? .pl

    /// Returns the Polish or English variant for the current language.
    static func t(_ pl: String, _ en: String) -> String {
        language == .pl ? pl : en
    }
}
