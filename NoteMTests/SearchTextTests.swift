import Foundation
import Testing
@testable import NoteM

/// Search is how people find their own notes, and the three places that answered
/// "does this text match?" used to answer differently — a note could be found,
/// its matching fragment shown, and nothing in it highlighted (E3-P3-01).
struct SearchTextTests {

    @Test func foldingIgnoresCaseAndPolishDiacritics() {
        #expect(SearchText.fold("Żółw") == SearchText.fold("zolw"))
        #expect(SearchText.fold("ŁÓDŹ") == SearchText.fold("lodz"))
        #expect(SearchText.fold("Gęś") == SearchText.fold("GES"))
        #expect(SearchText.fold("Ćma ąę śż") == SearchText.fold("CMA AE SZ"))
    }

    /// Measured 2026-08-12: Foundation's `.diacriticInsensitive` does **not**
    /// fold `ł`, because `ł` is a letter rather than a decorated `l`. Everything
    /// above therefore depends on the app folding it by hand — if that mapping is
    /// ever dropped, "zolw" stops finding "żółw" again and this says so.
    @Test func foundationAloneWouldNotFoldTheStrokedL() {
        let options = SearchText.options
        #expect("żółw".range(of: "zolw", options: options) == nil)
        #expect("gęś".range(of: "ges", options: options) != nil)
        #expect(SearchText.fold("żółw") == "zolw")
    }

    @Test func foldedHaystackFindsAQueryTypedWithoutOgonki() {
        let haystack = SearchText.haystack(
            title: "Żółw morski",
            tags: ["Zwierzęta"],
            content: "Chciał się gdzieś schować"
        )
        #expect(SearchText.folded(haystack, contains: SearchText.fold("zolw")))
        #expect(SearchText.folded(haystack, contains: SearchText.fold("ZWIERZETA")))
        #expect(SearchText.folded(haystack, contains: SearchText.fold("gdzies")))
        #expect(!SearchText.folded(haystack, contains: SearchText.fold("wieloryb")))
    }

    /// A hit found by the filter must be pointable-at on screen: the offsets come
    /// back in the *original* text, so the highlighter marks the real characters
    /// and not a place shifted by however much folding changed the length.
    @Test func aMatchPointsAtTheOriginalCharacters() {
        let text = "Notatka o żółwiu morskim"
        let folded = FoldedText(text)
        let matches = folded.matches(ofFolded: SearchText.fold("zolwiu"))
        #expect(matches.count == 1)

        let match = try! #require(matches.first)
        let characters = Array(text)
        let marked = String(characters[match.lowerBound..<match.upperBound])
        #expect(marked == "żółwiu")
    }

    /// Several occurrences, each mapped separately — the highlighter walks them
    /// all, and an off-by-one here would either miss one or paint the wrong word.
    @Test func everyOccurrenceIsFound() {
        let text = "gęś, gęsi i jeszcze raz GĘŚ"
        let matches = FoldedText(text).matches(ofFolded: SearchText.fold("ges"))
        #expect(matches.count == 3)
        let characters = Array(text)
        #expect(String(characters[matches[0].lowerBound..<matches[0].upperBound]) == "gęś")
        #expect(String(characters[matches[2].lowerBound..<matches[2].upperBound]) == "GĘŚ")
    }

    /// An empty query highlights nothing rather than everything.
    @Test func anEmptyQueryHasNoMatches() {
        #expect(FoldedText("cokolwiek").matches(ofFolded: "").isEmpty)
    }

    /// An empty query is "not searching", which matches everything — otherwise
    /// clearing the field would empty the Start page.
    @Test func emptyQueryMatchesAnything() {
        #expect(SearchText.folded(SearchText.fold("cokolwiek"), contains: ""))
    }

    /// The fields are joined with a newline on purpose. Concatenated, a query
    /// could straddle the seam and report a hit that no single field contains.
    @Test func aQueryCannotMatchAcrossTheSeamBetweenFields() {
        let haystack = SearchText.haystack(title: "raport", tags: ["maj"], content: "treść")
        #expect(!SearchText.folded(haystack, contains: SearchText.fold("raportmaj")))
        #expect(SearchText.folded(haystack, contains: SearchText.fold("raport")))
        #expect(SearchText.folded(haystack, contains: SearchText.fold("maj")))
    }
}
