import AppKit
import Foundation

extension NSAttributedString.Key {
    /// Header level (1/2/3) applied across a whole paragraph.
    static let headerLevel = NSAttributedString.Key("noteHeaderLevel")
    /// List kind ("bullet" / "ordered") applied across a whole paragraph.
    static let listKind = NSAttributedString.Key("noteListKind")
    /// Checklist item state (`Bool`, checked/unchecked) applied across a whole
    /// paragraph. The paragraph begins with a checkbox text attachment.
    static let checklist = NSAttributedString.Key("noteChecklist")
}

/// Two-way conversion between the editor's `NSAttributedString` and the plain
/// markdown persisted in `note.md`, plus the shared fonts/attributes used to
/// style content in the editor.
///
/// Supported subset (Faza 1): bold, italic, headers H1–H3, bulleted and
/// numbered lists. Inline emphasis is parsed with Foundation's markdown
/// parser; block structure and serialization are handled explicitly here.
enum MarkdownStyler {
    static let bulletMarker = "• "

    /// URL scheme used to encode wiki links (`[[Title]]`) as clickable links in
    /// the editor. The title is carried in the URL's resource specifier.
    static let wikiScheme = "notem-wiki"

    /// Matches a wiki link `[[Title]]`, capturing the title.
    static let wikiLinkRegex = try! NSRegularExpression(pattern: "\\[\\[([^\\[\\]]+)\\]\\]")

    /// Builds a clickable, styled attributed string for a wiki link. The visible
    /// text keeps the `[[Title]]` markers so it round-trips straight to markdown.
    static func wikiLinkAttributed(title: String) -> NSAttributedString {
        var attrs = defaultTypingAttributes
        if let url = wikiURL(for: title) {
            attrs[.link] = url
        }
        attrs[.foregroundColor] = NSColor.linkColor
        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        return NSAttributedString(string: "[[\(title)]]", attributes: attrs)
    }

    static func wikiURL(for title: String) -> URL? {
        let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? title
        return URL(string: "\(wikiScheme):\(encoded)")
    }

    /// Extracts the title from a wiki-link URL, or `nil` if it isn't one.
    static func wikiTitle(from url: URL) -> String? {
        guard url.scheme == wikiScheme else { return nil }
        let specifier = String(url.absoluteString.dropFirst(wikiScheme.count + 1))
        return specifier.removingPercentEncoding ?? specifier
    }

    static let bodyFont = NSFont.systemFont(ofSize: 14)

    static func headerFont(_ level: Int) -> NSFont {
        let size: CGFloat = level == 1 ? 28 : level == 2 ? 22 : 17
        return NSFont.boldSystemFont(ofSize: size)
    }

