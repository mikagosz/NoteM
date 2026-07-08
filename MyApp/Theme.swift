import SwiftUI

/// A colour theme: an accent used across the app (buttons, selections, links)
/// plus a subtle window background tint derived from it.
struct AppTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let accent: Color

    /// Subtle background tint used behind the app for this theme.
    var tintedBackground: Color { accent.opacity(0.07) }

    /// The built-in themes offered in Settings → Wygląd.
    static let all: [AppTheme] = [
        AppTheme(id: "purple", name: "Neon Purple", accent: Color(hex: 0x8B5CF6)),
        AppTheme(id: "ocean",  name: "Ocean",       accent: Color(hex: 0x0EA5E9)),
        AppTheme(id: "forest", name: "Forest",      accent: Color(hex: 0x22C55E)),
        AppTheme(id: "sunset", name: "Sunset",      accent: Color(hex: 0xF97316)),
        AppTheme(id: "rose",   name: "Rose",        accent: Color(hex: 0xF43F5E)),
        AppTheme(id: "mono",   name: "Mono",        accent: Color(hex: 0x64748B))
    ]

    static let fallback = all[0]

    static func theme(id: String) -> AppTheme {
        all.first { $0.id == id } ?? fallback
    }

    /// Accent colour for a theme id, or `nil` if unknown — used for per-folder
    /// cover colours (which store a theme id).
    static func color(id: String?) -> Color? {
        guard let id else { return nil }
        return all.first { $0.id == id }?.accent
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

            Spacer()
        }
        .padding(20)
        .frame(width: 560, height: 380)
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
