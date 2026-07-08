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

    /// Replaces `{date}` / `{time}` placeholders with filesystem-safe strings.
    static func substitute(_ pattern: String, now: Date) -> String {
        let result = pattern
            .replacingOccurrences(of: "{date}", with: formatted(now, "yyyy-MM-dd"))
            .replacingOccurrences(of: "{time}", with: formatted(now, "HH-mm-ss"))
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
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
    var quickCaptureCorner: QuickCaptureCorner {
        didSet { defaults.set(quickCaptureCorner.rawValue, forKey: Self.qcCornerKey) }
    }

    /// Days a note stays in the trash before it's auto-deleted.
    var trashRetentionDays: Int {
        didSet { defaults.set(trashRetentionDays, forKey: Self.trashDaysKey) }
    }

    /// Whether notes are stored in iCloud Drive (synced) rather than locally.
    var syncEnabled: Bool {
        didSet { defaults.set(syncEnabled, forKey: Self.syncKey) }
    }

    /// Identifier of the selected colour theme (see `AppTheme`).
    var themeID: String {
        didSet { defaults.set(themeID, forKey: Self.themeKey) }
    }

    /// The currently selected theme.
    var theme: AppTheme { AppTheme.theme(id: themeID) }

    private let defaults: UserDefaults
    private static let rulesKey = "categoryRules"
    private static let qcEnabledKey = "quickCaptureEnabled"
    private static let qcCornerKey = "quickCaptureCorner"
    private static let trashDaysKey = "trashRetentionDays"
    private static let syncKey = "syncEnabled"
    private static let themeKey = "themeID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.rulesKey),
           let decoded = try? JSONDecoder().decode([CategoryRule].self, from: data) {
            self.rules = decoded
        } else {
            self.rules = []
        }
        self.quickCaptureEnabled = defaults.bool(forKey: Self.qcEnabledKey)
        self.quickCaptureCorner = QuickCaptureCorner(rawValue: defaults.string(forKey: Self.qcCornerKey) ?? "")
            ?? .topRight
        self.trashRetentionDays = defaults.object(forKey: Self.trashDaysKey) as? Int ?? 30
        self.syncEnabled = defaults.bool(forKey: Self.syncKey)
        self.themeID = defaults.string(forKey: Self.themeKey) ?? AppTheme.fallback.id
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
}

/// Preferences pane: how long notes stay in the trash before auto-deletion.
struct TrashSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kosz")
                .font(.headline)
            Text("Usunięte notatki trafiają do kosza i są automatycznie kasowane po upływie "
                 + "podanej liczby dni. Ustaw 0, aby wyłączyć automatyczne czyszczenie.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Stepper(value: $settings.trashRetentionDays, in: 0...365) {
                if settings.trashRetentionDays == 0 {
                    Text("Automatyczne czyszczenie: wyłączone")
                } else {
                    Text("Czyść po: \(settings.trashRetentionDays) dniach")
                }
            }
            .frame(maxWidth: 320, alignment: .leading)

            Spacer()
        }
        .padding(20)
        .frame(width: 560, height: 380)
    }
}

/// Preferences pane: manage auto-filing rules (add / edit / delete / reorder).
struct RulesSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reguły katalogowania")
                .font(.headline)
            Text("Notatka zawierająca słowo kluczowe trafia do wskazanego folderu. "
                 + "Sprawdzana jest pierwsza pasująca reguła od góry — przeciągnij, by zmienić kolejność. "
                 + "W ścieżce możesz użyć {date} i {time}.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach($settings.rules) { $rule in
                    HStack(spacing: 8) {
                        TextField("słowo kluczowe", text: $rule.keyword)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        TextField("folder, np. Praca/{date}", text: $rule.targetFolderPattern)
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
                    Label("Dodaj regułę", systemImage: "plus")
                }
                Spacer()
                if !settings.rules.isEmpty {
                    Text("Notatki bez dopasowania trafiają do „\(CategoryEngine.inbox)”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 380)
    }
}
