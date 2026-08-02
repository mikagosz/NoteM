import Foundation

/// File-backed store for notes.
///
/// Root directory is `~/Documents/NoteM/` (hard-coded for now — no location
/// settings yet). Each note is a folder containing `note.md` and `meta.json`.
final class NoteStore {
    /// Names of the files stored inside every note folder.
    private enum FileName {
        static let content = "note.md"
        /// Full-fidelity archive of the note's attributed string (colours, fonts,
        /// pasted formatting, inline images). The source of truth for display;
        /// `note.md` is kept alongside for text features (tasks, links, titles).
        static let rich = "note.rich"
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

    /// Called when a note's own data can't be written to disk — its text, rich
    /// archive, metadata, attachments or folder moves.
    ///
    /// Kept separate from `onWriteError`: that one reports store-level iCloud
    /// availability and is cleared by the sync poller on the next healthy tick,
    /// which would swallow a message about a note that failed to save.
    var onDataError: ((String) -> Void)?

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
        let id = UUID()
        // New notes start unfiled in Inbox; the categorization engine may move
        // them once they have content (see NotesModel.save).
        var folderPath = CategoryEngine.inbox + "/" + Self.makeFolderPath(for: now)
        // The folder name is only precise to the second, so two notes created in
        // the same second would share one — and the second would overwrite the
        // first's note.md and meta.json, losing it. Disambiguate as elsewhere.
        if fileManager.fileExists(atPath: url(forFolderPath: folderPath).path) {
            folderPath += "-" + id.uuidString.prefix(8)
        }
        let note = Note(id: id, title: title, created: now, modified: now, folderPath: folderPath)

        let folderURL = url(forFolderPath: folderPath)
        // Without the folder both writes below would fail too — report once.
        guard ensureDirectory(at: folderURL) else { return note }

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
    /// `modified`.
    ///
    /// Returns `nil` when the note's text couldn't reach the disk — the caller
    /// must not then present the note as saved, since a bumped `modified` on a
    /// failed write would also make this version look newer than a good copy on
    /// another Mac. The failure is reported through `onDataError`.
    @discardableResult
    func saveNote(_ note: Note, content: String, richData: Data? = nil) -> Note? {
        var updated = note
        updated.modified = Date()

        let folderURL = url(forFolderPath: updated.folderPath)
        guard ensureDirectory(at: folderURL) else { return nil }

        // Snapshot the previous content before overwriting, as a safety net.
        snapshotContent(for: updated, from: folderURL)
        guard writeContent(content, to: folderURL) else { return nil }
        writeRich(richData, to: folderURL)
        writeMeta(updated.meta, to: folderURL)
        updateManifest()

        return updated
    }

    // MARK: - Trash

    /// Moves a note's folder into `.trash/<id>`, recording where it came from and
    /// when it was deleted. Returns the note with its trash `folderPath` and
    /// metadata, or `nil` if the move didn't happen (reported via `onDataError`)
    /// — the caller must then leave the note where the user can still see it.
    @discardableResult
    func trashNote(_ note: Note) -> Note? {
        let source = url(forFolderPath: note.folderPath)
        guard fileManager.fileExists(atPath: source.path) else {
            onDataError?(Loc.t("Folder notatki „\(note.title)” zniknął z dysku — nie ma czego przenieść do kosza",
                               "The folder for “\(note.title)” is gone from disk — nothing to move to the trash"))
            return nil
        }

        let trashPath = Self.trashDir + "/" + note.id.uuidString
        let destination = url(forFolderPath: trashPath)
        guard ensureDirectory(at: destination.deletingLastPathComponent()) else { return nil }
        if fileManager.fileExists(atPath: destination.path) {
            guard write(Loc.t("Nie udało się zwolnić miejsca w koszu",
                              "Could not clear the slot in the trash"), {
                try fileManager.removeItem(at: destination)
            }) else { return nil }
        }
        guard write(Loc.t("Nie udało się przenieść notatki „\(note.title)” do kosza",
                          "Could not move “\(note.title)” to the trash"), {
            try fileManager.moveItem(at: source, to: destination)
        }) else { return nil }

        var trashed = note
        trashed.originalFolderPath = note.folderPath
        trashed.deletedAt = Date()
        trashed.folderPath = trashPath
        writeMeta(trashed.meta, to: destination)
        updateManifest()
        return trashed
    }

