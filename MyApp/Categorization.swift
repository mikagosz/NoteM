import SwiftUI
import Foundation
import Observation

/// A user-defined auto-filing rule: a note whose content contains `keyword`
/// is moved into the folder produced by `targetFolderPattern`.
///
/// `targetFolderPattern` may contain `{date}` and `{time}` placeholders, which
/// are substituted with the current date/time when the rule fires (e.g.
/// "Praca/{date}"). `priority` mirrors the rule's position in the list — lower
/// wins, and the first matching rule (top of the list) is applied.
struct CategoryRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var keyword: String
    var targetFolderPattern: String
    var priority: Int
}

/// Decides where a note should live based on its content and the current rules.
enum CategoryEngine {
    /// Default category for notes that match no rule.
    static let inbox = "Inbox"

    /// Returns the new `folderPath` a note should move to, or `nil` if it should
    /// stay put.
    ///
    /// Only *unfiled* notes are categorized — those still in `Inbox` or sitting
    /// directly at the store root. Once a note has been filed into a named
    /// category it is left alone, so edits don't make it hop folders (and
    /// `{date}` patterns don't re-file it every day).
    static func targetFolderPath(
        content: String,
        currentFolderPath: String,
        rules: [CategoryRule],
        now: Date = Date()
    ) -> String? {
        let components = currentFolderPath.split(separator: "/").map(String.init)
        guard let leaf = components.last else { return nil }
        let currentCategory = components.dropLast().joined(separator: "/")

        let isUnfiled = currentCategory.isEmpty || currentCategory == inbox
        guard isUnfiled else { return nil }

        let lowerContent = content.lowercased()
        let targetCategory: String
        if let rule = rules.first(where: { rule in
            let keyword = rule.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !keyword.isEmpty && lowerContent.contains(keyword)
        }) {
            targetCategory = substitute(rule.targetFolderPattern, now: now)
        } else {
            targetCategory = inbox
        }

        guard !targetCategory.isEmpty, targetCategory != currentCategory else { return nil }
        return targetCategory + "/" + leaf
    }

    /// Replaces `{date}` / `{time}` placeholders with filesystem-safe strings,
    /// then confines the result to a path inside the store (see `confined`).
    static func substitute(_ pattern: String, now: Date) -> String {
        let result = pattern
            .replacingOccurrences(of: "{date}", with: formatted(now, "yyyy-MM-dd"))
            .replacingOccurrences(of: "{time}", with: formatted(now, "HH-mm-ss"))
        return confined(result)
    }

    /// Keeps a rule's folder pattern inside the store root.
    ///
    /// The pattern is typed by hand in preferences, so "../../Desktop" or a
    /// leading "/" would otherwise move the note's folder clean out of NoteM.
    /// Dropping every dot-prefixed component handles `.` and `..` and also keeps
    /// notes out of the store's own reserved folders (`.trash`, `.history`),
    /// where they would vanish from the list. Returns a plain relative path.
    static func confined(_ path: String) -> String {
        path.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(".") }
            .joined(separator: "/")
    }

    private static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}

/// App-level settings persisted in `UserDefaults`. Currently the auto-filing
/// rules; later phases add quick-capture, theme, etc.
@MainActor
@Observable
final class AppSettings {
    var rules: [CategoryRule] {
        didSet { persistRules() }
    }

    /// Quick-capture hot corner: on/off and which corner.
    var quickCaptureEnabled: Bool {
        didSet { defaults.set(quickCaptureEnabled, forKey: Self.qcEnabledKey) }
    }
    /// Which corners reveal the quick-capture icon. Several can be active at once.
    var quickCaptureCorners: Set<QuickCaptureCorner> {
        didSet { defaults.set(quickCaptureCorners.map(\.rawValue), forKey: Self.qcCornersKey) }
    }

    /// Days a note stays in the trash before it's auto-deleted.
    var trashRetentionDays: Int {
        didSet { defaults.set(trashRetentionDays, forKey: Self.trashDaysKey) }
    }

    /// Whether notes are stored in iCloud Drive (synced) rather than locally.
    var syncEnabled: Bool {
        didSet { defaults.set(syncEnabled, forKey: Self.syncKey) }
    }

    /// Whether the user uses Obsidian at all. Off by default — with the bridge
    /// disconnected the Obsidian button stays out of the note toolbar entirely.
    var obsidianConnected: Bool {
        didSet { defaults.set(obsidianConnected, forKey: Self.obsidianConnectedKey) }
    }

