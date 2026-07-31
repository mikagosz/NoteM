import Foundation

/// Regex replacement where the substitute is built from the match groups.
///
/// Lives on its own because both exporters need it: `HTMLExport` rewrites
/// `attachments/…` targets into inline data URIs, `ObsidianExport` rewrites the
/// same targets into vault-relative embeds. They used to carry a byte-identical
/// private copy each.
enum RegexReplace {

    /// Replaces every match of `pattern` in `text` with what `builder` returns.
    ///
    /// `builder` receives the match groups, index 0 being the whole match — so
    /// returning `groups[0]` leaves that occurrence as it was. An invalid
    /// pattern leaves `text` untouched.
    static func apply(_ text: String, pattern: String,
                      with builder: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var location = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: location, length: match.range.location - location))
            var groups: [String] = []
            for i in 0..<match.numberOfRanges {
                let r = match.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += builder(groups)
            location = NSMaxRange(match.range)
        }
        result += ns.substring(from: location)
        return result
    }
}