    /// Moves a trashed note back to its original location (disambiguating if
    /// something now sits there) and clears its trash metadata. Returns `nil`
    /// when the move failed, so the note stays visible in the trash.
    @discardableResult
    func restoreNote(_ note: Note) -> Note? {
        let source = url(forFolderPath: note.folderPath)
        guard fileManager.fileExists(atPath: source.path) else {
            onDataError?(Loc.t("Folder notatki „\(note.title)” zniknął z kosza — nie ma czego przywrócić",
                               "The folder for “\(note.title)” is gone from the trash — nothing to restore"))
            return nil
        }

        let target = note.originalFolderPath ?? (CategoryEngine.inbox + "/" + note.id.uuidString)
        var finalPath = target
        var destination = url(forFolderPath: finalPath)
        guard ensureDirectory(at: destination.deletingLastPathComponent()) else { return nil }
        if fileManager.fileExists(atPath: destination.path) {
            finalPath = target + "-" + note.id.uuidString.prefix(8)
            destination = url(forFolderPath: finalPath)
        }
        guard write(Loc.t("Nie udało się przywrócić notatki „\(note.title)” z kosza",
                          "Could not restore “\(note.title)” from the trash"), {
            try fileManager.moveItem(at: source, to: destination)
        }) else { return nil }

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
    /// the note with its updated `folderPath`, or `nil` if it stayed put.
    @discardableResult
    func moveNote(_ note: Note, toFolderPath newFolderPath: String) -> Note? {
        let source = url(forFolderPath: note.folderPath)
        guard fileManager.fileExists(atPath: source.path) else { return nil }

        var finalPath = newFolderPath
        var destination = url(forFolderPath: finalPath)
        guard ensureDirectory(at: destination.deletingLastPathComponent()) else { return nil }
        // Disambiguate if something already sits at the destination.
        if fileManager.fileExists(atPath: destination.path) {
            finalPath = newFolderPath + "-" + note.id.uuidString.prefix(8)
            destination = url(forFolderPath: finalPath)
        }

        guard write(Loc.t("Nie udało się skatalogować notatki „\(note.title)” w folderze \(newFolderPath)",
                          "Could not file “\(note.title)” into \(newFolderPath)"), {
            try fileManager.moveItem(at: source, to: destination)
        }) else { return nil }

        var moved = note
        moved.folderPath = finalPath
        return moved
    }

    /// Rewrites only `meta.json` for a note (e.g. after a tags change), leaving
    /// `note.md` and `modified` untouched. Returns whether it reached the disk.
    @discardableResult
    func updateMeta(_ note: Note) -> Bool {
        let folderURL = url(forFolderPath: note.folderPath)
        guard writeMeta(note.meta, to: folderURL) else { return false }
        updateManifest()
        return true
    }

    /// Deletes a note's entire folder from disk. Returns whether it's gone.
    @discardableResult
    func deleteNote(_ note: Note) -> Bool {
        let folderURL = url(forFolderPath: note.folderPath)
        // Already gone — the caller's goal is met, nothing to report.
        guard fileManager.fileExists(atPath: folderURL.path) else { return true }
        guard write(Loc.t("Nie udało się usunąć notatki „\(note.title)” z dysku",
                          "Could not delete “\(note.title)” from disk"), {
            try fileManager.removeItem(at: folderURL)
        }) else { return false }
        updateManifest()
        return true
    }

    /// Reads the `note.md` content for a given note, or an empty string if
    /// none is present.
    func loadContent(for note: Note) -> String {
        let contentURL = url(forFolderPath: note.folderPath)
            .appendingPathComponent(FileName.content)
        return (try? String(contentsOf: contentURL, encoding: .utf8)) ?? ""
    }

    /// Reads the full-fidelity `note.rich` archive, or `nil` if the note predates
    /// rich storage (in which case the caller rebuilds from `note.md`).
    func loadRichData(for note: Note) -> Data? {
        let url = url(forFolderPath: note.folderPath)
            .appendingPathComponent(FileName.rich)
        return try? Data(contentsOf: url)
    }

    /// Public absolute URL for a note's folder (used by the editor to resolve
    /// attachment paths).
    func folderURL(for note: Note) -> URL {
        url(forFolderPath: note.folderPath)
    }

    // MARK: - Attachments

    /// Copies `fileURL` into `noteFolder/attachments/`, disambiguating the name
    /// if needed. Returns the final filename on success.
    @discardableResult
    func addAttachment(fileURL: URL, toNote note: Note) -> String? {
        let attachDir = url(forFolderPath: note.folderPath).appendingPathComponent("attachments", isDirectory: true)
        guard ensureDirectory(at: attachDir) else { return nil }

        var dest = attachDir.appendingPathComponent(fileURL.lastPathComponent)
        var counter = 1
        while fileManager.fileExists(atPath: dest.path) {
            let base = fileURL.deletingPathExtension().lastPathComponent
            let ext  = fileURL.pathExtension
            dest = attachDir.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }
        guard write(Loc.t("Nie udało się dodać załącznika „\(fileURL.lastPathComponent)”",
                          "Could not add the attachment “\(fileURL.lastPathComponent)”"), {
            try fileManager.copyItem(at: fileURL, to: dest)
        }) else { return nil }
        updateManifest()
        return dest.lastPathComponent
    }

    /// Deletes files in a note's `attachments/` folder that are no longer
    /// referenced by the note (their filename isn't in `keeping`). Called on save
    /// so images the user removed from a note also leave the "Załączniki" view.
    /// The image bytes still live in `note.rich`, so this only drops the now
    /// redundant standalone file.
    func pruneAttachments(for note: Note, keeping names: Set<String>) {
        let dir = url(forFolderPath: note.folderPath)
            .appendingPathComponent("attachments", isDirectory: true)
        guard let items = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        var removedAny = false
        for item in items where !names.contains(item.lastPathComponent) {
            let removed = write(Loc.t("Nie udało się usunąć nieużywanego załącznika „\(item.lastPathComponent)”",
                                      "Could not remove the unused attachment “\(item.lastPathComponent)”")) {
                try fileManager.removeItem(at: item)
            }
            if removed { removedAny = true }
        }
        if removedAny { updateManifest() }
    }

    /// Filenames inside a note's `attachments/` folder, sorted. Empty when the
    /// note has no attachments folder. Used to build the "Załączniki" index.
    func attachmentFilenames(for note: Note) -> [String] {
        let dir = url(forFolderPath: note.folderPath)
            .appendingPathComponent("attachments", isDirectory: true)
        guard let items = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.map(\.lastPathComponent).sorted()
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
            onWriteError?(Loc.t("iCloud Drive niedostępny — działam lokalnie", "iCloud Drive unavailable — working locally"))
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
    /// Returns whether it reached the disk.
    @discardableResult
    func setCategoryColorID(_ id: String?, forCategory category: String) -> Bool {
        guard !category.isEmpty else { return false }
        let folderURL = url(forFolderPath: category)
        guard ensureDirectory(at: folderURL) else { return false }
        let metaURL = folderURL.appendingPathComponent(Self.categoryMetaFile)
        guard write(Loc.t("Nie udało się zapisać koloru kategorii „\(category)”",
                          "Could not save the cover colour for “\(category)”"), {
            try encoder.encode(CategoryMeta(coverColorID: id)).write(to: metaURL, options: .atomic)
        }) else { return false }
        updateManifest()
        return true
    }

    /// Moves every top-level entry (note folders, `.trash`, `.history`) from one
    /// store root into another, used when switching between local and iCloud
    /// storage. Existing items at the destination are left untouched.
    ///
    /// Returns the names that could not be moved, so the caller can tell the user
    /// which notes stayed behind instead of silently losing half the library.
    static func moveContents(from source: URL, to destination: URL) -> [String] {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return [destination.lastPathComponent]
        }
        guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return [] }
        var failed: [String] = []
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            guard !fm.fileExists(atPath: target.path) else { continue }
            do {
                try fm.moveItem(at: item, to: target)
            } catch {
                failed.append(item.lastPathComponent)
            }
        }
        return failed
    }

