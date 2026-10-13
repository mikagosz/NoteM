import Foundation
import Testing
@testable import NoteM

/// Every Help text has both languages, and every section 1–4 steps.
@MainActor
struct HelpContentTests {
    /// Polish letters in an English text mean the translation was left out (copied Polish).
    private func looksPolish(_ s: String) -> Bool { s.contains { "ąćęłńóśźżĄĆĘŁŃÓŚŹŻ".contains($0) } }

    @Test func checkCatchesPolish() {
        // The check itself: it must flag a Polish sentence, or a clean run would prove nothing.
        #expect(looksPolish("Zapisz notatkę"))
    }

    @Test func everyTextHasBothLanguages() {
        for text in HelpContent.allTexts {
            #expect(!text.pl.isEmpty, "empty Polish for \(text.en)")
            #expect(!text.en.isEmpty, "empty English for \(text.pl)")
            #expect(!looksPolish(text.en), "English looks Polish: \(text.en)")
        }
    }

    @Test func stepsPerSection() {
        for section in HelpContent.sections {
            #expect((1...4).contains(section.steps.count), "\(section.title.pl)")
        }
    }
}
