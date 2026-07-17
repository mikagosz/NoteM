import SwiftUI

/// Paleta poleceń (⌘K, Priorytet 5): pływające okno z polem tekstowym i listą
/// akcji filtrowaną na żywo. Enter uruchamia zaznaczoną akcję, strzałki ↑/↓
/// zmieniają zaznaczenie, Esc (albo klik poza oknem) zamyka.

/// One action offered by the palette. Note-jump items are flagged so the
/// empty-query view can cap how many notes it lists.
struct CommandPaletteItem: Identifiable {
    let id: String
    let title: String
    var subtitle: String? = nil
    let icon: String
    var isNote: Bool = false
    let perform: () -> Void
}

struct CommandPaletteOverlay: View {
    let settings: AppSettings
    var accent: Color = .accentColor
    /// Every available action, in display order (filtering happens here).
    let items: [CommandPaletteItem]
    let onClose: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var fieldFocused: Bool

    /// How many note-jump entries to show before the user types anything.
    private static let idleNoteLimit = 5

    private var visibleItems: [CommandPaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            var noteCount = 0
            return items.filter { item in
                guard item.isNote else { return true }
                noteCount += 1
                return noteCount <= Self.idleNoteLimit
            }
        }
        return items
            .compactMap { item -> (CommandPaletteItem, Int)? in
                guard let score = Self.fuzzyScore(query: q, in: item.title) else { return nil }
                return (item, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Dimmed backdrop; clicking it dismisses the palette.
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            palette
                .padding(.top, 110)
        }
        .onExitCommand { onClose() }
    }

    private var palette: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField(settings.t("Wpisz polecenie albo tytuł notatki…",
                                     "Type a command or note title…"),
                          text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { runSelected() }
            }
            .padding(14)

            Divider()

            if visibleItems.isEmpty {
                Text(settings.t("Brak pasujących poleceń ani notatek.",
                                "No matching commands or notes."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(18)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                                row(item, isSelected: index == selectedIndex)
                                    .id(index)
                                    .onTapGesture {
                                        onClose()
                                        item.perform()
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selectedIndex) {
                        proxy.scrollTo(selectedIndex)
                    }
                }
            }
        }
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.quaternary))
        .shadow(radius: 24, y: 8)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { selectedIndex = 0 }
        .onKeyPress(.downArrow) {
            selectedIndex = min(selectedIndex + 1, max(visibleItems.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        }
    }

    private func row(_ item: CommandPaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .frame(width: 20)
                .foregroundStyle(isSelected ? .white : accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : .secondary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.75))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? accent : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func runSelected() {
        guard visibleItems.indices.contains(selectedIndex) else { return }
        let item = visibleItems[selectedIndex]
        onClose()
        item.perform()
    }

    /// Simple fuzzy match: every character of the query must appear in order
    /// in the candidate. Consecutive hits and matches at word starts score
    /// higher; `nil` means no match. Case- and diacritic-insensitive.
    static func fuzzyScore(query: String, in candidate: String) -> Int? {
        let q = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let c = candidate.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        // A literal substring is the strongest signal.
        if let range = c.range(of: q) {
            return 1000 - c.distance(from: c.startIndex, to: range.lowerBound)
        }
        var score = 0
        var qIndex = q.startIndex
        var previousMatched = false
        var previousChar: Character? = nil
        for ch in c {
            guard qIndex < q.endIndex else { break }
            if ch == q[qIndex] {
                score += previousMatched ? 8 : 4
                if previousChar == nil || previousChar == " " { score += 6 }
                qIndex = q.index(after: qIndex)
                previousMatched = true
            } else {
                previousMatched = false
            }
            previousChar = ch
        }
        return qIndex == q.endIndex ? score : nil
    }
}
