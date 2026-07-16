import AppKit
import SwiftUI

extension NSPasteboard.PasteboardType {
    /// Private type used to round-trip NoteM's full attributed string (including
    /// custom attributes like headerLevel / listKind / checklist) within the same
    /// app, without going through RTF which strips those custom keys.
    static let noteMRichText = NSPasteboard.PasteboardType("com.notem.richtext")
}

extension NSAttributedString.Key {
    /// User-set display width / height (in points) for a resized image attachment.
    /// Stored on the attachment character so the size survives archiving/reload and
    /// is re-applied to `NSTextAttachment.bounds` on load. Height is optional; when
    /// missing the aspect ratio of the image is used.
    static let noteMImageWidth = NSAttributedString.Key("noteMImageWidth")
    static let noteMImageHeight = NSAttributedString.Key("noteMImageHeight")
    /// Filename (inside the note's `attachments/` folder) that an inline image
    /// attachment came from. Stored on the attachment character so it survives
    /// archiving; used to prune attachment files the user removed from the note.
    static let noteMAttachmentName = NSAttributedString.Key("noteMAttachmentName")
    /// Marks a paragraph as a block quote (indented + tinted text).
    static let noteMBlockquote = NSAttributedString.Key("noteMBlockquote")
}

/// Marker subclass for NoteM's inline image attachments. It renders at its
/// natural size (or an explicit resized `bounds`) — sizing to the window is done
/// on demand via the "fit" button, not automatically.
final class FittingTextAttachment: NSTextAttachment {}

/// Lossless disk format for a note's attributed string: a keyed archive that
/// preserves colours, fonts, sizes, inline images and NoteM's custom attributes.
enum NoteRichArchive {
    static func data(from attributed: NSAttributedString) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(attributed, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    static func attributedString(from data: Data) -> NSAttributedString? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSAttributedString
    }
}

/// The set of toggle-style formats active at the caret / selection, so the
/// toolbar can highlight the buttons that are currently "on".
struct ActiveFormats: OptionSet {
    let rawValue: Int
    static let bold          = ActiveFormats(rawValue: 1 << 0)
    static let italic        = ActiveFormats(rawValue: 1 << 1)
    static let underline     = ActiveFormats(rawValue: 1 << 2)
    static let bulletList     = ActiveFormats(rawValue: 1 << 3)
    static let numberedList   = ActiveFormats(rawValue: 1 << 4)
    static let checklist      = ActiveFormats(rawValue: 1 << 5)
    static let strikethrough  = ActiveFormats(rawValue: 1 << 6)
    static let dashList       = ActiveFormats(rawValue: 1 << 7)
    static let blockquote     = ActiveFormats(rawValue: 1 << 8)
}

/// Predefined paragraph styles offered in the "Aa" style panel.
enum ParagraphStyleKind: String, CaseIterable {
    case title, heading, subheading, body, monospaced
}

/// Drives formatting commands on the underlying `NSTextView` and reports edits
/// back to SwiftUI. Owned by `NoteDetailView` as `@State` so it survives view
/// updates; the text view is attached once in `RichTextEditor.makeNSView`.
final class RichTextController: NSObject, NSTextViewDelegate {
    weak var textView: NSTextView?
    /// Called after any user edit, with the current attributed content.
    var onChange: ((NSAttributedString) -> Void)?
    /// Supplies note titles for `[[` wiki-link autocompletion.
    var titlesProvider: () -> [String] = { [] }
    /// Called when a wiki link is clicked, with the linked note's title.
    var onOpenWikiLink: ((String) -> Void)?
    /// Called whenever the caret/selection moves, reporting the font size at
    /// the insertion point so the toolbar's size field can stay in sync.
    var onFontSizeChange: ((CGFloat) -> Void)?
    /// Called when the active toggle formats change, so the toolbar can
    /// highlight the buttons (bold, italic, underline, lists, checklist).
    var onActiveFormatsChange: ((ActiveFormats) -> Void)?

    /// Folder of the currently loaded note; used for resolving attachment paths.
    var noteFolder: URL?
    /// Called when the user drops a file — returns the attachment filename, or nil.
    var onAddAttachment: ((URL) -> String?)?

    private var storedContent = NSAttributedString()
    private var isSettingText = false
    private var floatingPanel: FloatingFormatPanel?

    /// Marker prefix for dash-style list items.
    static let dashMarker = "– "

    // MARK: - Attaching / content

    func attach(_ textView: NSTextView) {
        self.textView = textView
        floatingPanel = FloatingFormatPanel(
            onBold:      { [weak self] in self?.toggleBold() },
            onItalic:    { [weak self] in self?.toggleItalic() },
            onH1:        { [weak self] in self?.toggleHeader(1) },
            onH2:        { [weak self] in self?.toggleHeader(2) },
            onBullet:    { [weak self] in self?.toggleList("bullet") },
            onNumbered:  { [weak self] in self?.toggleList("ordered") },
            onChecklist: { [weak self] in self?.toggleChecklist() },
            onTable:     { [weak self] in self?.insertTable() },
            onCode:      { [weak self] in self?.insertInlineCode() }
        )
        applyStoredContent()
    }

    func hideFloatingPanel() { floatingPanel?.hide() }

    /// Undo the last edit (mirrors ⌘Z), driven from the toolbar button.
    func undo() {
        guard let textView, let manager = textView.undoManager, manager.canUndo else { return }
        textView.window?.makeFirstResponder(textView)
        manager.undo()
    }

    /// Redo the last undone edit (mirrors ⇧⌘Z), driven from the toolbar button.
    func redo() {
        guard let textView, let manager = textView.undoManager, manager.canRedo else { return }
        textView.window?.makeFirstResponder(textView)
        manager.redo()
    }

    /// Shows the native find bar (⌘F) so the user can search within the note.
    func showFindBar() {
        guard let textView else { return }
        let item = NSMenuItem()
        item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        textView.performTextFinderAction(item)
    }

