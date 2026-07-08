import AppKit
import Foundation

/// Converts an attributed string pasted from another app (Word, a web page, …)
/// into NoteM's own representation, keeping only the formatting we support —
/// bold, italic, headers, bulleted/numbered lists and links — and discarding
/// everything else (custom fonts, colors, backgrounds, margins, source styles).
enum PasteSanitizer {
    static func sanitized(_ input: NSAttributedString) -> NSAttributedString {
        let paragraphs = input.string.components(separatedBy: "\n")
        let output = NSMutableAttributedString()
        var location = 0
        var orderedNumber = 1

        for (index, paragraphString) in paragraphs.enumerated() {
            let length = (paragraphString as NSString).length
            let paragraph = input.attributedSubstring(from: NSRange(location: location, length: length))
            output.append(sanitizeParagraph(paragraph, orderedNumber: &orderedNumber))
            if index < paragraphs.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: MarkdownStyler.defaultTypingAttributes))
            }
            location += length + 1
        }
        return output
    }

    // MARK: - Paragraphs

    private static func sanitizeParagraph(
        _ paragraph: NSAttributedString,
        orderedNumber: inout Int
    ) -> NSAttributedString {
        guard paragraph.length > 0 else {
            orderedNumber = 1
            return NSMutableAttributedString(string: "")
        }

        // List item? Detected from the source paragraph style's text lists.
        if let style = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
           let list = style.textLists.first {
            let ordered = isOrdered(list)
            let content = sanitizeInline(paragraph)
            stripLeadingListMarker(content)
            let marker = ordered ? "\(orderedNumber). " : MarkdownStyler.bulletMarker
            if ordered { orderedNumber += 1 }
            return listItem(marker: marker, content: content, kind: ordered ? "ordered" : "bullet")
        }

        orderedNumber = 1

        // Header? Heuristic based on the paragraph's largest font size.
        if let level = headerLevel(of: paragraph) {
            return NSMutableAttributedString(
                string: paragraph.string,
                attributes: [
                    .font: MarkdownStyler.headerFont(level),
                    .headerLevel: level,
                    .foregroundColor: NSColor.labelColor
                ]
            )
        }

        // Plain body paragraph.
        return sanitizeInline(paragraph)
    }

    private static func listItem(marker: String, content: NSAttributedString, kind: String) -> NSAttributedString {
        let item = NSMutableAttributedString(string: marker, attributes: MarkdownStyler.defaultTypingAttributes)
        item.append(content)
        let full = NSRange(location: 0, length: item.length)
        item.addAttribute(.listKind, value: kind, range: full)
        item.addAttribute(.paragraphStyle, value: MarkdownStyler.listParagraphStyle, range: full)
        return item
    }

    // MARK: - Inline

    /// Rebuilds a paragraph keeping only bold/italic (from font traits) and links.
    private static func sanitizeInline(_ paragraph: NSAttributedString) -> NSMutableAttributedString {
        let output = NSMutableAttributedString()
        let ns = paragraph.string as NSString
        var index = 0
        while index < paragraph.length {
            var range = NSRange(location: 0, length: 0)
            let attrs = paragraph.attributes(at: index, effectiveRange: &range)
            let font = attrs[.font] as? NSFont ?? MarkdownStyler.bodyFont
            let traits = font.fontDescriptor.symbolicTraits

            var newAttributes: [NSAttributedString.Key: Any] = [
                .font: MarkdownStyler.font(bold: traits.contains(.bold), italic: traits.contains(.italic)),
                .foregroundColor: NSColor.labelColor
            ]
            if let url = link(from: attrs[.link]) {
                newAttributes[.link] = url
                newAttributes[.foregroundColor] = NSColor.linkColor
                newAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }

            output.append(NSAttributedString(string: ns.substring(with: range), attributes: newAttributes))
            index = NSMaxRange(range)
        }
        return output
    }

    // MARK: - Helpers

    private static func link(from value: Any?) -> URL? {
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    private static func isOrdered(_ list: NSTextList) -> Bool {
        let format = list.markerFormat.rawValue.lowercased()
        return ["decimal", "alpha", "roman", "hex", "octal"].contains { format.contains($0) }
    }

    /// Header level from the paragraph's font size — but only when the *whole*
    /// paragraph is bold, which distinguishes real headers from body text that
    /// merely contains some bold words.
    private static func headerLevel(of paragraph: NSAttributedString) -> Int? {
        var maxSize: CGFloat = 0
        var allBold = true
        var sawFont = false
        let full = NSRange(location: 0, length: paragraph.length)
        paragraph.enumerateAttribute(.font, in: full, options: []) { value, _, _ in
            guard let font = value as? NSFont else { allBold = false; return }
            sawFont = true
            maxSize = max(maxSize, font.pointSize)
            if !font.fontDescriptor.symbolicTraits.contains(.bold) { allBold = false }
        }
        guard sawFont, allBold else { return nil }
        if maxSize >= 22 { return 1 }
        if maxSize >= 16 { return 2 }
        if maxSize >= 13 { return 3 }
        return nil
    }

    /// Matches a leading list marker that sources embed as text, e.g. "\t",
    /// "•\t", "1.\t", "2) " — optional whitespace, optional bullet/number,
    /// optional trailing whitespace.
    private static let listMarkerRegex = try! NSRegularExpression(
        pattern: "^\\s*(?:[•◦▪‣·\\-\\*]|\\d+[.)]?)?\\s*"
    )

    /// Removes a leading bullet/number marker that some sources include as text.
    private static func stripLeadingListMarker(_ content: NSMutableAttributedString) {
        let range = NSRange(location: 0, length: (content.string as NSString).length)
        if let match = listMarkerRegex.firstMatch(in: content.string, range: range),
           match.range.length > 0 {
            content.deleteCharacters(in: match.range)
        }
    }
}
