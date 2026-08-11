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
/// language changes; non-SwiftUI code (AppKit menus, panels, error descriptions)
/// reads `Loc.t(_:_:)`.
///
/// Read straight from `UserDefaults` on every call, rather than kept in a stored
/// property that `AppSettings` mirrored into. Two reasons, and the first is the
/// one that matters: a mutable static is shared mutable state, so `t` could only
/// be called from the main actor — and `LocalizedError.errorDescription` is
/// nonisolated, which made an export error unreadable under Swift 6. The second
/// is the lesson from `StorageLocation`: two copies of one value drift, and the
/// mirror had to be re-assigned in two places to stay honest.
///
/// `UserDefaults` is thread-safe and keeps its own in-memory cache, so this is a
/// dictionary lookup, not a disk read.
nonisolated enum Loc {
    static let key = "appLanguage"

    static var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .pl
    }

    /// Returns the Polish or English variant for the current language.
    static func t(_ pl: String, _ en: String) -> String {
        language == .pl ? pl : en
    }
}