    /// Opens a file picker and inserts the chosen file(s) as attachments.
    func addAttachmentFromPanel() {
        guard let textView = textView as? NoteTextView else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK else { return }
            textView.window?.makeFirstResponder(textView)
            textView.insertAttachments(from: panel.urls)
        }
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
        Self.normalizeImageAttachments(in: storage)
        Self.reapplyImageSizes(in: storage)
        textView.typingAttributes = MarkdownStyler.defaultTypingAttributes
        isSettingText = false
    }

    /// Makes every inline image display correctly and auto-fit the note width:
    /// 1) rebuilds the `image` from the attachment's archived `fileWrapper`/
    ///    `contents` when the live image was lost (NSTextAttachment archives the
    ///    wrapper/contents, not a bare `image`) — this is what makes pasted /
    ///    dropped images reappear after a note reloads from note.rich; and
    /// 2) upgrades plain image attachments to `FittingTextAttachment`, so they
    ///    clamp to the column width at layout time.
    /// Checkbox attachments (their paragraph is tagged `.checklist`) and non-image
    /// attachments are left untouched, so text formatting is never affected.
    static func normalizeImageAttachments(in storage: NSTextStorage) {
        let ns = storage.string as NSString
        // Collect first; replacing the .attachment value while enumerating that
        // same key could disturb the walk.
        var replacements: [(range: NSRange, attachment: FittingTextAttachment)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let old = value as? NSTextAttachment else { return }
            let paragraphStart = ns.paragraphRange(for: NSRange(location: range.location, length: 0)).location
            if storage.attribute(.checklist, at: paragraphStart, effectiveRange: nil) != nil { return }

            // Find the image: prefer a live one, else rebuild from stored bytes.
            var image = NoteTextView.image(of: old)
            if image == nil, let data = old.fileWrapper?.regularFileContents ?? old.contents {
                image = NSImage(data: data)
            }
            guard let image else { return }   // not an image attachment

            // Already the right class and rendering via image? just ensure image.
            if let fitting = old as? FittingTextAttachment {
                fitting.image = image
                fitting.attachmentCell = nil
                return
            }
            let fitting = FittingTextAttachment()
            fitting.fileWrapper = old.fileWrapper
            fitting.contents = old.contents
            fitting.fileType = old.fileType
            fitting.bounds = old.bounds
            fitting.image = image
            replacements.append((range, fitting))
        }
        guard !replacements.isEmpty else { return }
        storage.beginEditing()
        for item in replacements {
            storage.addAttribute(.attachment, value: item.attachment, range: item.range)
        }
        storage.endEditing()
    }

    /// Restores each resized image to its saved display width. `NSTextAttachment`
    /// doesn't reliably archive its `bounds`, so we persist the width in the
    /// `.noteMImageWidth` attribute and re-apply it here (keeping the aspect ratio
    /// from the image itself).
    static func reapplyImageSizes(in storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.noteMImageWidth, in: full) { value, range, _ in
            guard let width = value as? CGFloat,
                  let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
                  let image = NoteTextView.image(of: attachment), image.size.width > 0 else { return }
            // Use the stored height if present (stretched images); otherwise keep
            // the image's aspect ratio.
            let height = (storage.attribute(.noteMImageHeight, at: range.location, effectiveRange: nil) as? CGFloat)
                ?? width * (image.size.height / image.size.width)
            attachment.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isSettingText, let textView else { return }
        onChange?(textView.attributedString())
    }

    /// Shows / hides the floating format panel whenever the selection changes.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView else { return }
        onFontSizeChange?(currentFontSize())
        notifyActiveFormats()
        let sel = textView.selectedRange()
        guard sel.length > 0, textView.window?.isKeyWindow == true else {
            floatingPanel?.hide()
            return
        }
        let screenRect = textView.firstRect(forCharacterRange: sel, actualRange: nil)
        floatingPanel?.show(above: screenRect)
    }

    /// Follow clicked wiki links (other schemes fall through to the default).
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, let title = MarkdownStyler.wikiTitle(from: url) else { return false }
        onOpenWikiLink?(title)
        return true
    }

    // MARK: - List continuation on Return

    /// Intercepts Return so that lists keep going: pressing it inside a list item
    /// starts the next item (next number / bullet / dash / checkbox); pressing it
    /// on an empty item ends the list and drops back to a plain paragraph.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)),
              let storage = textView.textStorage else { return false }

        let sel = textView.selectedRange()
        let ns = storage.string as NSString
        let paraRange = ns.paragraphRange(for: sel)
        guard paraRange.location < storage.length else { return false }

        // What kind of list (if any) is the current paragraph?
        let isChecklist = storage.attribute(.checklist, at: paraRange.location, effectiveRange: nil) != nil
        let listKind = storage.attribute(.listKind, at: paraRange.location, effectiveRange: nil) as? String
        guard isChecklist || listKind != nil else { return false }

        // The current line's text (without its trailing newline).
        var lineRange = paraRange
        if lineRange.length > 0, ns.character(at: lineRange.location + lineRange.length - 1) == 10 {
            lineRange.length -= 1
        }
        let lineText = ns.substring(with: lineRange)
        let content = listItemContent(lineText, isChecklist: isChecklist, kind: listKind)

        // Empty item + Return → end the list (plain paragraph).
        if content.isEmpty {
            guard textView.shouldChangeText(in: lineRange, replacementString: "") else { return true }
            storage.beginEditing()
            storage.replaceCharacters(
                in: lineRange,
                with: NSAttributedString(string: "", attributes: MarkdownStyler.defaultTypingAttributes)
            )
            storage.endEditing()
            textView.didChangeText()
            textView.typingAttributes = MarkdownStyler.defaultTypingAttributes
            textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
            notifyActiveFormats()
            return true
        }

        // Otherwise → start the next item on a new line.
        let newItem = NSMutableAttributedString(string: "\n", attributes: MarkdownStyler.defaultTypingAttributes)
        if isChecklist {
            newItem.append(MarkdownStyler.checkboxAttachmentString(checked: false))
            newItem.append(NSAttributedString(string: " ", attributes: MarkdownStyler.defaultTypingAttributes))
        } else if listKind == "ordered" {
            let n = leadingNumber(lineText) ?? 1
            newItem.append(NSAttributedString(string: "\(n + 1). ", attributes: MarkdownStyler.defaultTypingAttributes))
        } else if listKind == "dash" {
            newItem.append(NSAttributedString(string: RichTextController.dashMarker, attributes: MarkdownStyler.defaultTypingAttributes))
        } else {
            newItem.append(NSAttributedString(string: MarkdownStyler.bulletMarker, attributes: MarkdownStyler.defaultTypingAttributes))
        }
        let full = NSRange(location: 0, length: newItem.length)
        newItem.addAttribute(.paragraphStyle, value: MarkdownStyler.listParagraphStyle, range: full)
        if isChecklist {
            newItem.addAttribute(.checklist, value: false, range: full)
        } else if let listKind {
            newItem.addAttribute(.listKind, value: listKind, range: full)
        }

        guard textView.shouldChangeText(in: sel, replacementString: newItem.string) else { return true }
        storage.beginEditing()
        storage.replaceCharacters(in: sel, with: newItem)
        storage.endEditing()
        textView.didChangeText()

        // Caret after the new marker; keep typing attributes in the list.
        textView.setSelectedRange(NSRange(location: sel.location + newItem.length, length: 0))
        var typing = MarkdownStyler.defaultTypingAttributes
        typing[.paragraphStyle] = MarkdownStyler.listParagraphStyle
        if isChecklist {
            typing[.checklist] = false
        } else if let listKind {
            typing[.listKind] = listKind
        }
        textView.typingAttributes = typing
        notifyActiveFormats()
        return true
    }

    /// The text of a list item with its marker removed (to test for emptiness).
    private func listItemContent(_ line: String, isChecklist: Bool, kind: String?) -> String {
        if isChecklist {
            let ns = line as NSString
            var i = 0
            if ns.length > 0, ns.character(at: 0) == 0xFFFC {
                i = 1
                if ns.length > 1, ns.character(at: 1) == 32 { i = 2 }
            }
            return ns.substring(from: min(i, ns.length)).trimmingCharacters(in: .whitespaces)
        }
        switch kind {
        case "bullet":
            if line.hasPrefix(MarkdownStyler.bulletMarker) {
                return String(line.dropFirst(MarkdownStyler.bulletMarker.count)).trimmingCharacters(in: .whitespaces)
            }
        case "dash":
            if line.hasPrefix(RichTextController.dashMarker) {
                return String(line.dropFirst(RichTextController.dashMarker.count)).trimmingCharacters(in: .whitespaces)
            }
        case "ordered":
            if let n = leadingNumber(line) {
                let prefix = "\(n). "
                if line.hasPrefix(prefix) {
                    return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                }
            }
        default:
            break
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// The leading integer of `line` (e.g. 3 from "3. foo"), or nil.
    private func leadingNumber(_ line: String) -> Int? {
        let ns = line as NSString
        var i = 0
        while i < ns.length, let scalar = UnicodeScalar(ns.character(at: i)), Character(scalar).isNumber {
            i += 1
        }
        guard i > 0 else { return nil }
        return Int(ns.substring(to: i))
    }

    // MARK: - Inline formatting

    func toggleBold() { toggleTrait(.boldFontMask, symbolic: .bold) }
    func toggleItalic() { toggleTrait(.italicFontMask, symbolic: .italic) }

    func toggleUnderline() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            var attrs = textView.typingAttributes
            let current = attrs[.underlineStyle] as? Int ?? 0
            attrs[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            textView.typingAttributes = attrs
            notifyActiveFormats()
            return
        }
        var allUnderlined = true
        storage.enumerateAttribute(.underlineStyle, in: range) { value, _, _ in
            let v = value as? Int ?? 0
            if v == 0 { allUnderlined = false }
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.addAttribute(
            .underlineStyle,
            value: allUnderlined ? 0 : NSUnderlineStyle.single.rawValue,
            range: range
        )
        storage.endEditing()
        textView.didChangeText()
        notifyActiveFormats()
    }

    func insertLink() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()

        // Ask for the URL in a small dialog (prefilled from the clipboard if it
        // already holds a URL).
        let alert = NSAlert()
        alert.messageText = Loc.t("Wstaw link", "Insert link")
        alert.informativeText = Loc.t("Wklej adres URL", "Paste the URL")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "https://…"
        field.usesSingleLineMode = true
        // Disable the URL autocompletion list — its Safari helper popover conflicts
        // with the alert panel and crashes (NSRemoteView assertion).
        field.isAutomaticTextCompletionEnabled = false
        if let clip = NSPasteboard.general.string(forType: .string),
           clip.hasPrefix("http://") || clip.hasPrefix("https://") {
            field.stringValue = clip
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: Loc.t("Anuluj", "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var urlString = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !urlString.isEmpty else { return }
        if !urlString.contains("://") { urlString = "https://" + urlString }
        guard let url = URL(string: urlString) else { return }

        let linkAttrs: [NSAttributedString.Key: Any] = [
            .link: url,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        if range.length > 0 {
            // Attach the link to the selected text.
            guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
            storage.beginEditing()
            storage.addAttributes(linkAttrs, range: range)
            storage.endEditing()
            textView.didChangeText()
            // Collapse the caret past the link and clear the link typing attributes,
            // so text typed next isn't part of the link.
            textView.setSelectedRange(NSRange(location: range.location + range.length, length: 0))
            var typing = textView.typingAttributes
            typing[.link] = nil
            typing[.underlineStyle] = nil
            typing[.foregroundColor] = NSColor.labelColor
            textView.typingAttributes = typing
        } else {
            // No selection: insert the URL itself as a clickable link.
            var attrs = linkAttrs
            attrs[.font] = MarkdownStyler.bodyFont
            let linkStr = NSAttributedString(string: urlString, attributes: attrs)
            guard textView.shouldChangeText(in: range, replacementString: urlString) else { return }
            storage.replaceCharacters(in: range, with: linkStr)
            textView.didChangeText()
            // Reset typing attributes so text after the link isn't a link.
            textView.setSelectedRange(NSRange(location: range.location + linkStr.length, length: 0))
            textView.typingAttributes = MarkdownStyler.defaultTypingAttributes
        }
    }

    /// Toggles strikethrough on the selection (or the typing attributes).
    func toggleStrikethrough() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            var attrs = textView.typingAttributes
            let current = attrs[.strikethroughStyle] as? Int ?? 0
            attrs[.strikethroughStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            textView.typingAttributes = attrs
            notifyActiveFormats()
            return
        }
        var allStruck = true
        storage.enumerateAttribute(.strikethroughStyle, in: range) { value, _, _ in
            if (value as? Int ?? 0) == 0 { allStruck = false }
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.addAttribute(
            .strikethroughStyle,
            value: allStruck ? 0 : NSUnderlineStyle.single.rawValue,
            range: range
        )
        storage.endEditing()
        textView.didChangeText()
        notifyActiveFormats()
    }

    /// Sets the text colour of the selection (or of the next typed characters).
    func setTextColor(_ color: NSColor) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            var attrs = textView.typingAttributes
            attrs[.foregroundColor] = color
            textView.typingAttributes = attrs
            return
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: color, range: range)
        storage.endEditing()
        textView.didChangeText()
    }

    /// Toggles a highlight (text background colour) on the selection. Passing the
    /// same colour that's already there clears it.
    func toggleHighlight(_ color: NSColor) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            var attrs = textView.typingAttributes
            let has = attrs[.backgroundColor] != nil
            if has { attrs[.backgroundColor] = nil } else { attrs[.backgroundColor] = color }
            textView.typingAttributes = attrs
            return
        }
        var allHighlighted = true
        storage.enumerateAttribute(.backgroundColor, in: range) { value, _, _ in
            if value == nil { allHighlighted = false }
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        if allHighlighted {
            storage.removeAttribute(.backgroundColor, range: range)
        } else {
            storage.addAttribute(.backgroundColor, value: color, range: range)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    // MARK: - Paragraph styles

    /// Applies one of the predefined paragraph styles (title / heading /
    /// subheading / body / monospaced) to the current paragraph(s).
    func setParagraphStyle(_ kind: ParagraphStyleKind) {
        guard let textView, let storage = textView.textStorage else { return }
        let font: NSFont
        let headerLevel: Int?
        switch kind {
        case .title:      font = MarkdownStyler.headerFont(1); headerLevel = 1
        case .heading:    font = MarkdownStyler.headerFont(2); headerLevel = 2
        case .subheading: font = MarkdownStyler.headerFont(3); headerLevel = 3
        case .body:       font = MarkdownStyler.bodyFont;      headerLevel = nil
        case .monospaced: font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular); headerLevel = nil
        }

        let range = textView.selectedRange()

        // No selection: steer typing attributes so the next typed text uses the
        // style (until the user picks another style / turns it off).
        if range.length == 0 {
            var attrs = textView.typingAttributes
            attrs[.font] = font
            if let headerLevel { attrs[.headerLevel] = headerLevel } else { attrs[.headerLevel] = nil }
            attrs[.foregroundColor] = NSColor.labelColor
            textView.typingAttributes = attrs
            notifyActiveFormats()
            return
        }

        // Selection: apply the style to exactly the selected characters.
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.removeAttribute(.listKind, range: range)
        if let headerLevel {
            storage.addAttribute(.headerLevel, value: headerLevel, range: range)
        } else {
            storage.removeAttribute(.headerLevel, range: range)
        }
        storage.addAttribute(.font, value: font, range: range)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        storage.endEditing()
        textView.didChangeText()
        notifyActiveFormats()
    }

    /// The style at the caret / start of the selection, for highlighting the panel.
    func currentParagraphStyle() -> ParagraphStyleKind {
        guard let textView, let storage = textView.textStorage else { return .body }
        let range = textView.selectedRange()
        let level: Int?
        let font: NSFont?
        if range.length == 0, range.location >= storage.length {
            // Caret past the last character: consult the typing attributes.
            level = textView.typingAttributes[.headerLevel] as? Int
            font  = textView.typingAttributes[.font] as? NSFont
        } else {
            level = storage.attribute(.headerLevel, at: range.location, effectiveRange: nil) as? Int
            font  = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        }
        if let level { return level == 1 ? .title : level == 2 ? .heading : .subheading }
        if font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true { return .monospaced }
        return .body
    }

    // MARK: - Indent & block quote

    /// Increases (+) or decreases (−) the indentation of the current paragraph(s).
    func changeIndent(by delta: CGFloat) {
        guard let textView, let storage = textView.textStorage else { return }
        let paragraphRange = (storage.string as NSString).paragraphRange(for: textView.selectedRange())
        guard paragraphRange.length > 0,
              textView.shouldChangeText(in: paragraphRange, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: paragraphRange) { value, subrange, _ in
            let base = (value as? NSParagraphStyle) ?? .default
            let mutable = base.mutableCopy() as! NSMutableParagraphStyle
            let newFirst = max(0, mutable.firstLineHeadIndent + delta)
            let newHead  = max(0, mutable.headIndent + delta)
            mutable.firstLineHeadIndent = newFirst
            mutable.headIndent = newHead
            storage.addAttribute(.paragraphStyle, value: mutable, range: subrange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    /// Toggles a block quote on the current paragraph(s): indented, tinted,
    /// italic text tagged with `.noteMBlockquote`.
    func toggleBlockquote() {
        guard let textView, let storage = textView.textStorage else { return }
        let paragraphRange = (storage.string as NSString).paragraphRange(for: textView.selectedRange())
        guard paragraphRange.length > 0,
              textView.shouldChangeText(in: paragraphRange, replacementString: nil) else { return }
        let isQuote = storage.attribute(.noteMBlockquote, at: paragraphRange.location, effectiveRange: nil) != nil
        let fontManager = NSFontManager.shared
        storage.beginEditing()
        if isQuote {
            storage.removeAttribute(.noteMBlockquote, range: paragraphRange)
            storage.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: paragraphRange)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: paragraphRange)
            storage.enumerateAttribute(.font, in: paragraphRange) { value, subrange, _ in
                let font = value as? NSFont ?? MarkdownStyler.bodyFont
                storage.addAttribute(.font, value: fontManager.convert(font, toNotHaveTrait: .italicFontMask), range: subrange)
            }
        } else {
            let quoteStyle = NSMutableParagraphStyle()
            quoteStyle.firstLineHeadIndent = 20
            quoteStyle.headIndent = 20
            storage.addAttribute(.noteMBlockquote, value: true, range: paragraphRange)
            storage.addAttribute(.paragraphStyle, value: quoteStyle, range: paragraphRange)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: paragraphRange)
            storage.enumerateAttribute(.font, in: paragraphRange) { value, subrange, _ in
                let font = value as? NSFont ?? MarkdownStyler.bodyFont
                storage.addAttribute(.font, value: fontManager.convert(font, toHaveTrait: .italicFontMask), range: subrange)
            }
        }
        storage.endEditing()
        textView.didChangeText()
        notifyActiveFormats()
    }

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
            notifyActiveFormats()
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
        notifyActiveFormats()
    }

    // MARK: - Font size

    /// The point size of the font at the current caret / start of the selection.
    func currentFontSize() -> CGFloat {
        guard let textView else { return MarkdownStyler.bodyFont.pointSize }
        let range = textView.selectedRange()
        if range.length == 0 {
            let font = textView.typingAttributes[.font] as? NSFont ?? MarkdownStyler.bodyFont
            return font.pointSize
        }
        guard let storage = textView.textStorage, range.location < storage.length else {
            return MarkdownStyler.bodyFont.pointSize
        }
        let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            ?? MarkdownStyler.bodyFont
        return font.pointSize
    }

    /// Resizes the selected text to `size` points (keeping bold/italic traits);
    /// with no selection it steers the typing attributes for the next keystrokes.
    func setFontSize(_ size: CGFloat) {
        guard let textView, let storage = textView.textStorage else { return }
        let clamped = max(4, min(400, size))
        let fontManager = NSFontManager.shared
        let range = textView.selectedRange()

        if range.length == 0 {
            var attrs = textView.typingAttributes
            let font = attrs[.font] as? NSFont ?? MarkdownStyler.bodyFont
            attrs[.font] = fontManager.convert(font, toSize: clamped)
            textView.typingAttributes = attrs
            onFontSizeChange?(clamped)
            return
        }

        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? NSFont ?? MarkdownStyler.bodyFont
            storage.addAttribute(.font, value: fontManager.convert(font, toSize: clamped), range: subrange)
        }
        storage.endEditing()
        textView.didChangeText()
        onFontSizeChange?(clamped)
    }

    // MARK: - Font family

    /// The font family at the caret / start of the selection.
    func currentFontFamily() -> String {
        guard let textView else { return MarkdownStyler.bodyFont.familyName ?? "Helvetica" }
        let range = textView.selectedRange()
        let font: NSFont
        if range.length == 0 || range.location >= (textView.textStorage?.length ?? 0) {
            font = textView.typingAttributes[.font] as? NSFont ?? MarkdownStyler.bodyFont
        } else {
            font = textView.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
                ?? MarkdownStyler.bodyFont
        }
        let family = font.familyName ?? "Helvetica"
        // The system UI font reports an internal family name (".AppleSystemUIFont");
        // present it as the friendly "System".
        return family.hasPrefix(".") ? "System" : family
    }

    /// Changes the font family of the selection (or typing attributes), keeping
    /// the current size and bold/italic traits. Pass "System" for the system font.
    func setFontFamily(_ family: String) {
        guard let textView, let storage = textView.textStorage else { return }
        let fontManager = NSFontManager.shared

        func convertFont(_ font: NSFont) -> NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            var result = family == "System"
                ? NSFont.systemFont(ofSize: font.pointSize)
                : fontManager.convert(font, toFamily: family)
            if traits.contains(.bold)   { result = fontManager.convert(result, toHaveTrait: .boldFontMask) }
            if traits.contains(.italic) { result = fontManager.convert(result, toHaveTrait: .italicFontMask) }
            return result
        }

        let range = textView.selectedRange()
        if range.length == 0 {
            var attrs = textView.typingAttributes
            let font = attrs[.font] as? NSFont ?? MarkdownStyler.bodyFont
            attrs[.font] = convertFont(font)
            textView.typingAttributes = attrs
            return
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? NSFont ?? MarkdownStyler.bodyFont
            storage.addAttribute(.font, value: convertFont(font), range: subrange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    // MARK: - Active formats (toolbar highlight)

    private func notifyActiveFormats() {
        onActiveFormatsChange?(currentActiveFormats())
    }

    /// The toggle-style formats active at the caret / start of the selection.
    func currentActiveFormats() -> ActiveFormats {
        guard let textView, let storage = textView.textStorage else { return [] }
        var result: ActiveFormats = []
        let range = textView.selectedRange()

        // Inline traits (bold / italic / underline / strikethrough).
        let font: NSFont
        let underline: Int
        let strike: Int
        if range.length == 0 {
            font = textView.typingAttributes[.font] as? NSFont ?? MarkdownStyler.bodyFont
            underline = textView.typingAttributes[.underlineStyle] as? Int ?? 0
            strike = textView.typingAttributes[.strikethroughStyle] as? Int ?? 0
        } else if range.location < storage.length {
            font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? MarkdownStyler.bodyFont
            underline = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
            strike = storage.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
        } else {
            font = MarkdownStyler.bodyFont
            underline = 0
            strike = 0
        }
        let traits = font.fontDescriptor.symbolicTraits
        if traits.contains(.bold)   { result.insert(.bold) }
        if traits.contains(.italic) { result.insert(.italic) }
        if underline != 0           { result.insert(.underline) }
        if strike != 0              { result.insert(.strikethrough) }

        // Paragraph-level (checklist / list kind / block quote).
        if storage.length > 0 {
            let paraLoc = (storage.string as NSString).paragraphRange(for: range).location
            let idx = min(paraLoc, storage.length - 1)
            if storage.attribute(.noteMBlockquote, at: idx, effectiveRange: nil) != nil {
                result.insert(.blockquote)
            }
            if storage.attribute(.checklist, at: idx, effectiveRange: nil) != nil {
                result.insert(.checklist)
            } else if let kind = storage.attribute(.listKind, at: idx, effectiveRange: nil) as? String {
                if kind == "bullet"  { result.insert(.bulletList) }
                if kind == "ordered" { result.insert(.numberedList) }
                if kind == "dash"    { result.insert(.dashList) }
            }
        }
        return result
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
        notifyActiveFormats()
    }

    // MARK: - Checklists

    /// Turns the selected line(s) into checklist items, or back into plain
    /// paragraphs if they already are.
    func toggleChecklist() {
        guard let textView, let storage = textView.textStorage else { return }
        let paragraphRange = (storage.string as NSString).paragraphRange(for: textView.selectedRange())
        guard textView.shouldChangeText(in: paragraphRange, replacementString: nil) else { return }

        let paragraph = storage.attributedSubstring(from: paragraphRange)
        let lineStrings = paragraph.string.components(separatedBy: "\n")
        let rebuilt = NSMutableAttributedString()
        var location = 0

        for (index, lineString) in lineStrings.enumerated() {
            let length = (lineString as NSString).length
            let line = NSMutableAttributedString(
                attributedString: paragraph.attributedSubstring(from: NSRange(location: location, length: length))
            )
            transformLineToChecklist(line)
            rebuilt.append(line)
            if index < lineStrings.count - 1 {
                rebuilt.append(NSAttributedString(string: "\n", attributes: MarkdownStyler.defaultTypingAttributes))
            }
            location += length + 1
        }

        storage.replaceCharacters(in: paragraphRange, with: rebuilt)
        textView.didChangeText()
        notifyActiveFormats()
    }

    // MARK: - Table

    func insertTable() { insertTable(rows: 3, columns: 3) }

    /// Inserts a real, bordered `NSTextTable` with the given number of rows
    /// (including the header row) and columns — aligned cells you can type into.
    func insertTable(rows: Int, columns: Int) {
        guard let textView, let storage = textView.textStorage else { return }
        let cols = max(1, columns)
        let rws = max(1, rows)

        let table = NSTextTable()
        table.numberOfColumns = cols
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        let result = NSMutableAttributedString()
        for r in 0..<rws {
            for c in 0..<cols {
                let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1,
                                             startingColumn: c, columnSpan: 1)
                block.setBorderColor(.separatorColor)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(5, type: .absoluteValueType, for: .padding)
                block.setValue(110, type: .absoluteValueType, for: .width)

                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                let font = r == 0 ? NSFont.boldSystemFont(ofSize: 14) : MarkdownStyler.bodyFont
                result.append(NSAttributedString(string: "\u{00A0}\n", attributes: [
                    .paragraphStyle: paragraph,
                    .font: font,
                    .foregroundColor: NSColor.labelColor
                ]))
            }
        }
        // A trailing plain paragraph so the caret can continue below the table.
        result.append(NSAttributedString(string: "\n", attributes: MarkdownStyler.defaultTypingAttributes))

        let range = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: result.string) else { return }
        storage.replaceCharacters(in: range, with: result)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
    }

    // MARK: - Inline code

    func insertInlineCode() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let selectedText = range.length > 0 ? (storage.string as NSString).substring(with: range) : ""
        let wrapped = "`\(selectedText)`"
        var attrs = MarkdownStyler.defaultTypingAttributes
        attrs[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let str = NSAttributedString(string: wrapped, attributes: attrs)
        guard textView.shouldChangeText(in: range, replacementString: wrapped) else { return }
        storage.replaceCharacters(in: range, with: str)
        textView.didChangeText()
        // Place cursor inside the backticks when no selection
        let cursorPos = range.length == 0 ? range.location + 1 : range.location + wrapped.count
        textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
    }

    private func transformLineToChecklist(_ line: NSMutableAttributedString) {
        let isChecklist = line.length > 0 && line.attribute(.checklist, at: 0, effectiveRange: nil) != nil
        stripListMarker(line)
        let full = { NSRange(location: 0, length: line.length) }

        // Toggling checklist off: leave a plain body paragraph.
        if isChecklist {
            line.removeAttribute(.checklist, range: full())
            line.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: full())
            return
        }

        line.removeAttribute(.listKind, range: full())
        line.insert(NSAttributedString(string: " ", attributes: MarkdownStyler.defaultTypingAttributes), at: 0)
        line.insert(MarkdownStyler.checkboxAttachmentString(checked: false), at: 0)
        line.addAttribute(.checklist, value: false, range: full())
        line.addAttribute(.paragraphStyle, value: MarkdownStyler.listParagraphStyle, range: full())
    }

    private func transformLine(_ line: NSMutableAttributedString, to kind: String, orderedNumber: inout Int) {
        let existing = line.length > 0
            ? line.attribute(.listKind, at: 0, effectiveRange: nil) as? String
            : nil
        stripListMarker(line)
        line.removeAttribute(.checklist, range: NSRange(location: 0, length: line.length))

        let full = { NSRange(location: 0, length: line.length) }

        // Toggling the same kind off: leave a plain body paragraph.
        if existing == kind {
            line.removeAttribute(.listKind, range: full())
            line.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: full())
            return
        }

        let marker: String
        switch kind {
        case "bullet":  marker = MarkdownStyler.bulletMarker
        case "dash":    marker = RichTextController.dashMarker
        default:        marker = "\(orderedNumber). "
        }
        if kind == "ordered" { orderedNumber += 1 }
        line.insert(NSAttributedString(string: marker, attributes: MarkdownStyler.defaultTypingAttributes), at: 0)
        line.addAttribute(.listKind, value: kind, range: full())
        line.addAttribute(.paragraphStyle, value: MarkdownStyler.listParagraphStyle, range: full())
        line.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full())
    }

    private func stripListMarker(_ line: NSMutableAttributedString) {
        let text = line.string
        // Checklist: a leading checkbox attachment (U+FFFC) + optional space.
        if let first = (text as NSString).length > 0 ? (text as NSString).character(at: 0) : nil,
           first == 0xFFFC {
            let ns = text as NSString
            var removeCount = 1
            if ns.length > 1, ns.character(at: 1) == 32 { removeCount += 1 }
            line.deleteCharacters(in: NSRange(location: 0, length: removeCount))
            return
        }
        if text.hasPrefix(MarkdownStyler.bulletMarker) {
            line.deleteCharacters(in: NSRange(location: 0, length: (MarkdownStyler.bulletMarker as NSString).length))
            return
        }
        if text.hasPrefix(RichTextController.dashMarker) {
            line.deleteCharacters(in: NSRange(location: 0, length: (RichTextController.dashMarker as NSString).length))
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
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), let controller {
            let chars = event.charactersIgnoringModifiers?.lowercased()
            // Cmd+Shift+L: insert / toggle a checklist item.
            if flags.contains(.shift) {
                if chars == "l" { controller.toggleChecklist(); return true }
            } else {
                switch chars {
                case "b": controller.toggleBold(); return true
                case "i": controller.toggleItalic(); return true
                case "1": controller.toggleHeader(1); return true
                case "2": controller.toggleHeader(2); return true
                case "3": controller.toggleHeader(3); return true
                // Cmd+O: fit the selected image to the window (only if one is
                // selected & oversized; otherwise fall through to the default).
                case "o": if fitSelectedImageToWindow() { return true }
                default: break
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Polish context menu

    /// The app isn't localized to Polish, so AppKit serves its standard editing
    /// menu (Cut/Copy/Paste/Font/…) in English. We take that menu and rename the
    /// items to Polish; actions and key equivalents are left untouched.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        // The system menu is already English; only rewrite it to Polish in PL mode.
        if Loc.language == .pl { Self.localizeToPolish(menu) }
        return menu
    }

    /// Exact English → Polish titles for the editing context menu and its submenus.
    private static let polishMenuTitles: [String: String] = [
        "Cut": "Wytnij",
        "Copy": "Kopiuj",
        "Paste": "Wklej",
        "Paste and Match Style": "Wklej i dopasuj styl",
        "Delete": "Usuń",
        "Select All": "Zaznacz wszystko",
        "Font": "Czcionka",
        "Show Fonts": "Pokaż czcionki",
        "Bold": "Pogrubienie",
        "Italic": "Kursywa",
        "Underline": "Podkreślenie",
        "Outline": "Kontur",
        "Styles": "Style",
        "Bigger": "Większa",
        "Smaller": "Mniejsza",
        "Kern": "Kerning",
        "Ligature": "Ligatury",
        "Baseline": "Linia bazowa",
        "Use Default": "Użyj domyślnych",
        "Use None": "Nie używaj",
        "Use All": "Użyj wszystkich",
        "Superscript": "Indeks górny",
        "Subscript": "Indeks dolny",
        "Raise": "Podnieś",
        "Lower": "Obniż",
        "Copy Style": "Kopiuj styl",
        "Paste Style": "Wklej styl",
        "Show Colors": "Pokaż kolory",
        "Spelling and Grammar": "Pisownia i gramatyka",
        "Show Spelling and Grammar": "Pokaż pisownię i gramatykę",
        "Check Document Now": "Sprawdź dokument teraz",
        "Check Spelling While Typing": "Sprawdzaj pisownię podczas pisania",
        "Check Grammar With Spelling": "Sprawdzaj gramatykę wraz z pisownią",
        "Correct Spelling Automatically": "Automatycznie poprawiaj pisownię",
        "Substitutions": "Podstawienia",
        "Show Substitutions": "Pokaż podstawienia",
        "Smart Copy/Paste": "Inteligentne kopiowanie/wklejanie",
        "Smart Quotes": "Inteligentne cudzysłowy",
        "Smart Dashes": "Inteligentne myślniki",
        "Smart Links": "Inteligentne łącza",
        "Data Detectors": "Wykrywanie danych",
        "Text Replacement": "Zamiana tekstu",
        "Transformations": "Przekształcenia",
        "Make Upper Case": "Wielkie litery",
        "Make Lower Case": "Małe litery",
        "Capitalize": "Kapitaliki",
        "Speech": "Mowa",
        "Start Speaking": "Zacznij mówić",
        "Stop Speaking": "Przestań mówić",
        "AutoFill": "Autouzupełnianie",
        "Writing Direction": "Kierunek pisania",
        "Default": "Domyślny",
        "Left to Right": "Od lewej do prawej",
        "Right to Left": "Od prawej do lewej",
        "Share": "Udostępnij",
        "Translate": "Przetłumacz",
        "Font…": "Czcionka…"
    ]

    /// English prefixes for items with a dynamic tail (e.g. Look Up "word").
    private static let polishMenuPrefixes: [(String, String)] = [
        ("Look Up", "Sprawdź"),
        ("Search with Google", "Szukaj w Google"),
        ("Search With Google", "Szukaj w Google"),
        ("Translate", "Przetłumacz")
    ]

    private static func localizeToPolish(_ menu: NSMenu) {
        for item in menu.items {
            if let translated = translateMenuTitle(item.title) {
                item.title = translated
            }
            if let submenu = item.submenu {
                if let t = translateMenuTitle(submenu.title) { submenu.title = t }
                localizeToPolish(submenu)
            }
        }
    }

    private static func translateMenuTitle(_ title: String) -> String? {
        if let exact = polishMenuTitles[title] { return exact }
        for (eng, pol) in polishMenuPrefixes where title.hasPrefix(eng) {
            return pol + title.dropFirst(eng.count)
        }
        return nil
    }

    /// Clicking a checklist's checkbox toggles its state (and autosaves) instead
    /// of moving the caret.
    override func mouseDown(with event: NSEvent) {
        // Clicking the "fit to window" badge shrinks the selected image to fit.
        if fitSelectedImageIfBadgeClicked(event) { return }
        // Dragging a handle of the already-selected image resizes it.
        if beginImageResizeIfHandleClicked(event) { return }
        // Pressing an image selects it and lets the user drag it to a new spot.
        if beginImageSelectOrMove(event) { return }
        // Any other click clears the image selection.
        if selectedImageRange != nil { selectedImageRange = nil; needsDisplay = true }
        if toggleChecklistIfCheckboxClicked(event) { return }
        if openWikiLinkIfClicked(event) { return }
        super.mouseDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        maybeShowWikiCompletion()
    }

    // MARK: - Delete a click-selected image with Backspace / Delete

    override func deleteBackward(_ sender: Any?) {
        if deleteSelectedImage() { return }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if deleteSelectedImage() { return }
        super.deleteForward(sender)
    }

    /// Removes the image selected by click (`selectedImageRange`) when there's no
    /// text selection, so Backspace/Delete deletes it. Returns `true` when it did.
    @discardableResult
    private func deleteSelectedImage() -> Bool {
        guard let storage = textStorage,
              let range = selectedImageRange,
              selectedRange().length == 0,
              range.location < storage.length,
              storage.attribute(.attachment, at: range.location, effectiveRange: nil) is NSTextAttachment,
              shouldChangeText(in: range, replacementString: "") else { return false }
        storage.replaceCharacters(in: range, with: "")
        setSelectedRange(NSRange(location: range.location, length: 0))
        selectedImageRange = nil
        didChangeText()
        needsDisplay = true
        return true
    }

    // MARK: - Image resizing (Word-style selection with 8 handles)

    /// The eight resize handles around a selected image, like Word.
    private enum ResizeHandle: CaseIterable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight

        var isCorner: Bool {
            self == .topLeft || self == .topRight || self == .bottomLeft || self == .bottomRight
        }
        /// A corner or a left/right side handle changes width.
        var affectsWidth: Bool { self != .top && self != .bottom }
        /// A corner or a top/bottom side handle changes height.
        var affectsHeight: Bool { self != .left && self != .right }
    }

    /// Diameter of the square selection handles.
    private static let imageHandleSize: CGFloat = 9

    /// Character range (length 1) of the image the user has selected, or `nil`.
    private var selectedImageRange: NSRange?

    /// Tracking area that delivers hover events so the cursor can switch to a
    /// resize shape over a selected image's handles.
    private var handleTrackingArea: NSTrackingArea?

    /// While dragging an image to a new spot in the text, the character index
    /// where it would be dropped — drawn as an insertion caret. `nil` otherwise.
    private var moveDropIndex: Int?

    /// The image backing an attachment, whether it stores it directly (dropped /
    /// pasted images) or via an `NSTextAttachmentCell` (markdown `![](…)` images).
    static func image(of attachment: NSTextAttachment) -> NSImage? {
        if let image = attachment.image { return image }
        if let cell = attachment.attachmentCell as? NSTextAttachmentCell { return cell.image }
        return nil
    }

    /// The resizable image attachment at `point`, if any (skips checkboxes).
    private func imageAttachment(at point: NSPoint) -> (range: NSRange, attachment: NSTextAttachment, image: NSImage)? {
        guard let storage = textStorage, storage.length > 0,
              let layoutManager, let textContainer else { return nil }
        let containerPoint = CGPoint(x: point.x - textContainerInset.width,
                                     y: point.y - textContainerInset.height)
        let charIndex = layoutManager.characterIndex(
            for: containerPoint, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard charIndex < storage.length else { return nil }
        let paragraphLocation = (storage.string as NSString)
            .paragraphRange(for: NSRange(location: charIndex, length: 0)).location
        if storage.attribute(.checklist, at: paragraphLocation, effectiveRange: nil) != nil { return nil }
        guard let attachment = storage.attribute(.attachment, at: charIndex, effectiveRange: nil) as? NSTextAttachment,
              let image = Self.image(of: attachment), image.size.width > 0 else { return nil }
        let range = NSRange(location: charIndex, length: 1)
        // Confirm the point is actually inside the image glyph.
        guard imageRect(forCharacterRange: range).contains(point) else { return nil }
        return (range, attachment, image)
    }

    /// Presses on an image select it (showing its handles); dragging past a small
    /// threshold then moves it to a new position in the text, dropping it where an
    /// insertion caret indicates. Returns `true` when an image was hit.
    private func beginImageSelectOrMove(_ event: NSEvent) -> Bool {
        let startPoint = convert(event.locationInWindow, from: nil)
        guard let hit = imageAttachment(at: startPoint) else { return false }
        selectedImageRange = hit.range
        needsDisplay = true

        let srcIndex = hit.range.location
        var moving = false

        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            let p = convert(e.locationInWindow, from: nil)
            if !moving, hypot(p.x - startPoint.x, p.y - startPoint.y) > 4 {
                moving = true
                NSCursor.closedHand.set()
            }
            if moving {
                moveDropIndex = characterIndexForInsertion(at: p)
                needsDisplay = true
                displayIfNeeded()
            }
        }

        // Perform the move on release (skip if it wasn't really a drag or the drop
        // lands on the image's own spot).
        if moving, let rawDrop = moveDropIndex,
           rawDrop != srcIndex, rawDrop != srcIndex + 1 {
            // Convert the drop caret (original-text coords) to a post-removal
            // insertion index, then move via the undo-registering path.
            let dest = rawDrop > srcIndex ? rawDrop - 1 : rawDrop
            performImageMove(from: srcIndex, to: dest)
        }

        moveDropIndex = nil
        NSCursor.arrow.set()
        needsDisplay = true
        return true
    }

    /// Moves the single image at character index `src` so it ends up at index
    /// `dest` (expressed in the text *after* the source character is removed),
    /// and registers the inverse move on the undo manager. Because removing the
    /// inserted character exactly reverses the insert, the inverse is simply
    /// "move it back to `src`", which keeps undo/redo symmetric.
    private func performImageMove(from src: Int, to dest: Int) {
        guard let storage = textStorage, src >= 0, src < storage.length else { return }
        // Snapshot the attachment (with its size attributes) so it re-inserts intact.
        let piece = storage.attributedSubstring(from: NSRange(location: src, length: 1))
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: src, length: 1), with: "")
        let insertAt = min(max(dest, 0), storage.length)
        storage.insert(piece, at: insertAt)
        storage.endEditing()
        selectedImageRange = NSRange(location: insertAt, length: 1)
        typingAttributes = MarkdownStyler.defaultTypingAttributes

        undoManager?.registerUndo(withTarget: self) { target in
            target.performImageMove(from: insertAt, to: src)
        }
        undoManager?.setActionName(Loc.t("Przeniesienie obrazka", "Move image"))

        controller?.onChange?(attributedString())
        needsDisplay = true
    }

    /// If the click starts on one of the selected image's eight handles, run a
    /// live drag loop resizing it until the mouse is released.
    private func beginImageResizeIfHandleClicked(_ event: NSEvent) -> Bool {
        guard let storage = textStorage,
              let layoutManager, let textContainer,
              let charRange = selectedImageRange,
              charRange.location < storage.length,
              let attachment = storage.attribute(.attachment, at: charRange.location, effectiveRange: nil) as? NSTextAttachment,
              let image = Self.image(of: attachment), image.size.width > 0 else { return false }

        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect(forCharacterRange: charRange)
        guard let handle = handleHit(at: point, in: rect) else { return false }

        // Snapshot the pre-drag size so the resize can be reversed by undo/redo.
        // `rect.size` is the size currently on screen (cell-based markdown images
        // report a zero `bounds`, so use the displayed rect instead).
        let originalBounds = CGRect(origin: .zero, size: rect.size)

        // Markdown (cell-based) images ignore `bounds`; promote to a plain image
        // attachment so its size becomes adjustable.
        if attachment.image == nil {
            attachment.image = image
            attachment.attachmentCell = nil
        }

        let left = rect.minX, top = rect.minY
        let aspect = image.size.height / image.size.width
        let minSize: CGFloat = 30
        let maxWidth = max(minSize, textContainer.size.width - 2 * textContainerInset.width - 4)

        var size = rect.size
        while let drag = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = convert(drag.locationInWindow, from: nil)
            if handle.isCorner {
                // Proportional: drive off the horizontal distance from the anchor.
                let width = min(max(p.x - left, minSize), maxWidth)
                size = CGSize(width: width, height: width * aspect)
            } else if handle.affectsWidth {
                size.width = min(max(p.x - left, minSize), maxWidth)
            } else if handle.affectsHeight {
                size.height = max(p.y - top, minSize)
            }
            attachment.bounds = CGRect(origin: .zero, size: size)
            layoutManager.invalidateLayout(forCharacterRange: charRange, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: charRange)
            // Force a synchronous redraw so the resize is visible live (the event
            // loop is blocked inside this tracking loop).
            needsDisplay = true
            displayIfNeeded()
            if drag.type == .leftMouseUp { break }
        }

        // Restore the pre-drag size, then re-apply the final size through the
        // undo-registering path so ⌘Z / the toolbar arrows reverse the resize.
        // Skip when the click didn't actually change the size (no drag).
        if size != originalBounds.size {
            attachment.bounds = originalBounds
            applyImageSize(range: charRange,
                           bounds: CGRect(origin: .zero, size: size),
                           width: size.width, height: size.height)
        }
        needsDisplay = true
        return true
    }

    /// Sets the display size of the image at `range` (both the live attachment
    /// `bounds` and the persisted width/height attributes) and registers the
    /// inverse on the undo manager, so ⌘Z and the toolbar arrows reverse an
    /// image resize.
    private func applyImageSize(range: NSRange, bounds: CGRect, width: CGFloat?, height: CGFloat?) {
        guard let storage = textStorage, range.location < storage.length,
              let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment
        else { return }

        // Snapshot the current size for the inverse (undo / redo) action.
        let prevBounds = attachment.bounds
        let prevWidth = storage.attribute(.noteMImageWidth, at: range.location, effectiveRange: nil) as? CGFloat
        let prevHeight = storage.attribute(.noteMImageHeight, at: range.location, effectiveRange: nil) as? CGFloat

        // A cell-based markdown image ignores `bounds`; promote it to a plain
        // image so the size takes effect.
        if attachment.image == nil, let image = Self.image(of: attachment) {
            attachment.image = image
            attachment.attachmentCell = nil
        }

        attachment.bounds = bounds
        storage.beginEditing()
        if let width { storage.addAttribute(.noteMImageWidth, value: width, range: range) }
        else { storage.removeAttribute(.noteMImageWidth, range: range) }
        if let height { storage.addAttribute(.noteMImageHeight, value: height, range: range) }
        else { storage.removeAttribute(.noteMImageHeight, range: range) }
        storage.endEditing()

        layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager?.invalidateDisplay(forCharacterRange: range)

        undoManager?.registerUndo(withTarget: self) { target in
            target.applyImageSize(range: range, bounds: prevBounds, width: prevWidth, height: prevHeight)
        }
        undoManager?.setActionName(Loc.t("Zmiana rozmiaru obrazka", "Resize image"))

        controller?.onChange?(attributedString())
        needsDisplay = true
    }

    /// Which handle (if any) sits under `point`, given the image's view rect.
    private func handleHit(at point: NSPoint, in rect: NSRect) -> ResizeHandle? {
        let grab = Self.imageHandleSize + 5
        for handle in ResizeHandle.allCases {
            let center = handleCenter(handle, in: rect)
            if abs(point.x - center.x) <= grab && abs(point.y - center.y) <= grab {
                return handle
            }
        }
        return nil
    }

    /// Centre point of a handle on the image's selection rect (view coords).
    private func handleCenter(_ handle: ResizeHandle, in rect: NSRect) -> NSPoint {
        let xs = [rect.minX, rect.midX, rect.maxX]
        let ys = [rect.minY, rect.midY, rect.maxY]
        switch handle {
        case .topLeft:     return NSPoint(x: xs[0], y: ys[0])
        case .top:         return NSPoint(x: xs[1], y: ys[0])
        case .topRight:    return NSPoint(x: xs[2], y: ys[0])
        case .left:        return NSPoint(x: xs[0], y: ys[1])
        case .right:       return NSPoint(x: xs[2], y: ys[1])
        case .bottomLeft:  return NSPoint(x: xs[0], y: ys[2])
        case .bottom:      return NSPoint(x: xs[1], y: ys[2])
        case .bottomRight: return NSPoint(x: xs[2], y: ys[2])
        }
    }

    // MARK: - Hover cursor over handles

    /// Keeps our hover-tracking area covering the whole visible view.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = handleTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        handleTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if applyResizeCursor(at: convert(event.locationInWindow, from: nil)) { return }
        super.cursorUpdate(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if applyResizeCursor(at: convert(event.locationInWindow, from: nil)) { return }
        super.mouseMoved(with: event)
    }

    /// Sets a resize cursor when `point` is over a selected image's handle.
    /// Returns `true` when it did (so the caller leaves the default I-beam alone).
    @discardableResult
    private func applyResizeCursor(at point: NSPoint) -> Bool {
        guard let storage = textStorage,
              let charRange = selectedImageRange,
              charRange.location < storage.length,
              storage.attribute(.attachment, at: charRange.location, effectiveRange: nil) is NSTextAttachment else { return false }
        let rect = imageRect(forCharacterRange: charRange)
        if let handle = handleHit(at: point, in: rect) {
            cursor(for: handle).set()
            return true
        }
        // Over the image body: an open hand hints it can be grabbed and moved.
        if rect.contains(point) {
            NSCursor.openHand.set()
            return true
        }
        return false
    }

    private func cursor(for handle: ResizeHandle) -> NSCursor {
        switch handle {
        case .left, .right:            return .resizeLeftRight
        case .top, .bottom:            return .resizeUpDown
        case .topLeft, .bottomRight:   return Self.resizeNWSE
        case .topRight, .bottomLeft:   return Self.resizeNESW
        }
    }

    // Diagonal resize cursors aren't public; load the system ones by selector and
    // fall back to the crosshair if unavailable.
    private static let resizeNWSE = diagonalCursor("_windowResizeNorthWestSouthEastCursor") ?? .crosshair
    private static let resizeNESW = diagonalCursor("_windowResizeNorthEastSouthWestCursor") ?? .crosshair

    private static func diagonalCursor(_ selectorName: String) -> NSCursor? {
        let selector = NSSelectorFromString(selectorName)
        guard NSCursor.responds(to: selector),
              let cursor = NSCursor.perform(selector)?.takeUnretainedValue() as? NSCursor else { return nil }
        return cursor
    }

    /// View-space rectangle of the glyph for a single-character (attachment) range.
    private func imageRect(forCharacterRange charRange: NSRange) -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let glyphs = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        return rect
    }

    // MARK: - "Fit to window" badge

    private static let fitBadgeSize: CGFloat = 24

    /// Width an image is fitted to: the text column minus its insets (matching
    /// the clamp used while manually resizing).
    private var imageColumnWidth: CGFloat {
        let container = textContainer?.size.width ?? bounds.width
        return max(30, container - 2 * textContainerInset.width - 4)
    }

    /// The "fit to window" badge rect at a selected image's top-left corner, or
    /// `nil` when the image already fits the column (so it appears only when useful).
    private func fitBadgeRect(for imageRect: NSRect) -> NSRect? {
        guard imageRect.width > imageColumnWidth + 1 else { return nil }
        let size = Self.fitBadgeSize
        return NSRect(x: imageRect.minX + 3, y: imageRect.minY + 3, width: size, height: size)
    }

    /// If the click landed on a selected, oversized image's "fit" badge, shrink
    /// the image to the column width.
    private func fitSelectedImageIfBadgeClicked(_ event: NSEvent) -> Bool {
        guard let charRange = selectedImageRange,
              charRange.location < (textStorage?.length ?? 0) else { return false }
        let rect = imageRect(forCharacterRange: charRange)
        guard let badge = fitBadgeRect(for: rect),
              badge.contains(convert(event.locationInWindow, from: nil)) else { return false }
        return fitSelectedImageToWindow()
    }

    /// Shrinks the currently selected image to the column width (keeping aspect
    /// ratio) and registers undo. No-op unless an image is selected and it's
    /// actually wider than the column. Driven by the "fit" badge and ⌘O.
    @discardableResult
    func fitSelectedImageToWindow() -> Bool {
        guard let storage = textStorage,
              let charRange = selectedImageRange,
              charRange.location < storage.length,
              let attachment = storage.attribute(.attachment, at: charRange.location, effectiveRange: nil) as? NSTextAttachment,
              let image = Self.image(of: attachment), image.size.width > 0 else { return false }
        let targetW = imageColumnWidth
        let currentW = attachment.bounds.width > 0 ? attachment.bounds.width : image.size.width
        let currentH = attachment.bounds.height > 0 ? attachment.bounds.height : image.size.height
        guard currentW > targetW + 1 else { return false }   // already fits
        let targetH = targetW * (currentH / currentW)
        applyImageSize(range: charRange,
                       bounds: CGRect(x: 0, y: 0, width: targetW, height: targetH),
                       width: targetW, height: targetH)
        needsDisplay = true
        return true
    }

    /// Returns `image` tinted with `color` (used for the white badge glyph).
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.lockFocus()
        color.set()
        NSRect(origin: .zero, size: copy.size).fill(using: .sourceAtop)
        copy.unlockFocus()
        copy.isTemplate = false
        return copy
    }

    /// Draws the selection border and eight resize handles around the selected
    /// image (Word-style). Nothing is drawn when no image is selected.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let storage = textStorage,
              let charRange = selectedImageRange,
              charRange.location < storage.length,
              let attachment = storage.attribute(.attachment, at: charRange.location, effectiveRange: nil) as? NSTextAttachment,
              Self.image(of: attachment) != nil else { return }

        let rect = imageRect(forCharacterRange: charRange)
        guard rect.width > 1, rect.height > 1 else { return }

        // Selection border.
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        border.stroke()

        // Eight handles.
        let s = Self.imageHandleSize
        for handle in ResizeHandle.allCases {
            let c = handleCenter(handle, in: rect)
            let box = NSRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
            let path = NSBezierPath(ovalIn: box)
            NSColor.white.setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }

        // "Fit to window" badge (top-left) when the image is wider than the column.
        if let badge = fitBadgeRect(for: rect) {
            let bg = NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5)
            NSColor.controlAccentColor.setFill()
            bg.fill()
            NSColor.white.setStroke()
            bg.lineWidth = 1
            bg.stroke()
            if let icon = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left",
                                  accessibilityDescription: "Dopasuj do okna") {
                let conf = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                let glyph = Self.tinted(icon.withSymbolConfiguration(conf) ?? icon, .white)
                glyph.draw(in: badge.insetBy(dx: 5, dy: 5), from: .zero,
                           operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }

        // Drop-location caret while dragging the image to a new spot.
        if let dropIndex = moveDropIndex {
            let caret = insertionCaretRect(at: dropIndex)
            if caret.height > 1 {
                NSColor.controlAccentColor.setFill()
                NSRect(x: caret.minX, y: caret.minY, width: 2, height: caret.height).fill()
            }
        }
    }

    /// View-space caret rectangle for an insertion point at `charIndex`.
    private func insertionCaretRect(at charIndex: Int) -> NSRect {
        let clamped = min(max(charIndex, 0), textStorage?.length ?? 0)
        let screenRect = firstRect(forCharacterRange: NSRange(location: clamped, length: 0), actualRange: nil)
        guard let window, screenRect.height > 0 else { return .zero }
        let windowRect = window.convertFromScreen(screenRect)
        return convert(windowRect, from: nil)
    }

    // MARK: - Wiki links

    /// If the click landed on a `[[Title]]` link, open that note instead of
    /// moving the caret.
    private func openWikiLinkIfClicked(_ event: NSEvent) -> Bool {
        guard let storage = textStorage, storage.length > 0,
              let layoutManager, let textContainer else { return false }

        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = CGPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        let charIndex = layoutManager.characterIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        guard charIndex < storage.length,
              let url = storage.attribute(.link, at: charIndex, effectiveRange: nil) as? URL,
              let title = MarkdownStyler.wikiTitle(from: url) else { return false }

        // Only count it as a hit if the click is actually within the glyph.
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: charIndex, length: 1),
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        guard rect.contains(point) else { return false }

        controller?.onOpenWikiLink?(title)
        return true
    }

    /// When the caret sits right after a freshly typed `[[`, pop up a menu of
    /// note titles; picking one inserts a styled `[[Title]]` link.
    private func maybeShowWikiCompletion() {
        let selected = selectedRange()
        guard selected.length == 0, selected.location >= 2 else { return }
        let ns = string as NSString
        guard ns.substring(with: NSRange(location: selected.location - 2, length: 2)) == "[[" else { return }
        let titles = controller?.titlesProvider() ?? []
        guard !titles.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.presentWikiCompletion(titles: titles) }
    }

    private func presentWikiCompletion(titles: [String]) {
        let caret = selectedRange().location
        let ns = string as NSString
        guard caret >= 2, ns.substring(with: NSRange(location: caret - 2, length: 2)) == "[[" else { return }

        let menu = NSMenu()
        menu.autoenablesItems = false
        for title in titles.prefix(50) {
            let item = NSMenuItem(title: title, action: #selector(insertWikiSelection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = title
            menu.addItem(item)
        }

        let rect = firstRect(forCharacterRange: NSRange(location: caret, length: 0), actualRange: nil)
        guard let window else { return }
        let windowPoint = window.convertPoint(fromScreen: NSPoint(x: rect.minX, y: rect.minY))
        let viewPoint = convert(windowPoint, from: nil)
        menu.popUp(positioning: nil, at: viewPoint, in: self)
    }

    @objc private func insertWikiSelection(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String else { return }
        let caret = selectedRange().location
        guard caret >= 2 else { return }
        let range = NSRange(location: caret - 2, length: 2) // the "[[" already typed
        let link = MarkdownStyler.wikiLinkAttributed(title: title)
        guard shouldChangeText(in: range, replacementString: link.string) else { return }
        textStorage?.replaceCharacters(in: range, with: link)
        typingAttributes = MarkdownStyler.defaultTypingAttributes // don't keep styling the link
        didChangeText()
        setSelectedRange(NSRange(location: range.location + link.length, length: 0))
    }

    private func toggleChecklistIfCheckboxClicked(_ event: NSEvent) -> Bool {
        guard let storage = textStorage, storage.length > 0,
              let layoutManager, let textContainer else { return false }

        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = CGPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        let charIndex = layoutManager.characterIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        let clamped = min(charIndex, storage.length - 1)
        let paragraphRange = (storage.string as NSString).paragraphRange(for: NSRange(location: clamped, length: 0))
        guard let checked = storage.attribute(.checklist, at: paragraphRange.location, effectiveRange: nil) as? Bool else {
            return false
        }

        // Hit-test the checkbox glyph (first character of the paragraph).
        let boxGlyphs = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: paragraphRange.location, length: 1),
            actualCharacterRange: nil
        )
        var boxRect = layoutManager.boundingRect(forGlyphRange: boxGlyphs, in: textContainer)
        boxRect.origin.x += textContainerInset.width
        boxRect.origin.y += textContainerInset.height
        guard boxRect.insetBy(dx: -4, dy: -3).contains(point) else { return false }

        toggleChecklistBox(at: paragraphRange.location, currentlyChecked: checked)
        return true
    }

    private func toggleChecklistBox(at location: Int, currentlyChecked: Bool) {
        guard let storage = textStorage else { return }
        let boxRange = NSRange(location: location, length: 1)
        guard shouldChangeText(in: boxRange, replacementString: nil) else { return }
        let newChecked = !currentlyChecked
        storage.replaceCharacters(in: boxRange, with: MarkdownStyler.checkboxAttachmentString(checked: newChecked))
        let paragraphRange = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        storage.addAttribute(.checklist, value: newChecked, range: paragraphRange)
        storage.addAttribute(.paragraphStyle, value: MarkdownStyler.listParagraphStyle, range: paragraphRange)
        didChangeText()
    }

    // MARK: - Copy / Cut (write custom NoteM type for lossless round-trip)

    /// AppKit disables Copy/Cut when the text selection is empty, so an image
    /// selected only by click (which sets `selectedImageRange`, not the text
    /// selection) couldn't be copied. Re-enable them in that case.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) || item.action == #selector(cut(_:)),
           selectedImageRange != nil {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func copy(_ sender: Any?) {
        // An image selected by click has no text selection — copy it directly
        // (without moving the selection, which would pop the format panel).
        if let imgRange = selectedImageRange, selectedRange().length == 0,
           let storage = textStorage, imgRange.location + imgRange.length <= storage.length {
            writeImageToPasteboard(storage.attributedSubstring(from: imgRange))
            return
        }
        super.copy(sender)
        writeNoteMType(for: selectedRange())
    }

    override func cut(_ sender: Any?) {
        // Copy the click-selected image, then delete it.
        if let imgRange = selectedImageRange, selectedRange().length == 0,
           let storage = textStorage, imgRange.location + imgRange.length <= storage.length {
            writeImageToPasteboard(storage.attributedSubstring(from: imgRange))
            if shouldChangeText(in: imgRange, replacementString: "") {
                storage.replaceCharacters(in: imgRange, with: "")
                didChangeText()
            }
            selectedImageRange = nil
            return
        }
        // Capture before super deletes the selection
        let range = selectedRange()
        let saved: NSAttributedString? = range.length > 0
            ? textStorage?.attributedSubstring(from: range)
            : nil
        super.cut(sender)
        if let attributed = saved {
            writeNoteMType(attributed)
        }
    }

    /// Puts an image (or any attributed piece) on the pasteboard as both NoteM's
    /// lossless type and RTFD, so it pastes inside NoteM and into other apps.
    private func writeImageToPasteboard(_ piece: NSAttributedString) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.rtfd], owner: nil)
        if let rtfd = piece.rtfd(from: NSRange(location: 0, length: piece.length), documentAttributes: [:]) {
            pasteboard.setData(rtfd, forType: .rtfd)
        }
        writeNoteMType(piece)   // appends NoteM's lossless type
    }

    private func writeNoteMType(for range: NSRange) {
        guard range.length > 0, let storage = textStorage else { return }
        writeNoteMType(storage.attributedSubstring(from: range))
    }

    private func writeNoteMType(_ attributed: NSAttributedString) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(attributed, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let data = archiver.encodedData
        NSPasteboard.general.addTypes([.noteMRichText], owner: nil)
        NSPasteboard.general.setData(data, forType: .noteMRichText)
    }

    /// Custom paste: prefer NoteM's own rich-text type (lossless), then RTF/HTML
    /// (sanitized), then plain text.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general

        // NoteM-to-NoteM: our private type preserves all custom attributes without RTF loss.
        if let data = pasteboard.data(forType: .noteMRichText),
           let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) {
            unarchiver.requiresSecureCoding = false
            if let attributed = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSAttributedString {
                insertAttributed(attributed)
                if let storage = textStorage { RichTextController.normalizeImageAttachments(in: storage) }
                return
            }
        }

        // Keep the source formatting 1:1 (colours, fonts, sizes, images). RTFD
        // first so clipboard images come through, then RTF, then HTML.
        if let data = pasteboard.data(forType: .rtfd),
           let attributed = NSAttributedString(rtfd: data, documentAttributes: nil) {
            insertExternal(attributed)
            return
        }

        if let data = pasteboard.data(forType: .rtf),
           let attributed = NSAttributedString(rtf: data, documentAttributes: nil) {
            insertExternal(attributed)
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
            insertExternal(attributed)
            return
        }

        if let string = pasteboard.string(forType: .string) {
            insertAttributed(NSAttributedString(string: string, attributes: MarkdownStyler.defaultTypingAttributes))
            return
        }

        // Raw bitmap (e.g. a screenshot copied with ⌘⇧⌃4): save it as a real
        // attachments/ file so it shows up in "Załączniki" and OCR can index
        // it (Zadanie 2.1). Falls through to the default embedded paste when
        // there's no note to attach to (quick capture).
        if insertPastedImage(from: pasteboard) { return }

        super.paste(sender)
    }

    /// Saves a pasted raw image as a file in the note's `attachments/` folder
    /// and inserts it inline. Returns `false` when the pasteboard has no image
    /// or no note folder is available.
    private func insertPastedImage(from pasteboard: NSPasteboard) -> Bool {
        guard controller?.onAddAttachment != nil else { return false }
        let png = pasteboard.data(forType: .png)
            ?? pasteboard.data(forType: .tiff).flatMap {
                NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
            }
        guard let png else { return false }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        let name = "obraz-\(formatter.string(from: Date())).png"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        guard (try? png.write(to: tempURL)) != nil else { return false }
        insertAttachments(from: [tempURL])
        try? FileManager.default.removeItem(at: tempURL)
        return true
    }

    // MARK: - Drag & drop (attachments)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return super.performDragOperation(sender)
        }
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else { return super.performDragOperation(sender) }
        insertAttachments(from: fileURLs)
        return true
    }

    /// Copies each file into the note's `attachments/` folder and inserts it —
    /// inline for images, otherwise as a file link. Shared by drag-and-drop and
    /// the paperclip button.
    func insertAttachments(from urls: [URL]) {
        for url in urls {
            guard let filename = controller?.onAddAttachment?(url) else { continue }
            let isImage = ["jpg","jpeg","png","gif","heic","tiff","bmp","webp","svg"]
                .contains(url.pathExtension.lowercased())

            if isImage, let folder = controller?.noteFolder {
                let imageURL = folder.appendingPathComponent("attachments/\(filename)")
                if let image = NSImage(contentsOf: imageURL) {
                    // FittingTextAttachment clamps itself to the column width at
                    // layout time, so no manual sizing is needed here.
                    let attachment = FittingTextAttachment()
                    attachment.image = image
                    // Also carry the file's bytes so the image survives archiving
                    // into note.rich — a bare `attachment.image` is NOT archived.
                    if let wrapper = try? FileWrapper(url: imageURL) {
                        wrapper.preferredFilename = filename
                        attachment.fileWrapper = wrapper
                    }
                    let attributed = NSMutableAttributedString(attachment: attachment)
                    let full = NSRange(location: 0, length: attributed.length)
                    // Remember which file this image is, for attachment pruning.
                    attributed.addAttribute(.noteMAttachmentName, value: filename, range: full)
                    insertAttributed(attributed)
                    continue
                }
            }
            let link = isImage
                ? "![](attachments/\(filename))"
                : "[\(url.lastPathComponent)](attachments/\(filename))"
            insertAttributed(NSAttributedString(string: link, attributes: MarkdownStyler.defaultTypingAttributes))
        }
    }

    /// Inserts pasted-from-another-app content, first making achromatic text
    /// (white / black / grey, or no colour at all) adaptive so it stays readable
    /// against either note background — like Word's "Automatic" text colour.
    /// Genuinely coloured text (red, blue, …) is left exactly as copied.
    private func insertExternal(_ attributed: NSAttributedString) {
        let adapted = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: adapted.length)
        adapted.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            let color = value as? NSColor
            if color == nil || Self.isAchromatic(color!) {
                adapted.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        insertAttributed(adapted)
        // Upgrade any pasted images so they auto-fit the column; text formatting
        // (colours, fonts, sizes) is left exactly as pasted.
        if let storage = textStorage { RichTextController.normalizeImageAttachments(in: storage) }
    }

    /// True for near-white / near-black / grey colours (low saturation), which
    /// should follow the theme rather than keep a fixed shade.
    private static func isAchromatic(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return true }
        return rgb.saturationComponent < 0.12
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
    /// Black note background (with light text) when true, white (dark text) when false.
    var darkBackground: Bool = false

    // Read the same UserDefaults keys AppSettings persists, so toggling them in
    // Settings updates the editor live — in both the main note and quick capture.
    @AppStorage(AppSettings.spellCheckKey) private var spellCheckEnabled = true
    @AppStorage(AppSettings.autocorrectKey) private var autocorrectEnabled = false
    @AppStorage(Loc.key) private var languageRaw = AppLanguage.pl.rawValue

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // Thin overlay scrollbar that thickens on hover, regardless of the
        // system "Show scroll bars" setting.
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true

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
        // Height 26 keeps the first text line clear of the date header floating
        // top-center (in both the main note and quick capture).
        textView.textContainerInset = NSSize(width: 8, height: 26)
        textView.font = MarkdownStyler.bodyFont
        textView.textColor = NSColor.labelColor
        textView.typingAttributes = MarkdownStyler.defaultTypingAttributes
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.registerForDraggedTypes([.fileURL])

        scrollView.documentView = textView
        controller.attach(textView)
        applyBackground(to: scrollView, textView: textView)
        applySpellChecking(to: textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Content and formatting are driven imperatively through the controller;
        // the black/white background and spell-checking prefs are reconciled here.
        if let textView = nsView.documentView as? NoteTextView {
            applyBackground(to: nsView, textView: textView)
            applySpellChecking(to: textView)
        }
    }

    /// Turns spell checking (Polish dictionary, red underlines) and auto-correct
    /// on/off per the user's settings. Applies to the main editor and quick
    /// capture alike, since both use this view.
    private func applySpellChecking(to textView: NSTextView) {
        textView.isContinuousSpellCheckingEnabled = spellCheckEnabled
        textView.isAutomaticSpellingCorrectionEnabled = spellCheckEnabled && autocorrectEnabled
        textView.isGrammarCheckingEnabled = false
        guard spellCheckEnabled else { return }
        // Force the dictionary matching the app language, if installed.
        let prefix = (AppLanguage(rawValue: languageRaw) ?? .pl).spellPrefix
        let checker = NSSpellChecker.shared
        if let match = checker.availableLanguages.first(where: { $0.lowercased().hasPrefix(prefix) }) {
            checker.automaticallyIdentifiesLanguages = false
            checker.setLanguage(match)
        }
    }

    /// Switches the note area between a pure-black and pure-white background.
    /// Setting the appearance makes the dynamic text colours (labelColor, header
    /// colours) resolve to a readable shade automatically.
    private func applyBackground(to scrollView: NSScrollView, textView: NoteTextView) {
        let appearanceName: NSAppearance.Name = darkBackground ? .darkAqua : .aqua
        let appearance = NSAppearance(named: appearanceName)
        scrollView.appearance = appearance
        textView.appearance = appearance

        let color: NSColor = darkBackground ? .black : .white
        scrollView.drawsBackground = true
        scrollView.backgroundColor = color
        textView.drawsBackground = true
        textView.backgroundColor = color
    }
}
