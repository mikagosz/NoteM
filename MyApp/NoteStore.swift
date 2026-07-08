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

    /// Per-category metadata file (currently just the cover colour).
    private static let categoryMetaFile = ".category.json"

    /// Reserved top-level directories under the store root.
    static let trashDir = ".trash"
    static let historyDir = ".history"
    /// How many `note.md` snapshots to keep per note.
    private static let historyLimit = 20
    private static let manifestFile = "manifest.json"

    private struct Manifest: Codable { var lastModified: Date }

    /// Absolute URL of the store root (`~/Documents/NoteM/`).
    let rootURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Called when a manifest write fails (e.g. iCloud Drive unavailable).
    var onWriteError: ((String) -> Void)?

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
        updateManifest()

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
            let folderURL = fileURL.deletingLastPathComponent()
            let folderPath = relativePath(of: folderURL)
            // Skip the trash: those notes are surfaced via loadTrashedNotes().
            if folderPath == Self.trashDir || folderPath.hasPrefix(Self.trashDir + "/") { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let meta = try? decoder.decode(NoteMeta.self, from: data) else {
                continue
            }
            notes.append(Note(meta: meta, folderPath: folderPath))
        }

        return notes
    }

    /// Loads notes currently sitting in `.trash/`.
    func loadTrashedNotes() -> [Note] {
        let trashURL = url(forFolderPath: Self.trashDir)
        guard let enumerator = fileManager.enumerator(at: trashURL, includingPropertiesForKeys: nil) else {
            return []
        }
        var notes: [Note] = []
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == FileName.meta {
            guard let data = try? Data(contentsOf: fileURL),
                  let meta = try? decoder.decode(NoteMeta.self, from: data) else {
                continue
            }
            let folderURL = fileURL.deletingLastPathComponent()
            notes.append(Note(meta: meta, folderPath: relativePath(of: folderURL)))
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

        // Snapshot the previous content before overwriting, as a safety net.
        snapshotContent(for: updated, from: folderURL)
        writeContent(content, to: folderURL)
        writeMeta(updated.meta, to: folderURL)
        updateManifest()

        return updated
    }

    // MARK: - Trash

    /// Moves a note's folder into `.trash/<id>`, recording where it came from and
    /// when it was deleted. Returns the note with its trash `folderPath` and
    /// metadata (or unchanged if the move fails).
    @discardableResult
    func trashNote(_ note: Note) -> Note {
        let source = url(forFolderPath: note.folderPath)
        guard fileManager.fileExists(atPath: source.path) else { return note }

        let trashPath = Self.trashDir + "/" + note.id.uuidString
        let destination = url(forFolderPath: trashPath)
        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            return note
        }

        var trashed = note
        trashed.originalFolderPath = note.folderPath
        trashed.deletedAt = Date()
        trashed.folderPath = trashPath
        writeMeta(trashed.meta, to: destination)
        updateManifest()
        return trashed
    }

    /// Moves a trashed note back to its original location (disambiguating if
    /// something now sits there) and clears its trash metadata.
    @discardableResult
    func restoreNote(_ note: Note) -> Note {
        let source = url(forFolderPath: note.folderPath)
        guard fileManager.fileExists(atPath: source.path) else { return note }

        let target = note.originalFolderPath ?? (CategoryEngine.inbox + "/" + note.id.uuidString)
        var finalPath = target
        var destination = url(forFolderPath: finalPath)
        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            finalPath = target + "-" + note.id.uuidString.prefix(8)
            destination = url(forFolderPath: finalPath)
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            return note
        }

        var restored = note
        restored.folderPath = finalPath
        restored.originalFolderPath = nil
        restored.deletedAt = nil
        writeMeta(restored.meta, to: destination)
        updateManifest()
        return restored
    }

    /// Permanently deletes trashed notes whose `deletedAt` is older than `days`.
    func emptyTrash(olderThanDays days: Int) {
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for note in loadTrashedNotes() {
            if let deletedAt = note.deletedAt, deletedAt < cutoff {
                deleteNote(note)
            }
        }
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
        updateManifest()
        return note
    }

    /// Deletes a note's entire folder from disk.
    func deleteNote(_ note: Note) {
        let folderURL = url(forFolderPath: note.folderPath)
        try? fileManager.removeItem(at: folderURL)
        updateManifest()
    }

    /// Reads the `note.md` content for a given note, or an empty string if
    /// none is present.
    func loadContent(for note: Note) -> String {
        let contentURL = url(forFolderPath: note.folderPath)
            .appendingPathComponent(FileName.content)
        return (try? String(contentsOf: contentURL, encoding: .utf8)) ?? ""
    }

    // MARK: - Manifest (for cross-Mac change detection)

    /// Writes `manifest.json` at the store root with the current timestamp.
    /// Called after every mutation so other Macs can detect changes without
    /// scanning the full folder tree.
    func updateManifest() {
        let url = rootURL.appendingPathComponent(Self.manifestFile)
        do {
            let data = try encoder.encode(Manifest(lastModified: Date()))
            try data.write(to: url, options: .atomic)
            NotificationCenter.default.post(name: .noteMStoreDidWriteManifest, object: nil)
        } catch {
            onWriteError?("iCloud Drive niedostępny — działam lokalnie")
        }
    }

    /// Returns `lastModified` from `manifest.json`, or `nil` if absent / unreadable.
    func readManifestDate() -> Date? {
        let url = rootURL.appendingPathComponent(Self.manifestFile)
        guard let data = try? Data(contentsOf: url),
              let manifest = try? decoder.decode(Manifest.self, from: data) else { return nil }
        return manifest.lastModified
    }

    // MARK: - Category cover colour

    /// Metadata stored per category folder.
    private struct CategoryMeta: Codable { var coverColorID: String? }

    /// Reads the cover-colour theme id for a category folder, if set.
    func categoryColorID(forCategory category: String) -> String? {
        guard !category.isEmpty else { return nil }
        let metaURL = url(forFolderPath: category).appendingPathComponent(Self.categoryMetaFile)
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? decoder.decode(CategoryMeta.self, from: data) else { return nil }
        return meta.coverColorID
    }

    /// Sets (or clears, with `nil`) the cover-colour theme id for a category.
    func setCategoryColorID(_ id: String?, forCategory category: String) {
        guard !category.isEmpty else { return }
        let folderURL = url(forFolderPath: category)
        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let metaURL = folderURL.appendingPathComponent(Self.categoryMetaFile)
        if let data = try? encoder.encode(CategoryMeta(coverColorID: id)) {
            try? data.write(to: metaURL)
        }
        updateManifest()
    }

    /// Moves every top-level entry (note folders, `.trash`, `.history`) from one
    /// store root into another, used when switching between local and iCloud
    /// storage. Existing items at the destination are left untouched.
    static func moveContents(from source: URL, to destination: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try? fm.moveItem(at: item, to: target)
        }
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

    /// Copies the existing `note.md` (if any) into `.history/<id>/<timestamp>.md`
    /// and prunes the folder to the most recent `historyLimit` snapshots.
    private func snapshotContent(for note: Note, from folderURL: URL) {
        let contentURL = folderURL.appendingPathComponent(FileName.content)
        guard let existing = try? Data(contentsOf: contentURL), !existing.isEmpty else { return }

        let historyURL = url(forFolderPath: Self.historyDir)
            .appendingPathComponent(note.id.uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: historyURL, withIntermediateDirectories: true)

        let stamp = Self.snapshotFormatter.string(from: Date())
        try? existing.write(to: historyURL.appendingPathComponent("\(stamp).md"))
        pruneHistory(at: historyURL)
    }

    private func pruneHistory(at historyURL: URL) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: historyURL,
            includingPropertiesForKeys: nil
        ) else { return }
        let snapshots = files.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard snapshots.count > Self.historyLimit else { return }
        for url in snapshots.prefix(snapshots.count - Self.historyLimit) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Millisecond-precision timestamp so snapshots within the same second don't
    /// collide, e.g. "2026-07-08_10-00-00-123".
    private static let snapshotFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return formatter
    }()

    /// Timestamp-based folder path, e.g. "2026-07-08_10-00-00".
    /// (Auto-categorization into named parent folders is a later phase.)
    private static func makeFolderPath(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}
