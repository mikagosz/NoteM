import AppKit
import Foundation
import Testing
@testable import NoteM

/// List and checklist toggles run on a live `NSTextView`, which a headless test
/// on macOS can create just fine. The case that matters is a caret on a line
/// that *isn't* the last one: `paragraphRange(for:)` hands back the closing "\n"
/// as well, and the marker for that phantom empty line used to land at the start
/// of the following paragraph — and get saved there.
@MainActor
struct RichTextControllerTests {

    /// A controller attached to a text view preloaded with `text`, caret placed
    /// at `caret` (UTF-16 offset).
    private func makeController(text: String, caret: Int) -> (RichTextController, NSTextView) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let controller = RichTextController()
        controller.attach(textView)
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: MarkdownStyler.defaultTypingAttributes)
        )
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        return (controller, textView)
    }

    private func markdown(of textView: NSTextView) -> String {
        MarkdownStyler.markdown(from: textView.attributedString())
    }

    // MARK: - Bulleted / numbered lists (P1-02)

    @Test func bulletOnTheFirstOfTwoLinesLeavesTheSecondAlone() {
        let (controller, textView) = makeController(text: "abc\ndef", caret: 1)
        controller.toggleList("bullet")

        #expect(textView.string == "\(MarkdownStyler.bulletMarker)abc\ndef")
        #expect(markdown(of: textView) == "- abc\ndef")
    }

    @Test func bulletOnTheLastLineStillWorks() {
        let (controller, textView) = makeController(text: "abc\ndef", caret: 5)
        controller.toggleList("bullet")

        #expect(markdown(of: textView) == "abc\n- def")
    }

    @Test func numberedListOnTheFirstOfTwoLinesLeavesTheSecondAlone() {
        let (controller, textView) = makeController(text: "abc\ndef", caret: 0)
        controller.toggleList("ordered")

        #expect(markdown(of: textView) == "1. abc\ndef")
    }

    /// The multi-line path is the one that has to keep working: selecting three
    /// lines numbers them 1, 2, 3 — without a fourth marker leaking downwards.
    @Test func numberedListNumbersEveryLineOfASelection() {
        let (controller, textView) = makeController(text: "raz\ndwa\ntrzy\npo liście", caret: 0)
        textView.setSelectedRange(NSRange(location: 0, length: 12)) // "raz\ndwa\ntrzy"
        controller.toggleList("ordered")

        #expect(markdown(of: textView) == "1. raz\n2. dwa\n3. trzy\npo liście")
    }

    @Test func togglingTheSameKindAgainRemovesTheMarkers() {
        let (controller, textView) = makeController(text: "abc\ndef", caret: 1)
        controller.toggleList("bullet")
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        controller.toggleList("bullet")

        #expect(textView.string == "abc\ndef")
        #expect(markdown(of: textView) == "abc\ndef")
    }

    /// Starting a list on an empty line is how lists usually get created, so the
    /// blank-line guard must not swallow this case.
    @Test func bulletOnAnEmptyLineInsertsTheMarker() {
        let (controller, textView) = makeController(text: "", caret: 0)
        controller.toggleList("bullet")

        #expect(textView.string == MarkdownStyler.bulletMarker)
    }

    @Test func blankLineInsideASelectionStaysBlank() {
        let (controller, textView) = makeController(text: "raz\n\ndwa", caret: 0)
        textView.setSelectedRange(NSRange(location: 0, length: 8))
        controller.toggleList("bullet")

        #expect(markdown(of: textView) == "- raz\n\n- dwa")
    }

    // MARK: - Checklists (P1-02)

    @Test func checklistOnTheFirstOfTwoLinesLeavesTheSecondAlone() {
        let (controller, textView) = makeController(text: "abc\ndef", caret: 1)
        controller.toggleChecklist()

        #expect(markdown(of: textView) == "- [ ] abc\ndef")
    }

    @Test func checklistOnTheLastLineStillWorks() {
        let (controller, textView) = makeController(text: "abc\ndef", caret: 5)
        controller.toggleChecklist()

        #expect(markdown(of: textView) == "abc\n- [ ] def")
    }

    @Test func checklistTogglesBackToAPlainParagraph() {
        let (controller, textView) = makeController(text: "abc\ndef", caret: 1)
        controller.toggleChecklist()
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        controller.toggleChecklist()

        #expect(textView.string == "abc\ndef")
    }
}
