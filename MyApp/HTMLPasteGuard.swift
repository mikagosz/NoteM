import AppKit
import Foundation

/// Cuts remote references out of pasted HTML **before** the system importer sees it.
///
/// `NSAttributedString(data:options:.html)` fetches whatever the document points at.
/// Measured on 2026-08-11 against a local server: pasting a fragment containing
/// `<img src="http://…">` produced a `GET` for the image, and a `<link rel=stylesheet
/// href="http://…">` produced a second one for the stylesheet. Nobody asked for either.
///
/// For a program whose README says it makes no network connections, that is a broken
/// promise — and a quiet one. The request carries the machine's address and the moment
/// of the paste to whoever runs that server, and the user's only action was ⌘V.
///
/// There is no supported switch on the importer for this (the WebKit-era options that
/// once did it are long gone), so the references are removed from the source instead.
/// The rule is deliberately blunt: when in doubt, strip. Over-stripping costs a picture,
/// under-stripping costs a request that cannot be taken back.
///
/// What survives: text, structure, inline styling, `<a href>` links (a link is not a
/// fetch) and `data:` images, whose bytes are already in the clipboard.
///
/// What this costs: an HTML-only paste that referenced its pictures by URL arrives
/// without them. In practice that is the uncommon path — `paste(_:)` tries RTFD and RTF
/// first, and that is where a browser's images actually come from.
enum HTMLPasteGuard {

    /// The only way HTML gets into the editor. Both paste paths (⌘V and
    /// ⌥⇧⌘V) go through here, so the guard cannot be forgotten at a call site —
    /// there is no longer a call site to forget it at.
    ///
    /// The wiring is proven by measurement rather than by a unit test: a test can
    /// check what the stripping returns, but only a live server can show that no
    /// request left the machine. Numbers in the audit note.
    @MainActor
    static func attributedString(fromPastedHTML data: Data) -> NSAttributedString? {
        try? NSAttributedString(
            data: withoutRemoteResources(data),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        )
    }

    /// HTML with every remote reference removed. Returns the input unchanged if it
    /// isn't decodable as UTF-8 — the importer can still have it, and a paste that
    /// silently turns into nothing would be worse than the leak this guards against.
    static func withoutRemoteResources(_ data: Data) -> Data {
        guard let html = String(data: data, encoding: .utf8) else { return data }
        return Data(withoutRemoteResources(html).utf8)
    }

