import AppKit
import Foundation
import UniformTypeIdentifiers

/// Eksport do HTML (Priorytet 6): konwersja markdownu notatki do jednego,
/// samodzielnego pliku `.html` — style wpisane w plik, obrazki z `attachments/`
/// osadzone jako base64, zero zależności zewnętrznych.
enum HTMLExport {

    // MARK: - Save panel (single note, Zadanie 6.1)

    /// Asks where to save and writes the note as a standalone HTML file.
    @MainActor
    static func exportWithPanel(title: String, markdown: String, attachmentsFolder: URL) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.html]
        savePanel.nameFieldStringValue = (title.isEmpty ? Loc.t("Notatka", "Note") : title) + ".html"
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            let html = document(
                title: title,
                markdown: markdown,
                attachmentData: { name in
                    try? Data(contentsOf: attachmentsFolder.appendingPathComponent(name))
                },
                wikiHref: { _ in nil }
            )
            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // The app's rule is that a write which didn't reach the disk gets
                // said out loud — an export that silently produced nothing is the
                // worst kind, because the user walks away believing it worked.
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = Loc.t("Nie udało się zapisać pliku HTML",
                                          "Could not write the HTML file")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    // MARK: - Document

    /// Builds a complete standalone HTML document for one note.
    /// - Parameters:
    ///   - attachmentData: returns the raw bytes of `attachments/<name>`
    ///     (embedded as base64 data URIs), or `nil` when unavailable.
    ///   - wikiHref: maps a `[[Title]]` link to an href; `nil` renders the
    ///     title as plain styled text (used for single-note export).
    static func document(title: String,
                         markdown: String,
                         attachmentData: (String) -> Data?,
                         wikiHref: (String) -> String?) -> String {
        let body = bodyHTML(markdown: markdown, attachmentData: attachmentData, wikiHref: wikiHref)
        return """
        <!DOCTYPE html>
        <html lang="\(Loc.t("pl", "en"))">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
            line-height: 1.55;
            max-width: 720px;
            margin: 0 auto;
            padding: 40px 24px 64px;
            color: #1d1d1f;
            background: #ffffff;
        }
        @media (prefers-color-scheme: dark) {
            body { color: #e8e8ea; background: #1c1c1e; }
            blockquote { border-color: #48484a; color: #b0b0b5; }
            code { background: #2c2c2e; }
            .wiki { background: #2c2c2e; }
            a { color: #6fb1ff; }
        }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.2em 0 0.4em; }
        h1:first-child { margin-top: 0; }
        p { margin: 0.45em 0; }
        ul, ol { margin: 0.45em 0; padding-left: 1.6em; }
        ul.checklist { list-style: none; padding-left: 0.4em; }
        ul.checklist li { margin: 0.2em 0; }
        ul.checklist input { margin-right: 0.5em; }
        li.done { color: #8e8e93; text-decoration: line-through; }
        blockquote {
            margin: 0.6em 0;
            padding: 0.1em 0 0.1em 1em;
            border-left: 3px solid #d1d1d6;
            color: #6e6e73;
        }
        code {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 0.9em;
            background: #f2f2f7;
            border-radius: 4px;
            padding: 0.1em 0.35em;
        }
        img { max-width: 100%; height: auto; border-radius: 8px; }
        a { color: #0a66d0; }
        .wiki {
            background: #f2f2f7;
            border-radius: 4px;
            padding: 0.05em 0.3em;
        }
        .attachment { color: #6e6e73; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    // MARK: - Markdown -> HTML body

    /// Which multi-line block is currently open while walking the lines.
    private enum Block { case none, bullets, ordered, checklist, quote }

    private static func bodyHTML(markdown: String,
                                 attachmentData: (String) -> Data?,
                                 wikiHref: (String) -> String?) -> String {
        var out: [String] = []
        var block = Block.none

        func close() {
            switch block {
            case .none: break
            case .bullets: out.append("</ul>")
            case .ordered: out.append("</ol>")
            case .checklist: out.append("</ul>")
            case .quote: out.append("</blockquote>")
            }
            block = .none
        }
        func open(_ wanted: Block, tag: String) {
            guard block != wanted else { return }
            close()
            out.append(tag)
            block = wanted
        }

        func inlined(_ s: String) -> String {
            inline(s, attachmentData: attachmentData, wikiHref: wikiHref)
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                close()
                continue
            }
            // Headings: "# ..." to "###### ..."
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if (1...6).contains(level), !text.isEmpty {
                    close()
                    out.append("<h\(level)>\(inlined(text))</h\(level)>")
                    continue
                }
            }
            // Checklist: "- [ ] ..." / "- [x] ..."
            if let item = MarkdownStyler.parseChecklist(line) {
                open(.checklist, tag: "<ul class=\"checklist\">")
                let checked = item.checked ? " checked" : ""
                let cls = item.checked ? " class=\"done\"" : ""
                out.append("<li\(cls)><input type=\"checkbox\"\(checked) disabled>\(inlined(item.content))</li>")
                continue
            }
            // Bulleted list: "- ..." / "* ..."
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                open(.bullets, tag: "<ul>")
                out.append("<li>\(inlined(String(line.dropFirst(2))))</li>")
                continue
            }
            // Ordered list: "1. ..."
            if let dot = line.firstIndex(of: "."),
               !line.prefix(upTo: dot).isEmpty,
               line.prefix(upTo: dot).allSatisfy(\.isNumber),
               line[line.index(after: dot)...].hasPrefix(" ") {
                open(.ordered, tag: "<ol>")
                let text = line[line.index(dot, offsetBy: 2)...].trimmingCharacters(in: .whitespaces)
                out.append("<li>\(inlined(text))</li>")
                continue
            }
            // Blockquote: "> ..."
            if line.hasPrefix("> ") || line == ">" {
                open(.quote, tag: "<blockquote>")
                out.append("<p>\(inlined(String(line.dropFirst(2))))</p>")
                continue
            }
            close()
            out.append("<p>\(inlined(line))</p>")
        }
        close()
        return out.joined(separator: "\n")
    }

    // MARK: - Inline markdown

    /// Escapes HTML, then rewrites inline markdown: images, links, wiki links,
    /// emphasis and inline code.
    private static func inline(_ text: String,
                               attachmentData: (String) -> Data?,
                               wikiHref: (String) -> String?) -> String {
        var s = escape(text)

        // Images: ![alt](src) — attachments become embedded data URIs.
        s = RegexReplace.apply(s, pattern: "!\\[([^\\]]*)\\]\\(([^)]+)\\)") { groups in
            let alt = groups[1]
            let src = groups[2]
            if let name = attachmentName(src) {
                guard let data = attachmentData(name), let mime = imageMime(name) else {
                    return "<span class=\"attachment\">🖼 \(alt.isEmpty ? name : alt)</span>"
                }
                return "<img src=\"data:\(mime);base64,\(data.base64EncodedString())\" alt=\"\(alt)\">"
            }
            guard let safeSrc = safeImageSource(src) else {
                return "<span class=\"attachment\">🖼 \(alt.isEmpty ? src : alt)</span>"
            }
            return "<img src=\"\(safeSrc)\" alt=\"\(alt)\">"
        }
        // Links: [label](url) — attachment files render as a plain label,
        // web links stay clickable.
        s = RegexReplace.apply(s, pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)") { groups in
            let label = groups[1]
            let href = groups[2]
            if attachmentName(href) != nil {
                return "<span class=\"attachment\">📎 \(label)</span>"
            }
            guard let safeHref = safeLinkTarget(href) else { return label }
            return "<a href=\"\(safeHref)\">\(label)</a>"
        }
        // Wiki links: [[Title]]
        s = RegexReplace.apply(s, pattern: "\\[\\[([^\\]]+)\\]\\]") { groups in
            let title = groups[1].trimmingCharacters(in: .whitespaces)
            if let href = wikiHref(title) {
                return "<a href=\"\(href)\">\(title)</a>"
            }
            return "<span class=\"wiki\">\(title)</span>"
        }
        // Emphasis and inline code.
        s = RegexReplace.apply(s, pattern: "\\*\\*\\*([^*]+)\\*\\*\\*") { "<strong><em>\($0[1])</em></strong>" }
        s = RegexReplace.apply(s, pattern: "\\*\\*([^*]+)\\*\\*") { "<strong>\($0[1])</strong>" }
        s = RegexReplace.apply(s, pattern: "\\*([^*]+)\\*") { "<em>\($0[1])</em>" }
        s = RegexReplace.apply(s, pattern: "`([^`]+)`") { "<code>\($0[1])</code>" }
        return s
    }

    /// Filename when the target points into the note's `attachments/` folder.
    private static func attachmentName(_ src: String) -> String? {
        guard src.hasPrefix("attachments/") else { return nil }
        let name = String(src.dropFirst("attachments/".count))
            .removingPercentEncoding ?? String(src.dropFirst("attachments/".count))
        return name.isEmpty ? nil : name
    }

    private static func imageMime(_ filename: String) -> String? {
        switch (filename as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "tiff", "tif": return "image/tiff"
        case "svg": return "image/svg+xml"
        default: return nil
        }
    }

    /// Escapes everything that could break out of text *or* out of an attribute
    /// value. The quotes matter: link targets and alt texts are interpolated
    /// straight into `href="…"` / `alt="…"`, so a note containing
    /// `[x](a" onmouseover="alert(1))` would otherwise become a live handler in
    /// the exported page — which opens as `file://`, with no origin to stop it.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - Link targets

    /// Schemes allowed for a clickable link. Anything else — `javascript:` above
    /// all — is rendered as plain text instead.
    private static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    /// The lowercased scheme of a target, or `nil` when it's a relative path
    /// (relative targets are harmless and stay as they are).
    private static func scheme(of target: String) -> String? {
        guard let colon = target.firstIndex(of: ":") else { return nil }
        let candidate = target[target.startIndex..<colon].lowercased()
        // A real scheme starts with a letter and holds only letters, digits and
        // + - . — so "./notes:2026" reads as a relative path, not a scheme.
        guard let first = candidate.first, first.isLetter,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return nil }
        return candidate
    }

    /// The target for `href="…"`, or `nil` when the link must not be clickable.
    private static func safeLinkTarget(_ href: String) -> String? {
        let target = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = scheme(of: target) else { return target }
        return allowedLinkSchemes.contains(scheme) ? target : nil
    }

    /// The target for `img src="…"`, or `nil` when the image must not be loaded.
    /// `data:` is allowed here — that's how the note's own attachments are
    /// embedded — but only for image payloads.
    private static func safeImageSource(_ src: String) -> String? {
        let target = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = scheme(of: target) else { return target }
        if scheme == "data" { return target.lowercased().hasPrefix("data:image/") ? target : nil }
        return ["http", "https"].contains(scheme) ? target : nil
    }

}
