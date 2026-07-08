import Foundation

/// File-backed store for notes.
///
/// Root directory is `~/Documents/NoteM/` (hard-coded for now — no location
/// settings yet). Each note is a folder containing `note.md` and `meta.json`.
final class NoteStore {
    /// Names of the files stored inside every note folder.
    private enum FileName {
        static let content = "note.md"
        static let meta = "meta.json"
    }

    /// Absolute URL of the store root (`~/Documents/NoteM/`).
    let rootURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Errors thrown by the store.
    enum StoreError: Error {
        case noteFolderMissing(String)
    }

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        if let rootURL {
            self.rootURL = rootURL
        } else {
            let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.rootURL = documents.appendingPathComponent("NoteM", isDirectory: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        ensureRootExists()
    }

    // MARK: - Public API

    /// Creates a new note: makes its folder and writes an empty `note.md`
    /// plus a `meta.json`.
    @discardableResult
    func createNote(title: String) -> Note {
        let now = Date()
        // New notes start unfiled in Inbox; the categorization engine may move
        // them once they have content (see NotesModel.save).
        let folderPath = CategoryEngine.inbox + "/" + Self.makeFolderPath(for: now)
        let note = Note(title: title, created: now, modified: now, folderPath: folderPath)

        let folderURL = url(forFolderPath: folderPath)
        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        writeContent("", to: folderURL)
        writeMeta(note.meta, to: folderURL)

        return note
    }

    /// Scans the store root and loads every note whose folder contains a
    /// readable `meta.json`.
    func loadAllNotes() -> [Note] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        var notes: [Note] = []
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == FileName.meta {
            guard let data = try? Data(contentsOf: fileURL),
                  let meta = try? decoder.decode(NoteMeta.self, from: data) else {
                continue
            }
            let folderURL = fileURL.deletingLastPathComponent()
            let folderPath = relativePath(of: folderURL)
            notes.append(Note(meta: meta, folderPath: folderPath))
        }

        return notes
    }

    /// Overwrites `note.md` with `content` and rewrites `meta.json`, bumping
    /// `modified`. Returns the updated note.
    @discardableResult
    func saveNote(_ note: Note, content: String) -> Note {
        var updated = note
        updated.modified = Date()

        let folderURL = url(forFolderPath: updated.folderPath)
        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        writeContent(content, to: folderURL)
        writeMeta(updated.meta, to: folderURL)

        return updated
    }

    /// Moves a note's folder to `newFolderPath` (relative to the store root),
    /// creating intermediate directories and avoiding name collisions. Returns
    /// the note with its updated `folderPath` (unchanged if the move fails).
    @discardableResult
    func moveNote(_ note: Note, toFolderPath newFolderPath: String) -> Note {
        let source = url(forFolderPath: note.folderPath)
        guard fileManager.fileExists(atPath: source.path) else { return note }

        var finalPath = newFolderPath
        var destination = url(forFolderPath: finalPath)
        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Disambiguate if something already sits at the destination.
        if fileManager.fileExists(atPath: destination.path) {
            finalPath = newFolderPath + "-" + note.id.uuidString.prefix(8)
            destination = url(forFolderPath: finalPath)
        }

        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            return note
        }

        var moved = note
        moved.folderPath = finalPath
        return moved
    }

    /// Rewrites only `meta.json` for a note (e.g. after a tags change), leaving
    /// `note.md` and `modified` untouched.
    @discardableResult
    func updateMeta(_ note: Note) -> Note {
        let folderURL = url(forFolderPath: note.folderPath)
        writeMeta(note.meta, to: folderURL)
        return note
    }

    /// Deletes a note's entire folder from disk.
    func deleteNote(_ note: Note) {
        let folderURL = url(forFolderPath: note.folderPath)
        try? fileManager.removeItem(at: folderURL)
    }

    /// Reads the `note.md` content for a given note, or an empty string if
    /// none is present.
    func loadContent(for note: Note) -> String {
        let contentURL = url(forFolderPath: note.folderPath)
            .appendingPathComponent(FileName.content)
        return (try? String(contentsOf: contentURL, encoding: .utf8)) ?? ""
    }

    // MARK: - Helpers

    private func ensureRootExists() {
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func url(forFolderPath folderPath: String) -> URL {
        rootURL.appendingPathComponent(folderPath, isDirectory: true)
    }

    /// Path of `folderURL` relative to the store root (matches `Note.folderPath`).
    private func relativePath(of folderURL: URL) -> String {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let folderComponents = folderURL.standardizedFileURL.pathComponents
        guard folderComponents.count > rootComponents.count,
              Array(folderComponents.prefix(rootComponents.count)) == rootComponents else {
            return folderURL.lastPathComponent
        }
        return folderComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func writeContent(_ content: String, to folderURL: URL) {
        let url = folderURL.appendingPathComponent(FileName.content)
        try? content.data(using: .utf8)?.write(to: url)
    }

    private func writeMeta(_ meta: NoteMeta, to folderURL: URL) {
        let url = folderURL.appendingPathComponent(FileName.meta)
        if let data = try? encoder.encode(meta) {
            try? data.write(to: url)
        }
    }

    /// Timestamp-based folder path, e.g. "2026-07-08_10-00-00".
    /// (Auto-categorization into named parent folders is a later phase.)
    private static func makeFolderPath(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}
