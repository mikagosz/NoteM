import AppKit
import SwiftUI

extension NSPasteboard.PasteboardType {
    /// Private type used to round-trip NoteM's full attributed string (including
    /// custom attributes like headerLevel / listKind / checklist) within the same
    /// app, without going through RTF which strips those custom keys.
    static let noteMRichText = NSPasteboard.PasteboardType("com.notem.richtext")
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

    /// Folder of the currently loaded note; used for resolving attachment paths.
    var noteFolder: URL?
    /// Called when the user drops a file — returns the attachment filename, or nil.
    var onAddAttachment: ((URL) -> String?)?

    private var storedContent = NSAttributedString()
    private var isSettingText = false
    private var floatingPanel: FloatingFormatPanel?

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

    /// Shows / hides the floating format panel whenever the selection changes.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView else { return }
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
    }

    func insertLink() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let selectedText = range.length > 0 ? (storage.string as NSString).substring(with: range) : "link"
        let template = "[\(selectedText)](url)"
        let str = NSAttributedString(string: template, attributes: MarkdownStyler.defaultTypingAttributes)
        guard textView.shouldChangeText(in: range, replacementString: template) else { return }
        storage.replaceCharacters(in: range, with: str)
        textView.didChangeText()
        // Select the "url" part so user can immediately type the address.
        let urlStart = range.location + selectedText.count + 3
        let urlLen = 3
        if urlStart + urlLen <= storage.length {
            textView.setSelectedRange(NSRange(location: urlStart, length: urlLen))
        }
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
    }

    // MARK: - Table

    func insertTable() {
        let template = "| Kolumna 1 | Kolumna 2 | Kolumna 3 |\n|-----------|-----------|----------|\n|           |           |          |"
        let attrs = MarkdownStyler.defaultTypingAttributes
        let str = NSAttributedString(string: template, attributes: attrs)
        guard let textView else { return }
        let range = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: template) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: str)
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

        let marker = kind == "bullet" ? MarkdownStyler.bulletMarker : "\(orderedNumber). "
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
                default: break
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Clicking a checklist's checkbox toggles its state (and autosaves) instead
    /// of moving the caret.
    override func mouseDown(with event: NSEvent) {
        if toggleChecklistIfCheckboxClicked(event) { return }
        if openWikiLinkIfClicked(event) { return }
        super.mouseDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        maybeShowWikiCompletion()
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

    override func copy(_ sender: Any?) {
        super.copy(sender)
        writeNoteMType(for: selectedRange())
    }

    override func cut(_ sender: Any?) {
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
                return
            }
        }

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

        if let string = pasteboard.string(forType: .string) {
            insertAttributed(NSAttributedString(string: string, attributes: MarkdownStyler.defaultTypingAttributes))
            return
        }

        super.paste(sender)
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

        for url in fileURLs {
            guard let filename = controller?.onAddAttachment?(url) else { continue }
            let isImage = ["jpg","jpeg","png","gif","heic","tiff","bmp","webp","svg"]
                .contains(url.pathExtension.lowercased())

            if isImage, let folder = controller?.noteFolder {
                let imageURL = folder.appendingPathComponent("attachments/\(filename)")
                if let image = NSImage(contentsOf: imageURL) {
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    let maxW: CGFloat = 480
                    if image.size.width > maxW {
                        let s = maxW / image.size.width
                        attachment.bounds = CGRect(x: 0, y: 0, width: maxW, height: image.size.height * s)
                    }
                    insertAttributed(NSAttributedString(attachment: attachment))
                    continue
                }
            }
            let link = isImage
                ? "![](attachments/\(filename))"
                : "[\(url.lastPathComponent)](attachments/\(filename))"
            insertAttributed(NSAttributedString(string: link, attributes: MarkdownStyler.defaultTypingAttributes))
        }
        return true
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
        textView.isAutomaticLinkDetectionEnabled = true
        textView.registerForDraggedTypes([.fileURL])

        scrollView.documentView = textView
        controller.attach(textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Content and formatting are driven imperatively through the controller.
    }
}