    /// Mirror notes into the vault on every save. Only meaningful while
    /// `obsidianConnected` is on; manual sending stays available either way.
    var obsidianAutoExport: Bool {
        didSet { defaults.set(obsidianAutoExport, forKey: Self.obsidianAutoKey) }
    }

    /// Folder inside the Obsidian vault that receives the exported notes.
    var obsidianVaultPath: String {
        didSet { defaults.set(obsidianVaultPath, forKey: Self.obsidianPathKey) }
    }

    /// Identifier of the selected colour theme (see `AppTheme`).
    var themeID: String {
        didSet { defaults.set(themeID, forKey: Self.themeKey) }
    }

    /// Layout of the Start page: sections, columns, or macOS-style stacks.
    var startLayout: StartLayout {
        didSet { defaults.set(startLayout.rawValue, forKey: Self.startLayoutKey) }
    }

    /// The currently selected theme.
    var theme: AppTheme { AppTheme.theme(id: themeID) }

    /// User-defined smart folders (predefined ones are always prepended at runtime).
    var smartFolders: [SmartFolder] {
        didSet { persistSmartFolders() }
    }

    /// UI language of the app (also selects the spell-checker dictionary).
    var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Loc.key)
            Loc.language = language
        }
    }

    /// Returns the Polish or English variant for the current UI language. Reading
    /// `language` here makes SwiftUI views re-render when the language changes.
    func t(_ pl: String, _ en: String) -> String {
        language == .pl ? pl : en
    }

    /// Highlight misspelled words (Polish dictionary) while typing.
    var spellCheckEnabled: Bool {
        didSet { defaults.set(spellCheckEnabled, forKey: Self.spellCheckKey) }
    }
    /// Automatically correct misspelled words as you type.
    var autocorrectEnabled: Bool {
        didSet { defaults.set(autocorrectEnabled, forKey: Self.autocorrectKey) }
    }

    private let defaults: UserDefaults
    private static let rulesKey = "categoryRules"
    private static let qcEnabledKey = "quickCaptureEnabled"
    private static let qcCornerKey = "quickCaptureCorner"   // legacy single-corner value, kept for migration
    private static let qcCornersKey = "quickCaptureCorners"
    private static let trashDaysKey = "trashRetentionDays"
    private static let syncKey = "syncEnabled"
    private static let obsidianConnectedKey = "obsidianConnected"
    private static let obsidianAutoKey = "obsidianAutoExport"
    private static let obsidianPathKey = "obsidianVaultPath"
    private static let themeKey = "themeID"
    private static let startLayoutKey = "startLayout"
    private static let smartFoldersKey = "smartFolders"
    static let spellCheckKey = "spellCheckEnabled"
    static let autocorrectKey = "autocorrectEnabled"

    /// All smart folders: predefined first, then user-created.
    var allSmartFolders: [SmartFolder] {
        SmartFolder.predefined + smartFolders
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.rulesKey),
           let decoded = try? JSONDecoder().decode([CategoryRule].self, from: data) {
            self.rules = decoded
        } else {
            self.rules = []
        }
        self.quickCaptureEnabled = defaults.bool(forKey: Self.qcEnabledKey)
        if let raw = defaults.array(forKey: Self.qcCornersKey) as? [String] {
            self.quickCaptureCorners = Set(raw.compactMap(QuickCaptureCorner.init(rawValue:)))
        } else if let legacy = defaults.string(forKey: Self.qcCornerKey),
                  let corner = QuickCaptureCorner(rawValue: legacy) {
            self.quickCaptureCorners = [corner]   // migrate the old single-corner setting
        } else {
            self.quickCaptureCorners = [.topRight]
        }
        self.trashRetentionDays = defaults.object(forKey: Self.trashDaysKey) as? Int ?? 30
        self.syncEnabled = defaults.bool(forKey: Self.syncKey)
        self.obsidianConnected = defaults.bool(forKey: Self.obsidianConnectedKey)
        // Once connected, mirroring on save is the expected behaviour.
        self.obsidianAutoExport = defaults.object(forKey: Self.obsidianAutoKey) as? Bool ?? true
        // No stored path, or one that used to be the default, means we fall back to
        // the current default; anything else is a deliberate choice and stays put.
        let storedVaultPath = defaults.string(forKey: Self.obsidianPathKey)
        if let storedVaultPath, !ObsidianExport.legacyVaultFolders.contains(storedVaultPath) {
            self.obsidianVaultPath = storedVaultPath
        } else {
            self.obsidianVaultPath = ObsidianExport.defaultVaultFolder
        }
        self.themeID = defaults.string(forKey: Self.themeKey) ?? AppTheme.fallback.id
        self.startLayout = StartLayout(rawValue: defaults.string(forKey: Self.startLayoutKey) ?? "")
            ?? .sections
        if let data = defaults.data(forKey: Self.smartFoldersKey),
           let decoded = try? JSONDecoder().decode([SmartFolder].self, from: data) {
            self.smartFolders = decoded
        } else {
            self.smartFolders = []
        }
        // Spell checking on by default; auto-correct off (opt-in).
        self.spellCheckEnabled = defaults.object(forKey: Self.spellCheckKey) as? Bool ?? true
        self.autocorrectEnabled = defaults.bool(forKey: Self.autocorrectKey)
        self.language = AppLanguage(rawValue: defaults.string(forKey: Loc.key) ?? AppLanguage.pl.rawValue) ?? .pl
        Loc.language = self.language
    }

    func addRule() {
        rules.append(CategoryRule(keyword: "", targetFolderPattern: "", priority: rules.count))
    }

    func remove(atOffsets offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
        renumber()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        renumber()
    }

    /// Keeps `priority` in sync with list order (0 = highest).
    private func renumber() {
        for index in rules.indices where rules[index].priority != index {
            rules[index].priority = index
        }
    }

    private func persistRules() {
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: Self.rulesKey)
        }
    }

    func addSmartFolder(_ folder: SmartFolder) {
        smartFolders.append(folder)
    }

    func removeSmartFolder(id: UUID) {
        smartFolders.removeAll { $0.id == id }
    }

    private func persistSmartFolders() {
        if let data = try? JSONEncoder().encode(smartFolders) {
            defaults.set(data, forKey: Self.smartFoldersKey)
        }
    }
}

