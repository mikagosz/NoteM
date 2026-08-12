import Foundation

/// The one place that decides what "the same text" means when searching notes.
///
/// It used to be answered in three different ways on the Start page, and the
/// three disagreed: the filter compared `lowercased()` strings, the preview
/// picked its fragment with `[.caseInsensitive, .diacriticInsensitive]`, and the
/// highlighter used only `.caseInsensitive`. The visible result was a note that
/// search found, whose preview showed the right fragment, with nothing
/// highlighted in it (E3-P3-01).
///
/// > Measured 2026-08-12, and it corrects the audit: Foundation's
/// > `.diacriticInsensitive` folds `ż ó ę ś ź ć ą ń` but **not `ł`** — `ł` is a
/// > letter of its own, not a composition. So the audit's example ("typing
/// > `zolw` finds `żółw`") never worked in any of the three paths. Polish
/// > searching only really ignores the ogonki once `ł → l` is folded by hand,
/// > which is what `polishExtras` below does.
///
/// `nonisolated`: the haystacks are folded on whichever thread reads the notes.
nonisolated enum SearchText {
    /// Foundation options used for the character-by-character folding below.
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Letters Foundation does not treat as decorated vowels or consonants.
    private static let polishExtras: [Character: Character] = ["ł": "l", "Ł": "l"]

    /// Case- and diacritic-folded form of `text`, plus `ł → l`.
    static func fold(_ text: String) -> String {
        FoldedText(text).folded
    }

    /// Whether an already-folded haystack contains an already-folded query.
    /// An empty query matches everything, which is what "no search" means.
    static func folded(_ haystack: String, contains query: String) -> Bool {
        query.isEmpty || haystack.contains(query)
    }

    /// The haystack cached per note: title, tags and content in one folded string.
    ///
    /// Joined with a newline rather than concatenated, so a query cannot match
    /// across the seam between a title and a tag and report a hit that no single
    /// field contains.
    static func haystack(title: String, tags: [String], content: String) -> String {
        fold(([title] + tags + [content]).joined(separator: "\n"))
    }

    /// Folds one character, or returns `nil` when it folds away to nothing.
    fileprivate static func foldCharacter(_ character: Character) -> String {
        if let extra = polishExtras[character] { return String(extra) }
        return String(character).folding(options: options, locale: nil)
    }
}

/// A folded copy of a string that can still point back at the original.
///
/// Searching a folded string is easy; showing the user *where* the hit is means
/// translating an index in the folded text back to the same place in the text on
/// screen. Folding is not always one character in, one character out (`ß` folds
/// to `ss`, a combining sequence can shrink), so the mapping is recorded while
/// folding rather than assumed — measuring on `lowercased()` and slicing the
/// original is the bug the old preview comment warns about, and an offset past
/// the end kills the process.
nonisolated struct FoldedText {
    /// The folded text: lowercase, no diacritics, `ł` folded to `l`.
    let folded: String
    /// For every character of `folded`, the offset of the character it came from
    /// in the original string.
    private let sourceOffsets: [Int]

    init(_ text: String) {
        var folded = ""
        var offsets: [Int] = []
        for (offset, character) in text.enumerated() {
            let replacement = SearchText.foldCharacter(character)
            folded += replacement
            offsets.append(contentsOf: Array(repeating: offset, count: replacement.count))
        }
        self.folded = folded
        self.sourceOffsets = offsets
    }

    /// Character offset in the original string where `foldedIndex` came from.
    func sourceOffset(of foldedIndex: String.Index) -> Int? {
        let position = folded.distance(from: folded.startIndex, to: foldedIndex)
        guard position >= 0, position < sourceOffsets.count else { return nil }
        return sourceOffsets[position]
    }

    /// Offsets in the original string covered by a range of the folded string,
    /// as `start..<end` in characters. `nil` when the range cannot be mapped.
    func sourceOffsets(of foldedRange: Range<String.Index>) -> Range<Int>? {
        guard let start = sourceOffset(of: foldedRange.lowerBound) else { return nil }
        guard foldedRange.upperBound > foldedRange.lowerBound else { return start..<start }
        let lastFolded = folded.index(before: foldedRange.upperBound)
        guard let lastSource = sourceOffset(of: lastFolded) else { return nil }
        return start..<(lastSource + 1)
    }

    /// Every occurrence of `query` (already folded) as offsets in the original
    /// string. Empty when the query is empty — "not searching" highlights nothing.
    func matches(ofFolded query: String) -> [Range<Int>] {
        guard !query.isEmpty else { return [] }
        var results: [Range<Int>] = []
        var searchStart = folded.startIndex
        while let range = folded.range(of: query, range: searchStart..<folded.endIndex) {
            if let mapped = sourceOffsets(of: range) { results.append(mapped) }
            searchStart = range.upperBound
        }
        return results
    }
}
