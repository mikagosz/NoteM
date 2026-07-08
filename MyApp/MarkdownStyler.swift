import AppKit
import Foundation

extension NSAttributedString.Key {
    /// Header level (1/2/3) applied across a whole paragraph.
    static let headerLevel = NSAttributedString.Key("noteHeaderLevel")
    /// List kind ("bullet" / "ordered") applied across a whole paragraph.
    static let listKind = NSAttributedString.Key("noteListKind")
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

    // MARK: - Markdown -> NSAttributedString

    static func attributedString(fromMarkdown markdown: String) -> NSAttributedString {
        let lines = markdown.components(separatedBy: "\n")
        let out = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            out.append(attributedParagraph(fromMarkdownLine: line))
            if index < lines.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: defaultTypingAttributes))
            }
        }
        return out
    }

    private static func attributedParagraph(fromMarkdownLine line: String) -> NSAttributedString {
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

    /// Parses inline emphasis (bold/italic) from a single line of markdown.
    private static func attributed(inline markdown: String) -> NSAttributedString {
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
            result.append(NSAttributedString(
                string: text,
                attributes: [.font: font(bold: bold, italic: italic), .foregroundColor: NSColor.labelColor]
            ))
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

    /// Serializes inline emphasis by wrapping runs in `**` / `*` / `***`.
    private static func inlineMarkdown(from attributed: NSAttributedString) -> String {
        var result = ""
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            let font = value as? NSFont ?? bodyFont
            let traits = font.fontDescriptor.symbolicTraits
            let text = (attributed.string as NSString).substring(with: range)
            result += wrap(text, bold: traits.contains(.bold), italic: traits.contains(.italic))
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

    // MARK: - Parsing helpers

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
