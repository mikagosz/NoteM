import Foundation

/// How a file in a note's `attachments/` folder is written into `note.md` and read back.
///
/// One implementation for every reader — the HTML export, the display rebuilt from
/// Markdown, the Obsidian mirror and attachment pruning. Each used to do it alone, and they
/// disagreed (dynamic audit 2026-11-12):
/// - D-B-P0-01: the HTML export and the display took everything after `attachments/` as a
///   path, `../` included, so a line of pasted text could pull a picture from anywhere on
///   the disk into an exported HTML file. Only the Obsidian mirror refused it.
/// - D-S-P1-01: a file named "Faktura (1).pdf" was written into the link as is, and the
///   pruning pattern stopped at the first `)` — the file was taken for unused and deleted on
///   the next save.
nonisolated enum AttachmentPath {

    static let prefix = "attachments/"

    /// Characters that would break the Markdown link around the name, plus `%` itself so
    /// that decoding gives back exactly the name that was encoded.
    private static let escapes: [(String, String)] = [
        ("%", "%25"), ("(", "%28"), (")", "%29"), ("[", "%5B"), ("]", "%5D"), ("\n", "%0A"), ("\r", "%0D")
    ]

    /// `attachments/<name>` with only the link-breaking characters escaped — the rest stays
    /// readable in `note.md` and in Obsidian.
    static func markdownTarget(for filename: String) -> String {
        var escaped = filename
        for (character, escape) in escapes {
            escaped = escaped.replacingOccurrences(of: character, with: escape)
        }
        return prefix + escaped
    }

    /// Label for a `[label](…)` link: square brackets would end the label early.
    static func linkLabel(for filename: String) -> String {
        filename.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    /// The single file an `attachments/…` target names, or `nil` when it is not an
    /// attachment target or could reach outside the folder.
    static func filename(fromTarget target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { return nil }
        return filename(fromEncoded: String(trimmed.dropFirst(prefix.count)))
    }

    /// The name after `attachments/`, decoded, or `nil` when it is not one plain file name.
    /// Checked **after** decoding: `%2F` and `%2E%2E` are a `/` and a `..` too.
    static func filename(fromEncoded raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let name = trimmed.removingPercentEncoding ?? trimmed
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0") else { return nil }
        return name
    }
}
