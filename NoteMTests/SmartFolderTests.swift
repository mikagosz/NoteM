import Foundation
import Testing
@testable import NoteM

/// Smart folders decide what the user sees in a saved search, so a wrong match
/// either hides notes or shows the wrong ones — silently, in both directions.
@MainActor
struct SmartFolderTests {

    private func note(
        title: String = "Notatka",
        tags: [String] = [],
        folderPath: String = "Inbox/2026-08-01_10-00-00",
        pinned: Bool = false,
        modified: Date = Date()
    ) -> Note {
        Note(title: title, tags: tags, modified: modified, folderPath: folderPath, pinned: pinned)
    }

    private func folder(_ conditions: [SmartFolderCondition], conjunctive: Bool) -> SmartFolder {
        SmartFolder(id: UUID(), name: "Test", icon: "star", conditions: conditions, conjunctive: conjunctive)
    }

    @Test func noConditionsMatchNothing() {
        #expect(folder([], conjunctive: false).matches(note()) == false)
        #expect(folder([], conjunctive: true).matches(note()) == false)
    }

    @Test func tagMatchIgnoresCase() {
        let smart = folder([.tagContains("Praca")], conjunctive: true)
        #expect(smart.matches(note(tags: ["praca"])))
        #expect(smart.matches(note(tags: ["dom"])) == false)
    }

    @Test func titleMatchIsASubstring() {
        let smart = folder([.titleContains("faktura")], conjunctive: true)
        #expect(smart.matches(note(title: "Faktura za lipiec")))
        #expect(smart.matches(note(title: "Umowa")) == false)
    }

    @Test func conjunctiveNeedsEveryConditionOrConditionsNeedOne() {
        let both = folder([.titleContains("faktura"), .pinned], conjunctive: true)
        let either = folder([.titleContains("faktura"), .pinned], conjunctive: false)
        let onlyTitle = note(title: "Faktura", pinned: false)

        #expect(both.matches(onlyTitle) == false)
        #expect(either.matches(onlyTitle))
        #expect(both.matches(note(title: "Faktura", pinned: true)))
    }

    /// The source folder is a path prefix, so "Praca" must not drag in
    /// "Pracownia" — the notes live in sibling folders on disk.
    @Test func sourceFolderMatchesTheFolderAndItsContentsOnly() {
        let smart = folder([.sourceFolder("Praca")], conjunctive: true)
        #expect(smart.matches(note(folderPath: "Praca/2026-08-01_10-00-00")))
        #expect(smart.matches(note(folderPath: "Praca")))
        #expect(smart.matches(note(folderPath: "Pracownia/2026-08-01_10-00-00")) == false)
    }

    @Test func modifiedInDaysCountsBackFromTheGivenMoment() {
        let now = Date()
        let smart = folder([.modifiedInDays(7)], conjunctive: true)
        let fresh = note(modified: now.addingTimeInterval(-3 * 24 * 3600))
        let stale = note(modified: now.addingTimeInterval(-30 * 24 * 3600))

        #expect(smart.matches(fresh, now: now))
        #expect(smart.matches(stale, now: now) == false)
    }

    @Test func modifiedTodayIsAboutTheCalendarDay() {
        let smart = folder([.modifiedToday], conjunctive: true)
        #expect(smart.matches(note(modified: Date())))
        #expect(smart.matches(note(modified: Date().addingTimeInterval(-48 * 3600))) == false)
    }
}

/// Ranking behind ⌘K: the list is only useful if the note you meant sits at the
/// top, so the ordering rules deserve their own checks.
@MainActor
struct CommandPaletteFuzzyTests {

    private func score(_ query: String, _ candidate: String) -> Int? {
        CommandPaletteOverlay.fuzzyScore(query: query, in: candidate)
    }

    @Test func nonMatchingQueryScoresNothing() {
        #expect(score("xyz", "Lista zakupów") == nil)
    }

    @Test func aLiteralSubstringBeatsScatteredLetters() {
        let literal = score("zak", "Lista zakupów")
        let scattered = score("zak", "Zeszyt astronomiczny Karola")
        #expect(literal != nil && scattered != nil)
        #expect(literal! > scattered!)
    }

    @Test func anEarlierMatchScoresHigher() {
        let early = score("lista", "Lista zakupów")
        let late = score("lista", "Nowa lista zakupów")
        #expect(early != nil && late != nil)
        #expect(early! > late!)
    }

    @Test func matchingIgnoresCaseAndDiacritics() {
        #expect(score("zakupow", "Lista Zakupów") != nil)
        #expect(score("ZAKUPÓW", "lista zakupow") != nil)
    }

    @Test func lettersMustAppearInOrder() {
        #expect(score("abc", "a b c") != nil)
        #expect(score("cba", "a b c") == nil)
    }
}