    ///
    /// > [!danger] 🔴 Match on what the IMPORTER will see, not on the raw text
    /// > Until 1.1.0 the rules looked for a literal `scheme://` in the source. The
    /// > importer decodes first — `&#104;ttp://`, `http:&#47;&#47;`, `&quot;` inside
    /// > a `style`, the CSS escape `u\72l(` — and only then reads the address, so all
    /// > of those reached the network untouched. The same went for `<svg><image href>`,
    /// > where `href` IS a fetch. SBW audit 2026-09-23, E2-B-P1-01 (a regression of
    /// > P2-07 from 2026-08-11).
    /// >
    /// > The rules are now an allow-list: a fetching attribute keeps its value only
    /// > when it is a `data:` URL or a plain relative path with nothing the importer
    /// > could decode into something else (`:`, `&`, `\`, a leading `//`). A `style`
    /// > with an entity, an escape or a non-empty `url(` goes whole. SVG goes whole.
    static func withoutRemoteResources(_ html: String) -> String {
        var result = html
        for pattern in strippedElements {
            result = RegexReplace.replacing(pattern, in: result, with: "", options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
        result = RegexReplace.apply(result, pattern: fetchingAttribute) { groups in
            isHarmlessReference(unquoted(groups[2])) ? groups[0] : ""
        }
        result = RegexReplace.apply(result, pattern: styleAttribute) { groups in
            isHarmlessStyle(unquoted(groups[1])) ? groups[0] : ""
        }
        // A `<style>` block is raw text — entities stay literal there — but CSS
        // escapes do apply, so a block with a backslash goes whole.
        result = RegexReplace.apply(result, pattern: "(?is)<style\\b[^>]*>(.*?)</style\\s*>") { groups in
            groups[1].contains("\\") ? "" : groups[0]
        }
        // CSS, both in `<style>` blocks and in a `style="…"` attribute. The url() is
        // emptied rather than the whole declaration removed: `url()` fetches nothing,
        // and the surrounding rule may still carry a colour worth keeping.
        result = RegexReplace.replacing(
            "url\\(\\s*['\"]?\\s*(?:https?:)?//[^)]*\\)",
            in: result, with: "url()", options: [.caseInsensitive]
        )
        result = RegexReplace.replacing(
            "@import\\s+[^;]*;", in: result, with: "", options: [.caseInsensitive]
        )
        return result
    }

    /// Elements that exist only to pull something in. None of them contributes text to
    /// an attributed string, so removing them whole costs nothing.
    ///
    /// `<base>` is here for a reason that is easy to miss: a remote base URL turns every
    /// *relative* path in the document into a remote one, so leaving it in would undo
    /// the rest of this.
    private static let strippedElements = [
        // SVG pulls in pictures through `<image href>` / `xlink:href` — an `href`
        // that is a fetch, unlike on `<a>`. It contributes no text worth keeping.
        "<svg\\b[^>]*>.*?</svg\\s*>",
        "<svg\\b[^>]*/?>",
        "<image\\b[^>]*/?>",
        "<meta\\b[^>]*>",
        "<script\\b[^>]*>.*?</script\\s*>",
        "<script\\b[^>]*/?>",
        "<style\\b[^>]*>(?=[^<]*@import)[^<]*</style\\s*>",
        "<link\\b[^>]*>",
        "<base\\b[^>]*>",
        "<iframe\\b[^>]*>.*?</iframe\\s*>",
        "<iframe\\b[^>]*/?>",
        "<object\\b[^>]*>.*?</object\\s*>",
        "<embed\\b[^>]*/?>",
        "<video\\b[^>]*>.*?</video\\s*>",
        "<audio\\b[^>]*>.*?</audio\\s*>",
        "<source\\b[^>]*/?>",
        "<track\\b[^>]*/?>",
    ]

    /// Attributes that make the importer go and get something. `href` is missing from
    /// this list on purpose: on an `<a>` it is a link the user may want to keep, and it
    /// is not fetched. The elements whose `href` *is* fetched (`link`, `base`, SVG's
    /// `image`) are removed whole above.
    private static let fetchingAttribute =
        "(?i)\\s(src|srcset|poster|background|lowsrc|dynsrc|profile|longdesc|manifest|cite|usemap|codebase|data)"
            + "\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)"

    private static let styleAttribute = "(?i)\\sstyle\\s*=\\s*(\"[^\"]*\"|'[^']*')"

    private static func unquoted(_ value: String) -> String {
        var v = value
        if let first = v.first, first == "\"" || first == "'", v.count >= 2 { v = String(v.dropFirst().dropLast()) }
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `data:` (bytes already in the clipboard), or a plain relative path — with no
    /// base it resolves to nothing. Anything the importer could decode into a scheme
    /// or a host is stripped: protocol-relative `//host` resolves to https.
    static func isHarmlessReference(_ value: String) -> Bool {
        if value.lowercased().hasPrefix("data:") { return true }
        if value.hasPrefix("//") { return false }
        return !value.contains(":") && !value.contains("&") && !value.contains("\\")
    }

    /// Plain inline styling passes; anything that could be decoded into a fetch
    /// does not. `url()` left empty by the rule above counts as plain.
    static func isHarmlessStyle(_ value: String) -> Bool {
        let lower = value.lowercased()
        if value.contains("&") || value.contains("\\") || lower.contains("image-set") { return false }
        return !lower.replacingOccurrences(of: "url()", with: "").contains("url(")
    }
}
