import Foundation
import Testing
@testable import NoteM

/// Filing rules are typed by hand in preferences and then used as a path, so the
/// engine has to keep them inside the store — and only re-file notes that are
/// still unfiled.
@MainActor
struct CategoryEngineTests {

    private func rule(_ keyword: String, _ target: String) -> CategoryRule {
        CategoryRule(keyword: keyword, targetFolderPattern: target, priority: 0)
    }

    // MARK: - Confining the pattern

    @Test func confinedStripsTraversalAndAbsolutePaths() {
        #expect(CategoryEngine.confined("../../Desktop") == "Desktop")
        #expect(CategoryEngine.confined("/etc/passwd") == "etc/passwd")
        #expect(CategoryEngine.confined("Praca/../../..") == "Praca")
        #expect(CategoryEngine.confined("Praca//2026") == "Praca/2026")
    }

    @Test func confinedKeepsNotesOutOfTheStoresOwnFolders() {
        #expect(CategoryEngine.confined(NoteStore.trashDir) == "")
        #expect(CategoryEngine.confined(NoteStore.historyDir + "/x") == "x")
    }

    @Test func confinedLeavesAnOrdinaryPathAlone() {
        #expect(CategoryEngine.confined("Praca/Projekty") == "Praca/Projekty")
    }

    @Test func aTraversingRuleCannotMoveTheNoteOutOfTheStore() {
        let target = CategoryEngine.targetFolderPath(
            content: "faktura za lipiec",
            currentFolderPath: "Inbox/2026-07-31_10-00-00",
            rules: [rule("faktura", "../../../Desktop")]
        )
        #expect(target == "Desktop/2026-07-31_10-00-00")
        #expect(target?.contains("..") == false)
    }

    // MARK: - Matching

    @Test func aMatchingRuleFilesTheNote() {
        let target = CategoryEngine.targetFolderPath(
            content: "Notatka ze spotkania w pracy",
            currentFolderPath: "Inbox/2026-07-31_10-00-00",
            rules: [rule("pracy", "Praca")]
        )
        #expect(target == "Praca/2026-07-31_10-00-00")
    }

    @Test func theFirstMatchingRuleWins() {
        let target = CategoryEngine.targetFolderPath(
            content: "faktura za spotkanie",
            currentFolderPath: "Inbox/nota",
            rules: [rule("faktura", "Finanse"), rule("spotkanie", "Kalendarz")]
        )
        #expect(target == "Finanse/nota")
    }

    @Test func matchingIgnoresLetterCase() {
        let target = CategoryEngine.targetFolderPath(
            content: "FAKTURA VAT",
            currentFolderPath: "Inbox/nota",
            rules: [rule("faktura", "Finanse")]
        )
        #expect(target == "Finanse/nota")
    }

    @Test func anEmptyKeywordMatchesNothing() {
        let target = CategoryEngine.targetFolderPath(
            content: "cokolwiek",
            currentFolderPath: "Inbox/nota",
            rules: [rule("   ", "Wszystko")]
        )
        #expect(target == nil)   // stays in Inbox
    }

    @Test func anAlreadyFiledNoteIsLeftWhereItIs() {
        let target = CategoryEngine.targetFolderPath(
            content: "faktura za lipiec",
            currentFolderPath: "Praca/nota",
            rules: [rule("faktura", "Finanse")]
        )
        #expect(target == nil)
    }

    @Test func anUnmatchedNoteAtTheRootIsPulledIntoInbox() {
        let target = CategoryEngine.targetFolderPath(
            content: "nic tu nie pasuje",
            currentFolderPath: "nota",
            rules: [rule("faktura", "Finanse")]
        )
        #expect(target == CategoryEngine.inbox + "/nota")
    }

    // MARK: - Placeholders

    @Test func datePlaceholdersAreSubstituted() {
        let now = Date(timeIntervalSince1970: 1_785_000_000)   // 2026-07-25 UTC-ish
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let result = CategoryEngine.substitute("Praca/{date}", now: now)
        #expect(result == "Praca/" + formatter.string(from: now))
        #expect(!result.contains("{date}"))
    }

    @Test func substituteAlsoConfinesTheResult() {
        #expect(CategoryEngine.substitute("../{date}/../..", now: Date()).contains("..") == false)
    }
}
