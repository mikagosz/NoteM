import AppKit
import SwiftUI

/// Drives formatting commands on the underlying `NSTextView` and reports edits
/// back to SwiftUI. Owned by `NoteDetailView` as `@State` so it survives view
/// updates; the text view is attached once in `RichTextEditor.makeNSView`.
final class RichTextController: NSObject, NSTextViewDelegate {
    weak var textView: NSTextView?
    /// Called after any user edit, with the current attributed content.
    var onChange: ((NSAttributedString) -> Void)?

    private var storedContent = NSAttributedString()
    private var isSettingText = false

    // MARK: - Attaching / content

    func attach(_ textView: NSTextView) {
        self.textView = textView
        applyStoredContent()
    }

    /// Sets the editor content (e.g. when a note loads).
    func setContent(_ content: NSAttributedString) {
        storedContent = content
        if textView != nil { applyStoredContent() }
    }

    private func applyStoredContent() {
        guard let textView, let storage = textView.textStorage else { return }
        isSettingText = true
        storage.setAttributedString(storedContent)
        textView.typingAttributes = MarkdownStyler.defaultTypingAttributes
        isSettingText = false
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isSettingText, let textView else { return }
        onChange?(textView.attributedString())
    }

    // MARK: - Inline formatting

    func toggleBold() { toggleTrait(.boldFontMask, symbolic: .bold) }
    func toggleItalic() { toggleTrait(.italicFontMask, symbolic: .italic) }

    private func toggleTrait(_ mask: NSFontTraitMask, symbolic: NSFontDescriptor.SymbolicTraits) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let fontManager = NSFontManager.shared

        // No selection: flip the typing attribute so the next typed text changes.
        if range.length == 0 {
            var attrs = textView.typingAttributes
            let font = attrs[.font] as? NSFont ?? MarkdownStyler.bodyFont
            let has = font.fontDescriptor.symbolicTraits.contains(symbolic)
            attrs[.font] = has
                ? fontManager.convert(font, toNotHaveTrait: mask)
                : fontManager.convert(font, toHaveTrait: mask)
            textView.typingAttributes = attrs
            return
        }

        // Selection: remove the trait if every character already has it, else add.
        var allHaveTrait = true
        storage.enumerateAttribute(.font, in: range) { value, _, _ in
            let font = value as? NSFont ?? MarkdownStyler.bodyFont
            if !font.fontDescriptor.symbolicTraits.contains(symbolic) { allHaveTrait = false }
        }

        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? NSFont ?? MarkdownStyler.bodyFont
            let newFont = allHaveTrait
                ? fontManager.convert(font, toNotHaveTrait: mask)
                : fontManager.convert(font, toHaveTrait: mask)
            storage.addAttribute(.font, value: newFont, range: subrange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    // MARK: - Headers

    func toggleHeader(_ level: Int) {
        guard let textView, let storage = textView.textStorage else { return }
        let paragraphRange = (storage.string as NSString).paragraphRange(for: textView.selectedRange())

        // Empty paragraph: steer typing attributes instead.
        if paragraphRange.length == 0 {
            var attrs = textView.typingAttributes
            let current = attrs[.headerLevel] as? Int
            if current == level {
                attrs[.headerLevel] = nil
                attrs[.font] = MarkdownStyler.bodyFont
            } else {
                attrs[.headerLevel] = level
                attrs[.font] = MarkdownStyler.headerFont(level)
            }
            textView.typingAttributes = attrs
            return
        }

        guard textView.shouldChangeText(in: paragraphRange, replacementString: nil) else { return }
        let current = storage.attribute(.headerLevel, at: paragraphRange.location, effectiveRange: nil) as? Int
        storage.beginEditing()
        if current == level {
            storage.removeAttribute(.headerLevel, range: paragraphRange)
            storage.addAttribute(.font, value: MarkdownStyler.bodyFont, range: paragraphRange)
        } else {
            storage.removeAttribute(.listKind, range: paragraphRange)
            storage.addAttribute(.headerLevel, value: level, range: paragraphRange)
            storage.addAttribute(.font, value: MarkdownStyler.headerFont(level), range: paragraphRange)
        }
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: paragraphRange)
        storage.endEditing()
        textView.didChangeText()
    }

    // MARK: - Lists