    // MARK: - Helpers

    private func ensureRootExists() {
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        // Keep the iCloud sync folder out of the user's iCloud Drive view.
        StorageLocation.hideICloudFolder(rootURL)
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
            // Can't be expressed relative to the root, so the fallback below is a
            // guess — every later path built from it points somewhere else than
            // the note actually lives. Say so instead of failing quietly.
            onDataError?(Loc.t("Folder notatki leży poza magazynem: \(folderURL.path)",
                               "Note folder lies outside the store: \(folderURL.path)"))
            return folderURL.lastPathComponent
        }
        return folderComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// Runs a disk write, reporting `what` through `onDataError` when it fails.
    /// Returns whether the write went through, so callers can stop instead of
    /// piling a second failure on top of the first.
    @discardableResult
    private func write(_ what: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            return true
        } catch {
            onDataError?(what + " — " + error.localizedDescription)
            return false
        }
    }

    /// Creates a folder (with intermediates), reporting failure. Returns whether
    /// the folder is there to be written into.
    @discardableResult
    private func ensureDirectory(at url: URL) -> Bool {
        write(Loc.t("Nie udało się utworzyć folderu „\(url.lastPathComponent)”",
                    "Could not create the folder “\(url.lastPathComponent)”")) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    @discardableResult
    private func writeContent(_ content: String, to folderURL: URL) -> Bool {
        let url = folderURL.appendingPathComponent(FileName.content)
        return write(Loc.t("Nie udało się zapisać treści notatki",
                           "Could not save the note's text")) {
            try Data(content.utf8).write(to: url, options: .atomic)
        }
    }

    /// Writes the rich archive, or removes a stale one when `data` is nil (e.g. a
    /// markdown-only save such as completing a task) so display falls back to md.
    @discardableResult
    private func writeRich(_ data: Data?, to folderURL: URL) -> Bool {
        let url = folderURL.appendingPathComponent(FileName.rich)
        if let data {
            return write(Loc.t("Nie udało się zapisać formatowania notatki",
                               "Could not save the note's formatting")) {
                try data.write(to: url, options: .atomic)
            }
        }
        // Nothing to clear — not a failure, so don't report one.
        guard fileManager.fileExists(atPath: url.path) else { return true }
        return write(Loc.t("Nie udało się usunąć nieaktualnego formatowania notatki",
                           "Could not remove the note's stale formatting")) {
            try fileManager.removeItem(at: url)
        }
    }

    @discardableResult
    private func writeMeta(_ meta: NoteMeta, to folderURL: URL) -> Bool {
        let url = folderURL.appendingPathComponent(FileName.meta)
        return write(Loc.t("Nie udało się zapisać danych notatki",
                           "Could not save the note's metadata")) {
            try encoder.encode(meta).write(to: url, options: .atomic)
        }
    }

    /// Copies the existing `note.md` (if any) into `.history/<id>/<timestamp>.md`
    /// and prunes the folder to the most recent `historyLimit` snapshots.
    ///
    /// Deliberately silent: history is a best-effort safety net on top of the
    /// save, and a failure here means no snapshot — not a lost note. The save
    /// itself reports through `onDataError`, and a broken disk would otherwise
    /// produce two banners for every keystroke pause.
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
