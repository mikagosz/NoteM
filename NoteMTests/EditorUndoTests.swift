import AppKit
import Foundation
import Testing
@testable import NoteM

/// ⌘Z over the editor's own edits.
///
/// `shouldChangeText(in:replacementString:)` decides what goes on the undo
/// stack, and `nil` means "only attributes are changing". Three places passed
/// `nil` while replacing characters, so undoing a list left its markers in the
/// text and undoing a tick left the task ticked. These tests fail the moment
/// `nil` comes back.
///
/// The text view has to sit in a window: without one `undoManager` is nil, undo
/// is a no-op and every test here would pass by doing nothing at all. That is
/// what `undoIsLive` guards against — it is the positive control for the rest
/// of the file.
@MainActor
struct EditorUndoTests {

    private final class Harness {
        let window: NSWindow
        let textView: NoteTextView
        let controller = RichTextController()

        init(text: String, caret: Int) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
            textView = NoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
            textView.allowsUndo = true
            textView.controller = controller
            window.contentView = textView
            window.makeFirstResponder(textView)
            controller.attach(textView)
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: text, attributes: MarkdownStyler.defaultTypingAttributes)
            )
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        }

        var markdown: String { MarkdownStyler.markdown(from: textView.attributedString()) }
        func undo() { textView.undoManager?.undo() }

        /// Runs `edit` as one undo step, the way one user action is.
        ///
        /// `NSUndoManager` normally closes a group when the run loop turns over,
        /// which is once per event. A test performs several edits inside a
        /// single turn, so they all land in one group — measured: undoing after
        /// "make a checklist, tick it" reverted both and left nothing to undo,
        /// which would have made the test below prove nothing. Taking the
        /// grouping over by hand is the honest stand-in for separate clicks.
        func asOneStep(_ edit: () -> Void) {
            guard let undoManager = textView.undoManager else {
                Issue.record("Bez okna nie ma undoManagera — test nie mierzy niczego")
                return
            }
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
            edit()
            undoManager.endUndoGrouping()
        }
    }

    // MARK: - Positive control

    @Test func undoIsLive() {
        let h = Harness(text: "abc", caret: 3)
        h.textView.insertText("XY", replacementRange: NSRange(location: 3, length: 0))
        #expect(h.textView.string == "abcXY")
        #expect(h.textView.undoManager?.canUndo == true)
        h.undo()
        #expect(h.textView.string == "abc")
    }

    // MARK: - The three places that used to pass `nil`

    @Test func undoTakesTheBulletMarkerBackOut() {
        let h = Harness(text: "abc", caret: 1)
        h.controller.toggleList("bullet")
        #expect(h.textView.string == "\(MarkdownStyler.bulletMarker)abc")

        h.undo()
        #expect(h.textView.string == "abc")
    }

    @Test func undoTakesTheNumberBackOut() {
        let h = Harness(text: "abc\ndef", caret: 1)
        h.controller.toggleList("ordered")
        #expect(h.textView.string.hasPrefix("1. "))

        h.undo()
        #expect(h.textView.string == "abc\ndef")
    }

    @Test func undoTakesTheCheckboxBackOut() {
        let h = Harness(text: "kupić mleko", caret: 2)
        h.controller.toggleChecklist()
        #expect(h.markdown == "- [ ] kupić mleko")

        h.undo()
        #expect(h.textView.string == "kupić mleko")
        #expect(h.markdown == "kupić mleko")
    }

    @Test func undoUnticksATask() {
        let h = Harness(text: "kupić mleko", caret: 2)
        h.asOneStep { h.controller.toggleChecklist() }
        h.asOneStep { h.textView.toggleChecklistBox(at: 0, currentlyChecked: false) }
        #expect(h.markdown == "- [x] kupić mleko")

        h.undo()
        #expect(h.markdown == "- [ ] kupić mleko")
        // The tick lives in an attribute spread over the paragraph, not in the
        // glyph alone: the whole paragraph has to come back unticked, or the box
        // looks empty while the note still reads `- [x]`.
        let storage = h.textView.textStorage
        #expect(storage?.attribute(.checklist, at: 0, effectiveRange: nil) as? Bool == false)
        #expect(storage?.attribute(.checklist, at: 4, effectiveRange: nil) as? Bool == false)
    }

    // MARK: - What already worked, pinned so the fix doesn't cost it

    @Test func undoStillReversesATable() {
        let h = Harness(text: "abc", caret: 3)
        h.controller.insertTable(rows: 2, columns: 2)
        #expect(h.textView.string != "abc")

        h.undo()
        #expect(h.textView.string == "abc")
    }
}

/// Sizes and offsets that used to be computed in the wrong unit — or not
/// clamped at all.
@MainActor
struct EditorGeometryTests {

    private func editor(text: String, selection: NSRange) -> (RichTextController, NSTextView) {
        let textView = NoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let controller = RichTextController()
        controller.attach(textView)
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: MarkdownStyler.defaultTypingAttributes)
        )
        textView.setSelectedRange(selection)
        return (controller, textView)
    }

    /// Every cell is its own text block and its own paragraph, and the layout
    /// cost grows faster than the cell count — 200×200 froze the window for
    /// 3,3 s. The hand-typed field takes any number, so the clamp lives in the
    /// editor, not only in the picker.
    @Test func aTableIsNeverBiggerThanTheLimit() {
        let (controller, textView) = editor(text: "", selection: NSRange(location: 0, length: 0))
        controller.insertTable(rows: 500, columns: 500)

        let side = RichTextController.maxTableSide
        // One paragraph per cell, plus the trailing paragraph for the caret.
        let paragraphs = textView.string.components(separatedBy: "\n").count - 1
        #expect(paragraphs == side * side + 1)
    }

    @Test func aTableSmallerThanTheLimitIsLeftAlone() {
        let (controller, textView) = editor(text: "", selection: NSRange(location: 0, length: 0))
        controller.insertTable(rows: 3, columns: 4)

        let paragraphs = textView.string.components(separatedBy: "\n").count - 1
        #expect(paragraphs == 3 * 4 + 1)
    }

    /// The caret is an NSRange index (UTF-16), the wrapped string was measured
    /// in Swift `Character`s — the two differ the moment an emoji is selected.
    @Test func theCaretLandsAfterInlineCodeEvenWithEmoji() {
        let text = "a👨‍👩‍👧‍👦b"
        let (controller, textView) = editor(
            text: text, selection: NSRange(location: 0, length: (text as NSString).length)
        )
        controller.insertInlineCode()

        #expect(textView.string == "`\(text)`")
        // Right after the closing backtick, i.e. at the end of the text.
        #expect(textView.selectedRange().location == (textView.string as NSString).length)
    }

    /// Generated filenames must not follow whatever calendar the Mac is set to.
    @Test func theFileStampIsCalendarIndependent() {
        let formatter = RichTextController.fileStampFormatter
        #expect(formatter.locale.identifier == "en_US_POSIX")

        // 2026-08-11 12:00:00 UTC, read back in the formatter's own time zone.
        let date = Date(timeIntervalSince1970: 1_786_536_000)
        var reference = Calendar(identifier: .gregorian)
        reference.timeZone = formatter.timeZone
        #expect(reference.component(.year, from: date) == 2026)
        #expect(formatter.string(from: date).hasPrefix("2026-"))
    }
}
