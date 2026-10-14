import Foundation

/// Read-only access to the note store: where it lives and what is in it.
///
/// Split out of `NoteStore` and `StorageLocation` (2026-10-14) so that code which
/// must never write — a read-only reader outside the app — can read the
/// store with exactly the functions the app uses, without pulling in the rest of
/// the app. Only `Foundation` here, on purpose: `NoteStore` also creates folders,
/// rewrites the manifest and keeps history, and `StorageLocation` lives next to
/// SwiftUI and the sync manager.
///
/// `NoteStore` and `StorageLocation` forward to this file, so there is one
/// implementation, not two that drift. Nothing here creates, moves or writes a file.
nonisolated enum NoteStoreReading {

    /// Names of the files stored inside every note folder.
    enum FileName {
        static let content = "note.md"
        /// Full-fidelity archive of the note's attributed string (colours, fonts,
        /// pasted formatting, inline images). The source of truth for display;
        /// `note.md` is kept alongside for text features (tasks, links, titles).
        static let rich = "note.rich"
        static let meta = "meta.json"
    }

    /// Reserved top-level directory for trashed notes.
    static let trashDir = ".trash"

    // MARK: - Where the store lives

    /// `~/Documents/NoteM/`, unless redirected.
    static func localRoot(redirectedPath: String?, documents: URL) -> URL {
        if let redirectedPath { return URL(fileURLWithPath: redirectedPath, isDirectory: true) }
        return documents.appendingPathComponent("NoteM", isDirectory: true)
    }

    /// iCloud Drive's user-visible folder, or `nil` if iCloud Drive isn't set up.
    ///
    /// A redirect applies here too — otherwise turning sync on inside a test copy
    /// would reach straight back into the real iCloud Drive.
    static func iCloudRoot(redirectedPath: String?, home: URL, fileManager: FileManager = FileManager()) -> URL? {
        if let redirectedPath {
            return URL(fileURLWithPath: redirectedPath, isDirectory: true)
                .deletingLastPathComponent().appendingPathComponent("NoteM-iCloud", isDirectory: true)
        }
        let base = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard fileManager.fileExists(atPath: base.path) else { return nil }
        return base.appendingPathComponent("NoteM", isDirectory: true)
    }

    /// The root for the given sync preference; local when iCloud isn't available.
    static func root(syncEnabled: Bool, local: URL, iCloud: URL?) -> URL {
        if syncEnabled, let iCloud { return iCloud }
        return local
    }

    // MARK: - What is in it

    /// Every active note under `root`. The trash is skipped — see `readTrashedNotes`.
    static func readAllNotes(root: URL) -> [Note] {
        readAllNotesReportingUnreadable(root: root).notes
    }

    /// `readAllNotes` plus the folders whose `meta.json` could not be decoded.
    ///
    /// 🔴 Such a note used to vanish from the list, the trash and search without
    /// a word — `note.md` intact on disk, and no reason for the user to go looking.
    /// The paths go to a banner (`NotesModel.apply`). SBW audit 2026-09-23, E1-S-P2-01.
    ///
    /// Each call makes its own `FileManager` and `JSONDecoder`: both are cheap, and
    /// the reads run off the main thread.
    static func readAllNotesReportingUnreadable(root: URL) -> (notes: [Note], unreadable: [String]) {
        let fileManager = FileManager()
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        let decoder = makeDecoder()
        var notes: [Note] = []
        var unreadable: [String] = []
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == FileName.meta {
            let folderURL = fileURL.deletingLastPathComponent()
            // Enumerating the root cannot produce a folder outside it, so `nil`
            // here means a symlink pointing away — skip it rather than guess.
            guard let folderPath = relativePath(of: folderURL, under: root) else { continue }
            // Skip the trash: those notes are surfaced via readTrashedNotes().
            if folderPath == trashDir || folderPath.hasPrefix(trashDir + "/") { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let meta = try? decoder.decode(NoteMeta.self, from: data) else {
                unreadable.append(folderPath)
                continue
            }
            notes.append(Note(meta: meta, folderPath: folderPath))
        }
        return (notes, unreadable)
    }

    static func readTrashedNotes(root: URL) -> [Note] {
        let fileManager = FileManager()
        let trashURL = root.appendingPathComponent(trashDir, isDirectory: true)
        guard let enumerator = fileManager.enumerator(at: trashURL, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = makeDecoder()
        var notes: [Note] = []
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == FileName.meta {
            guard let data = try? Data(contentsOf: fileURL),
                  let meta = try? decoder.decode(NoteMeta.self, from: data) else {
                continue
            }
            let folderURL = fileURL.deletingLastPathComponent()
            guard let folderPath = relativePath(of: folderURL, under: root) else { continue }
            notes.append(Note(meta: meta, folderPath: folderPath))
        }
        return notes
    }

    /// Text of a note (`note.md`), or `nil` when the file is missing or unreadable.
    static func readContent(of note: Note, root: URL) -> String? {
        let url = root.appendingPathComponent(note.folderPath, isDirectory: true)
            .appendingPathComponent(FileName.content)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Decoder settings shared by the reads and by the store — `meta.json`
    /// carries ISO-8601 dates and a decoder without this reads none of them.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Path of `folderURL` relative to `root`, or `nil` when it is not under it.
    static func relativePath(of folderURL: URL, under root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let folderComponents = folderURL.standardizedFileURL.pathComponents
        guard folderComponents.count > rootComponents.count,
              Array(folderComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return folderComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}