    func toggleList(_ kind: String) {
        guard let textView, let storage = textView.textStorage else { return }
        let paragraphRange = (storage.string as NSString).paragraphRange(for: textView.selectedRange())
        guard textView.shouldChangeText(in: paragraphRange, replacementString: nil) else { return }

        let paragraph = storage.attributedSubstring(from: paragraphRange)
        let lineStrings = paragraph.string.components(separatedBy: "\n")
        let rebuilt = NSMutableAttributedString()
        var location = 0
        var orderedNumber = 1

        for (index, lineString) in lineStrings.enumerated() {
            let length = (lineString as NSString).length
            let line = NSMutableAttributedString(
                attributedString: paragraph.attributedSubstring(from: NSRange(location: location, length: length))
            )
            transformLine(line, to: kind, orderedNumber: &orderedNumber)
            rebuilt.append(line)
            if index < lineStrings.count - 1 {
                rebuilt.append(NSAttributedString(string: "\n", attributes: MarkdownStyler.defaultTypingAttributes))
            }
            location += length + 1
        }

        storage.replaceCharacters(in: paragraphRange, with: rebuilt)
        textView.didChangeText()
    }

    private func transformLine(_ line: NSMutableAttributedString, to kind: String, orderedNumber: inout Int) {
        let existing = line.length > 0
            ? line.attribute(.listKind, at: 0, effectiveRange: nil) as? String
            : nil
        stripListMarker(line)

        let full = { NSRange(location: 0, length: line.length) }

        // Toggling the same kind off: leave a plain body paragraph.
        if existing == kind {
            line.removeAttribute(.listKind, range: full())
            line.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: full())
            return
        }

        let marker = kind == "bullet" ? MarkdownStyler.bulletMarker : "\(orderedNumber). "
        if kind == "ordered" { orderedNumber += 1 }
        line.insert(NSAttributedString(string: marker, attributes: MarkdownStyler.defaultTypingAttributes), at: 0)
        line.addAttribute(.listKind, value: kind, range: full())
        line.addAttribute(.paragraphStyle, value: MarkdownStyler.listParagraphStyle, range: full())
        line.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full())
    }

    private func stripListMarker(_ line: NSMutableAttributedString) {
        let text = line.string
        if text.hasPrefix(MarkdownStyler.bulletMarker) {
            line.deleteCharacters(in: NSRange(location: 0, length: (MarkdownStyler.bulletMarker as NSString).length))
            return
        }
        // Leading "<digits>. "
        let ns = text as NSString
        var i = 0
        while i < ns.length, let scalar = UnicodeScalar(ns.character(at: i)), Character(scalar).isNumber {
            i += 1
        }
        if i > 0, i + 1 < ns.length, ns.character(at: i) == 46, ns.character(at: i + 1) == 32 {
            line.deleteCharacters(in: NSRange(location: 0, length: i + 2))
        }
    }
}

/// `NSTextView` subclass that routes formatting key equivalents to the controller.
final class NoteTextView: NSTextView {
    weak var controller: RichTextController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let controller {
            switch event.charactersIgnoringModifiers {
            case "b": controller.toggleBold(); return true
            case "i": controller.toggleItalic(); return true
            case "1": controller.toggleHeader(1); return true
            case "2": controller.toggleHeader(2); return true
            case "3": controller.toggleHeader(3); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Custom paste: prefer rich content (RTF/HTML) from the pasteboard,
    /// sanitize it to NoteM's supported formatting, and fall back to plain text.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general

        if let data = pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
            insertSanitized(attributed)
            return
        }

        if let data = pasteboard.data(forType: .html),
           let attributed = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue
               ],
               documentAttributes: nil
           ) {
            insertSanitized(attributed)
            return
        }

        // Plain text (or unknown source): insert unchanged.
        if let string = pasteboard.string(forType: .string) {
            insertAttributed(NSAttributedString(string: string, attributes: MarkdownStyler.defaultTypingAttributes))
            return
        }

        super.paste(sender)
    }

    private func insertSanitized(_ attributed: NSAttributedString) {
        insertAttributed(PasteSanitizer.sanitized(attributed))
    }

    private func insertAttributed(_ attributed: NSAttributedString) {
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: attributed.string) else { return }
        textStorage?.replaceCharacters(in: range, with: attributed)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + attributed.length, length: 0))
    }
}

/// SwiftUI wrapper around a scrollable `NoteTextView`.
struct RichTextEditor: NSViewRepresentable {
    let controller: RichTextController

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NoteTextView(frame: .zero)
        textView.controller = controller
        textView.delegate = controller
        textView.isEditable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 8, height: 12)
        textView.font = MarkdownStyler.bodyFont
        textView.textColor = NSColor.labelColor
        textView.typingAttributes = MarkdownStyler.defaultTypingAttributes
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        controller.attach(textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Content and formatting are driven imperatively through the controller.
    }
}