    static func font(bold: Bool, italic: Bool) -> NSFont {
        var f = bodyFont
        let fm = NSFontManager.shared
        if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    /// Default attributes for freshly typed body text.
    static var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: NSColor.labelColor]
    }

    /// Paragraph style for list items (hanging indent so wrapped lines align).
    static let listParagraphStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.headIndent = 18
        p.firstLineHeadIndent = 0
        return p
    }()

    // MARK: - Checklists

    /// Accent colour used to tint checklist checkboxes. Set from the app theme so
    /// checkboxes follow the selected colour (see ContentView).
    static var checkboxColor: NSColor = .controlAccentColor

    /// A single checkbox rendered as a clickable text attachment. Unchecked: a
    /// larger empty square with a thicker outline (bold weight), tinted with the
    /// theme accent. Checked: a real green ✅ emoji, so it reads as a checkmark
    /// (a single-colour SF Symbol would collapse into a plain green blob).
    static func checkboxAttachmentString(checked: Bool) -> NSAttributedString {
        let attachment = NSTextAttachment()
        if checked {
            attachment.image = checkmarkEmojiImage()
        } else {
            // Bold weight on the empty square gives it the thicker border.
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [checkboxColor]))
            attachment.image = NSImage(systemSymbolName: "square", accessibilityDescription: "do zrobienia")?
                .withSymbolConfiguration(config)
        }
        return NSAttributedString(attachment: attachment)
    }

    /// Draws the ✅ emoji into an image so a completed checklist item shows a
    /// proper green checkmark regardless of the note's text colour or background.
    private static func checkmarkEmojiImage() -> NSImage {
        let emoji = "✅" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15)]
        let size = emoji.size(withAttributes: attrs)
        let image = NSImage(size: size)
        image.lockFocus()
        emoji.draw(at: .zero, withAttributes: attrs)
        image.unlockFocus()
        return image
    }

    /// Builds a checklist paragraph: `[checkbox] content`, tagged `.checklist`.
    static func checklistParagraph(checked: Bool, content: String) -> NSAttributedString {
        let paragraph = NSMutableAttributedString(attributedString: checkboxAttachmentString(checked: checked))
        paragraph.append(NSAttributedString(string: " ", attributes: defaultTypingAttributes))
        paragraph.append(attributed(inline: content))
        let full = NSRange(location: 0, length: paragraph.length)
        paragraph.addAttribute(.checklist, value: checked, range: full)
        paragraph.addAttribute(.paragraphStyle, value: listParagraphStyle, range: full)
        return paragraph
    }

    // MARK: - Markdown -> NSAttributedString

    static func attributedString(fromMarkdown markdown: String, noteFolder: URL? = nil) -> NSAttributedString {
        let lines = markdown.components(separatedBy: "\n")
        let out = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            out.append(attributedParagraph(fromMarkdownLine: line, noteFolder: noteFolder))
            if index < lines.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: defaultTypingAttributes))
            }
        }
        return out
    }

    private static func attributedParagraph(fromMarkdownLine line: String, noteFolder: URL? = nil) -> NSAttributedString {
        // Inline image: ![alt](attachments/filename)
        if line.hasPrefix("!["), let parenOpen = line.firstIndex(of: "("), let parenClose = line.lastIndex(of: ")") {
            let path = String(line[line.index(after: parenOpen)..<parenClose])
            if path.hasPrefix("attachments/"), let folder = noteFolder {
                let fileURL = folder.appendingPathComponent(path)
                if let image = NSImage(contentsOf: fileURL) {
                    let attachment = NSTextAttachment()
                    let cell = NSTextAttachmentCell(imageCell: image)
                    attachment.attachmentCell = cell
                    return NSAttributedString(attachment: attachment)
                }
            }
        }

        // Header: #, ##, ### followed by a space.
        if let (level, content) = parseHeader(line) {
            return NSMutableAttributedString(
                string: content,
                attributes: [
                    .font: headerFont(level),
                    .headerLevel: level,
                    .foregroundColor: NSColor.labelColor
                ]
            )
        }

        // Checklist item: "- [ ] " or "- [x] " (before the plain bullet check).
        if let (checked, content) = parseChecklist(line) {
            return checklistParagraph(checked: checked, content: content)
        }

        // Bulleted list: "- " or "* ".
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            let content = String(line.dropFirst(2))
            return listParagraph(marker: bulletMarker, content: content, kind: "bullet")
        }

        // Numbered list: "<digits>. ".
        if let (number, content) = parseOrdered(line) {
            return listParagraph(marker: "\(number). ", content: content, kind: "ordered")
        }

        // Plain body paragraph.
        return attributed(inline: line)
    }

    private static func listParagraph(marker: String, content: String, kind: String) -> NSAttributedString {
        let paragraph = NSMutableAttributedString(string: marker, attributes: defaultTypingAttributes)
        paragraph.append(attributed(inline: content))
        let full = NSRange(location: 0, length: paragraph.length)
        paragraph.addAttribute(.listKind, value: kind, range: full)
        paragraph.addAttribute(.paragraphStyle, value: listParagraphStyle, range: full)
        paragraph.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        return paragraph
    }

    /// Parses a line of inline markdown, turning `[[Title]]` spans into styled
    /// wiki links and running the rest through the emphasis/link parser.
    private static func attributed(inline markdown: String) -> NSAttributedString {
        let ns = markdown as NSString
        let matches = wikiLinkRegex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return attributedEmphasis(inline: markdown) }

        let result = NSMutableAttributedString()
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let segment = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                result.append(attributedEmphasis(inline: segment))
            }
            let title = ns.substring(with: match.range(at: 1))
            result.append(wikiLinkAttributed(title: title))
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result.append(attributedEmphasis(inline: ns.substring(from: cursor)))
        }
        return result
    }

    /// Parses inline emphasis (bold/italic) and standard links from a segment.
    private static func attributedEmphasis(inline markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: defaultTypingAttributes)
        }
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            let bold = intent.contains(.stronglyEmphasized)
            let italic = intent.contains(.emphasized)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(bold: bold, italic: italic),
                .foregroundColor: NSColor.labelColor
            ]
            if let url = run.link {
                attributes[.link] = url
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
    }

    // MARK: - NSAttributedString -> Markdown

    static func markdown(from attributed: NSAttributedString) -> String {
        let paragraphs = attributed.string.components(separatedBy: "\n")
        var lines: [String] = []
        var location = 0
        for paragraph in paragraphs {
            let length = (paragraph as NSString).length
            let range = NSRange(location: location, length: length)
            lines.append(markdownLine(from: attributed.attributedSubstring(from: range)))
            location += length + 1 // + newline
        }
        return lines.joined(separator: "\n")
    }

    private static func markdownLine(from paragraph: NSAttributedString) -> String {
        guard paragraph.length > 0 else { return "" }

        if let level = paragraph.attribute(.headerLevel, at: 0, effectiveRange: nil) as? Int {
            return String(repeating: "#", count: level) + " " + paragraph.string
        }

        if let checked = paragraph.attribute(.checklist, at: 0, effectiveRange: nil) as? Bool {
            let contentStart = checklistContentStart(in: paragraph)
            let content = paragraph.attributedSubstring(
                from: NSRange(location: contentStart, length: paragraph.length - contentStart)
            )
            return (checked ? "- [x] " : "- [ ] ") + inlineMarkdown(from: content)
        }

        if let kind = paragraph.attribute(.listKind, at: 0, effectiveRange: nil) as? String {
            let text = paragraph.string
            if kind == "bullet", text.hasPrefix(bulletMarker) {
                let markerLength = (bulletMarker as NSString).length
                let content = paragraph.attributedSubstring(
                    from: NSRange(location: markerLength, length: paragraph.length - markerLength)
                )
                return "- " + inlineMarkdown(from: content)
            }
            if kind == "ordered", let markerLength = orderedMarkerRange(text) {
                let number = text.prefix(while: { $0.isNumber })
                let content = paragraph.attributedSubstring(
                    from: NSRange(location: markerLength, length: paragraph.length - markerLength)
                )
                return "\(number). " + inlineMarkdown(from: content)
            }
        }

        return inlineMarkdown(from: paragraph)
    }

    /// Serializes inline emphasis (`**`/`*`/`***`) and links (`[text](url)`).
    private static func inlineMarkdown(from attributed: NSAttributedString) -> String {
        var result = ""
        let ns = attributed.string as NSString
        var index = 0
        while index < attributed.length {
            var range = NSRange(location: 0, length: 0)
            let attrs = attributed.attributes(at: index, effectiveRange: &range)
            let font = attrs[.font] as? NSFont ?? bodyFont
            let traits = font.fontDescriptor.symbolicTraits
            let text = ns.substring(with: range)

            // Wiki link: the run text already reads "[[Title]]" — emit verbatim.
            if let url = attrs[.link] as? URL, url.scheme == wikiScheme {
                result += text
                index = NSMaxRange(range)
                continue
            }

            var piece = wrap(text, bold: traits.contains(.bold), italic: traits.contains(.italic))
            if let url = attrs[.link] as? URL {
                piece = "[\(piece)](\(url.absoluteString))"
            } else if let string = attrs[.link] as? String {
                piece = "[\(piece)](\(string))"
            }
            result += piece
            index = NSMaxRange(range)
        }
        return result
    }

    private static func wrap(_ text: String, bold: Bool, italic: Bool) -> String {
        let marker = bold && italic ? "***" : bold ? "**" : italic ? "*" : ""
        guard !marker.isEmpty else { return text }
        // Keep surrounding whitespace outside the emphasis markers.
        let leading = String(text.prefix(while: { $0 == " " }))
        let trailing = String(text.reversed().prefix(while: { $0 == " " }).reversed())
        let core = text.dropFirst(leading.count).dropLast(trailing.count)
        guard !core.isEmpty else { return text }
        return leading + marker + core + marker + trailing
    }

    /// All wiki-link titles referenced in a raw markdown string, in order and
    /// de-duplicated (case-insensitively, keeping first spelling).
    static func wikiTitles(in markdown: String) -> [String] {
        let ns = markdown as NSString
        var seen = Set<String>()
        var titles: [String] = []
        for match in wikiLinkRegex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            let title = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty, seen.insert(title.lowercased()).inserted else { continue }
            titles.append(title)
        }
        return titles
    }

    // MARK: - Parsing helpers

    /// Parses a checklist line: "- [ ] text" / "- [x] text" (also "* [ ]").
    static func parseChecklist(_ line: String) -> (checked: Bool, content: String)? {
        for bullet in ["- ", "* "] where line.hasPrefix(bullet) {
            let rest = line.dropFirst(bullet.count)
            guard rest.hasPrefix("[") else { return nil }
            let afterBracket = rest.dropFirst()
            guard let mark = afterBracket.first,
                  afterBracket.dropFirst().first == "]",
                  afterBracket.dropFirst(2).first == " " else { return nil }
            let content = String(afterBracket.dropFirst(3))
            switch mark {
            case " ": return (false, content)
            case "x", "X": return (true, content)
            default: return nil
            }
        }
        return nil
    }

    /// Character index where a checklist paragraph's text begins, skipping the
    /// checkbox attachment and its trailing space.
    private static func checklistContentStart(in paragraph: NSAttributedString) -> Int {
        let ns = paragraph.string as NSString
        var index = 0
        // Skip the attachment character (U+FFFC).
        if index < ns.length, ns.character(at: index) == 0xFFFC { index += 1 }
        // Skip a single following space.
        if index < ns.length, ns.character(at: index) == 32 { index += 1 }
        return index
    }

    /// Strips inline emphasis/link syntax, returning readable plain text — used
    /// by the collected-tasks view.
    static func plainText(fromInline markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return markdown
        }
        return String(parsed.characters)
    }

    private static func parseHeader(_ line: String) -> (level: Int, content: String)? {
        var level = 0
        for char in line {
            if char == "#" { level += 1 } else { break }
        }
        guard (1...3).contains(level) else { return nil }
        let afterHashes = line.dropFirst(level)
        guard afterHashes.first == " " else { return nil }
        return (level, String(afterHashes.dropFirst()))
    }

    private static func parseOrdered(_ line: String) -> (number: Int, content: String)? {
        guard let markerLength = orderedMarkerRange(line) else { return nil }
        let digits = line.prefix(while: { $0.isNumber })
        guard let number = Int(digits) else { return nil }
        let content = (line as NSString).substring(from: markerLength)
        return (number, content)
    }

    /// Returns the length (in NSString units) of a leading "<digits>. " marker,
    /// or nil if the line doesn't start with one.
    private static func orderedMarkerRange(_ line: String) -> Int? {
        let ns = line as NSString
        var i = 0
        while i < ns.length, let scalar = UnicodeScalar(ns.character(at: i)), Character(scalar).isNumber {
            i += 1
        }
        guard i > 0, i + 1 < ns.length else { return nil }
        guard ns.character(at: i) == unichar(46), ns.character(at: i + 1) == unichar(32) else { return nil } // ". "
        return i + 2
    }
}