/// Preferences pane: how long notes stay in the trash before auto-deletion.
struct TrashSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(settings.t("Kosz", "Trash"))
                .font(.headline)
            Text(settings.t("Usunięte notatki trafiają do kosza i są automatycznie kasowane po upływie "
                            + "podanej liczby dni. Ustaw 0, aby wyłączyć automatyczne czyszczenie.",
                            "Deleted notes go to the trash and are automatically removed after the given "
                            + "number of days. Set 0 to disable automatic cleanup."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Stepper(value: $settings.trashRetentionDays, in: 0...365) {
                if settings.trashRetentionDays == 0 {
                    Text(settings.t("Automatyczne czyszczenie: wyłączone", "Automatic cleanup: off"))
                } else {
                    Text(settings.t("Czyść po: \(settings.trashRetentionDays) dniach",
                                    "Clean up after \(settings.trashRetentionDays) days"))
                }
            }
            .frame(maxWidth: 320, alignment: .leading)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Preferences pane: manage auto-filing rules (add / edit / delete / reorder).
struct RulesSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(settings.t("Reguły katalogowania", "Filing rules"))
                .font(.headline)
            Text(settings.t("Notatka zawierająca słowo kluczowe trafia do wskazanego folderu. "
                            + "Sprawdzana jest pierwsza pasująca reguła od góry — przeciągnij, by zmienić kolejność. "
                            + "W ścieżce możesz użyć {date} i {time}.",
                            "A note containing the keyword is moved to the given folder. The first matching rule "
                            + "from the top wins — drag to reorder. You can use {date} and {time} in the path."))
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach($settings.rules) { $rule in
                    HStack(spacing: 8) {
                        TextField(settings.t("słowo kluczowe", "keyword"), text: $rule.keyword)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        TextField(settings.t("folder, np. Praca/{date}", "folder, e.g. Work/{date}"), text: $rule.targetFolderPattern)
                    }
                    .textFieldStyle(.roundedBorder)
                }
                .onMove { settings.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { settings.remove(atOffsets: $0) }
            }
            .frame(minHeight: 180)

            HStack {
                Button {
                    settings.addRule()
                } label: {
                    Label(settings.t("Dodaj regułę", "Add rule"), systemImage: "plus")
                }
                Spacer()
                if !settings.rules.isEmpty {
                    Text(settings.t("Notatki bez dopasowania trafiają do „\(CategoryEngine.inbox)”.",
                                    "Notes with no match go to “\(CategoryEngine.inbox)”."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
