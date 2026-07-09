import SwiftUI

/// A colour theme: an accent used across the app (buttons, selections, links)
/// plus a subtle window background tint derived from it.
struct AppTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let accent: Color

    /// Subtle background tint used behind the app for this theme.
    var tintedBackground: Color { accent.opacity(0.10) }

    /// The built-in themes offered in Settings → Wygląd.
    static let all: [AppTheme] = [
        AppTheme(id: "blue",    name: "Blue",    accent: Color(hex: 0x0055FF)),
        AppTheme(id: "purple",  name: "Purple",  accent: Color(hex: 0x8800FF)),
        AppTheme(id: "pink",    name: "Pink",    accent: Color(hex: 0xFF0077)),
        AppTheme(id: "red",     name: "Red",     accent: Color(hex: 0xFF1100)),
        AppTheme(id: "orange",  name: "Orange",  accent: Color(hex: 0xFF6600)),
        AppTheme(id: "yellow",  name: "Yellow",  accent: Color(hex: 0xFFBB00)),
        AppTheme(id: "green",   name: "Green",   accent: Color(hex: 0x00CC44)),
        AppTheme(id: "teal",    name: "Teal",    accent: Color(hex: 0x00BBCC)),
        AppTheme(id: "indigo",  name: "Indigo",  accent: Color(hex: 0x4400EE)),
        AppTheme(id: "mono",    name: "Graphite",accent: Color(hex: 0x888899))
    ]

    static let fallback = all[0]  // blue

    static func theme(id: String) -> AppTheme {
        // "ocean", "forest", "sunset", "rose" are legacy ids — map to closest new theme.
        let legacyMap: [String: String] = [
            "ocean": "blue", "forest": "green", "sunset": "orange",
            "rose": "pink", "neon purple": "purple"
        ]
        let resolvedID = legacyMap[id] ?? id
        return all.first { $0.id == resolvedID } ?? fallback
    }

    /// Accent colour for a theme id, or `nil` if unknown — used for per-folder
    /// cover colours (which store a theme id). Resolves legacy ids too, so a
    /// folder coloured in an older version keeps its cover bar.
    static func color(id: String?) -> Color? {
        guard let id else { return nil }
        if let exact = all.first(where: { $0.id == id })?.accent { return exact }
        let legacyMap = ["ocean": "blue", "forest": "green", "sunset": "orange",
                         "rose": "pink", "neon purple": "purple"]
        if let mapped = legacyMap[id] { return all.first { $0.id == mapped }?.accent }
        return nil
    }
}

extension Color {
    /// Builds a colour from a 24-bit RGB hex value, e.g. `0x8B5CF6`.
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Preferences pane: pick a colour theme with a live mini-preview.
struct AppearanceSettingsView: View {
    @Bindable var settings: AppSettings

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Wygląd")
                    .font(.headline)
                Text("Wybierz motyw kolorystyczny. Kolor akcentu wpływa na przyciski, zaznaczenia i linki "
                     + "w całej aplikacji. Kolor pojedynczego folderu ustawisz z menu kontekstowego notatki.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(AppTheme.all) { theme in
                        ThemeSwatch(theme: theme, isSelected: settings.themeID == theme.id) {
                            settings.themeID = theme.id
                        }
                    }
                }

                Divider()
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Widok strony Start")
                        .font(.callout)
                    Picker("Widok strony Start", selection: $settings.startLayout) {
                        ForEach(StartLayout.allCases) { layout in
                            Text(layout.label).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Sekcje: listy z nagłówkami dat. Kolumny: słupki obok siebie. Stosy: kliknij stos, by zobaczyć notatki z danego okresu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .thinScrollers()
        }
    }
}

/// A single theme option: a small interface mock-up plus its name.
private struct ThemeSwatch: View {
    let theme: AppTheme
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.tintedBackground)
                    .frame(height: 62)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 4) {
                                Circle().fill(theme.accent).frame(width: 10, height: 10)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(theme.accent.opacity(0.6))
                                    .frame(width: 44, height: 6)
                            }
                            RoundedRectangle(cornerRadius: 2).fill(.secondary.opacity(0.4)).frame(width: 70, height: 5)
                            RoundedRectangle(cornerRadius: 3).fill(theme.accent).frame(width: 34, height: 12)
                        }
                        .padding(8)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isSelected ? theme.accent : Color.clear, lineWidth: 2)
                    )

                HStack {
                    Text(theme.name).font(.callout)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
