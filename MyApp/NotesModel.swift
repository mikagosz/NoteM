import Foundation
import Observation

/// Observable UI-facing wrapper around `NoteStore`.
///
/// Holds the in-memory list of notes (sorted newest-modified first) and
/// forwards create / save / delete to the file-backed store.
@MainActor
@Observable
final class NotesModel {
    private var store = NoteStore()

    /// Indeks semantyczny (Priorytet 3): wektory znaczeniowe notatek do trybu
    /// wyszukiwania "znaczeniowo". Aktor — liczy poza głównym wątkiem.
    nonisolated let semanticIndex = SemanticIndex()

    /// Notes currently known to the UI, sorted by `modified` descending.
    private(set) var notes: [Note] = []

    /// Trashed notes, most recently deleted first.
    private(set) var trashedNotes: [Note] = []

    /// Sync conflicts: same note id found in more than one folder on disk.
    private(set) var conflicts: [NoteConflict] = []

    /// Cover-colour theme id per category folder (e.g. "Praca" → "ocean").
    private(set) var categoryColors: [String: String] = [:]

    /// Every attachment / image / link found across all notes, for the
    /// "Załączniki" view. Rebuilt whenever the notes or their content change.
    private(set) var attachments: [AttachmentRef] = []

    /// Per-note attachment refs, so a save only rescans the note that changed
    /// instead of reading every note's content back off the disk.
    @ObservationIgnored private var attachmentsByNote: [UUID: [AttachmentRef]] = [:]

    /// Last failed write to disk (note text, metadata, attachment, trash move),
    /// or `nil` when everything landed. Shown as a banner so a save that didn't
    /// reach the disk can't pass unnoticed.
    private(set) var storeError: String?

    /// Notes whose editor holds changes not yet written to disk. An external
    /// (iCloud) reload would replace the editor's text with the older on-disk
    /// version, so `reloadFromExternalChange()` defers while this isn't empty.
    @ObservationIgnored private var notesWithPendingEdits: Set<UUID> = []

    /// Absolute URL of the current store root (local Documents or iCloud Drive).
    var rootURL: URL { store.rootURL }

    /// Absolute URL of a note's folder (for attachment resolution).
    func noteFolder(for note: Note) -> URL { store.folderURL(for: note) }

    /// Copies a file into the note's `attachments/` subfolder. Returns the
    /// resulting filename, or `nil` if the copy failed (the store reports why
    /// through `storeError`).
    @discardableResult
    func addAttachment(fileURL: URL, to note: Note) -> String? {
        let filename = store.addAttachment(fileURL: fileURL, toNote: note)
        if filename != nil { refreshAttachments(for: note) }
        return filename
    }

    /// Supplies the trash auto-clean window (days). Set by the UI from settings.
    var trashRetentionProvider: () -> Int = { 30 }

    /// Supplies the current auto-filing rules at save time. Set by the UI from
    /// `AppSettings`; defaults to no rules.
    var rulesProvider: () -> [CategoryRule] = { [] }

    /// Supplies the Obsidian mirror settings: whether every save is mirrored, and
    /// which vault folder receives the `.md` copies. Set by the UI from
    /// `AppSettings`.
    var obsidianConfigProvider: () -> (autoExport: Bool, folder: URL) = {
        (false, URL(fileURLWithPath: ObsidianExport.defaultVaultFolder))
    }

    /// Last Obsidian export failure (e.g. vault folder unreachable), or `nil`
    /// when the mirror is healthy.
    private(set) var obsidianError: String?

    /// Pending debounced auto-exports, keyed by note id.
    @ObservationIgnored private var obsidianExportTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        connectStoreErrors()
        reload()
        let indexURL = store.rootURL.appendingPathComponent("semantic_index.json")
        Task { await semanticIndex.configure(indexURL: indexURL) }
    }

    /// Routes the store's write failures into `storeError` so the UI can show
    /// them. Re-applied whenever the store is replaced (storage switch).
    private func connectStoreErrors() {
        store.onDataError = { [weak self] message in
            self?.storeError = message
        }
    }

    /// Clears the write-error banner (after the user acknowledged it).
    func clearStoreError() { storeError = nil }

    // MARK: - Unsaved editor changes

    /// Called by the open editor when it holds text that isn't on disk yet.
    func beginPendingEdits(for noteID: UUID) {
        notesWithPendingEdits.insert(noteID)
    }

    /// Called once the editor's text has been written (or the editor closed).
    func endPendingEdits(for noteID: UUID) {
        notesWithPendingEdits.remove(noteID)
    }

    /// Reloads all notes from disk, purging expired trash first and detecting
    /// sync conflicts (the same note id sitting in more than one folder).
    func reload() {
        store.emptyTrash(olderThanDays: trashRetentionProvider())

        let raw = store.loadAllNotes()
        let grouped = Dictionary(grouping: raw, by: \.id)
        conflicts = grouped
            .filter { $0.value.count > 1 }
            .map { NoteConflict(id: $0.key, versions: $0.value.sorted { $0.modified > $1.modified }) }
            .sorted { $0.versions[0].title < $1.versions[0].title }
        // For conflicted ids, show the most recently modified version in the list.
        notes = grouped.values
            .compactMap { $0.max(by: { $0.modified < $1.modified }) }
            .sorted(by: Self.pinnedThenModified)

        trashedNotes = store.loadTrashedNotes()
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }

        var colors: [String: String] = [:]
        for note in notes {
            let cat = category(of: note)
            if !cat.isEmpty, colors[cat] == nil, let id = store.categoryColorID(forCategory: cat) {
                colors[cat] = id
            }
        }
        categoryColors = colors

        rebuildAttachments()
    }

    // MARK: - Category cover colour

    /// The category (parent folder path) a note lives in, e.g. "Praca".
    func category(of note: Note) -> String {
        note.folderPath.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// Cover-colour theme id for a note's category, if any.
    func categoryColorID(of note: Note) -> String? {
        categoryColors[category(of: note)]
    }

    /// Sets (or clears) the cover colour for a note's category and persists it.
    func setCategoryColor(_ id: String?, for note: Note) {
        let cat = category(of: note)
        guard !cat.isEmpty, store.setCategoryColorID(id, forCategory: cat) else { return }
        if let id {
            categoryColors[cat] = id
        } else {
            categoryColors.removeValue(forKey: cat)
        }
    }

    /// Reload triggered by an external filesystem change (e.g. another Mac via
    /// iCloud).
    ///
    /// Returns `false` — without reloading — while an editor still holds unsaved
    /// text: the reload would swap the editor's note for the older copy on disk
    /// and the user's last few seconds of typing would be gone. The autosave
    /// runs a second after the last keystroke, so the caller only has to come
    /// back on its next poll.
    @discardableResult
    func reloadFromExternalChange() -> Bool {
        guard notesWithPendingEdits.isEmpty else { return false }
        reload()
        return true
    }

    // MARK: - Storage location (sync)

    /// Write-error callback forwarded from the underlying store (set by SyncManager).
    var onStoreWriteError: ((String) -> Void)? {
        get { store.onWriteError }
        set { store.onWriteError = newValue }
    }

    /// Current `lastModified` from `manifest.json` (used by SyncManager for polling).
    func readManifestDate() -> Date? { store.readManifestDate() }

    /// Switches the store root between local and iCloud, optionally moving the
    /// existing notes across, then reloads.
    func switchStorage(syncEnabled: Bool, moveExisting: Bool) {
        let newRoot = StorageLocation.root(syncEnabled: syncEnabled)
        guard newRoot != store.rootURL else { return }
        let savedErrorHandler = store.onWriteError
        let oldRoot = store.rootURL
        var stragglers: [String] = []
        if moveExisting {
            stragglers = NoteStore.moveContents(from: oldRoot, to: newRoot)
        }
        store = NoteStore(rootURL: newRoot)
        store.onWriteError = savedErrorHandler
        connectStoreErrors()
        if !stragglers.isEmpty {
            storeError = Loc.t("Nie udało się przenieść \(stragglers.count) elementów — zostały w \(oldRoot.path)",
                               "Could not move \(stragglers.count) items — they stayed in \(oldRoot.path)")
        }
        reload()
    }

    /// Resolves a conflict by keeping one version and permanently removing the
    /// other folders that share its id.
    func resolveConflict(_ conflict: NoteConflict, keeping keep: Note) {
        for version in conflict.versions where version.folderPath != keep.folderPath {
            store.deleteNote(version)
        }
        reload()
    }

    /// Current on-disk content of any note version (used by the conflict view).
    func rawContent(for note: Note) -> String {
        store.loadContent(for: note)
    }

    /// Creates a new empty note and inserts it at the top of the list.
    @discardableResult
    func createNote() -> Note {
        let note = store.createNote(title: Loc.t("Nowa notatka", "New note"))
        notes.insert(note, at: 0)
        return note
    }

    /// Creates a note pre-filled with `content` (used by quick capture). Runs
    /// through the normal save path, so the title is derived and the
    /// categorization rules apply. `richData` carries the full-fidelity archive
    /// (pasted colours, fonts, images) so quick-capture notes keep 1:1 formatting
    /// just like the main editor; pass `nil` for plain markdown.
    @discardableResult
    func createNote(content: String, richData: Data? = nil, isTaskList: Bool = false) -> Note {
        let note = createNote()
        // Set the flag before saving so it lands in meta.json in one write.
        if isTaskList, let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index].isTaskList = true
        }
        save(note, content: content, richData: richData)
        return notes.first(where: { $0.id == note.id }) ?? note
    }

    /// Moves a note to the trash (soft delete): it leaves the main list but its
    /// folder is preserved under `.trash/` until restored or purged.
    ///
    /// If the folder didn't actually move, the note stays in the list — showing
    /// it as deleted while it's still on disk would put the screen out of step
    /// with the store. The store reports why through `storeError`.
    func delete(_ note: Note) {
        removeObsidianMirror(for: note)
        guard let trashed = store.trashNote(note) else { return }
        notes.removeAll { $0.id == note.id }
        trashedNotes.insert(trashed, at: 0)
        dropAttachments(for: note.id)
    }

    /// Restores a trashed note back to its original location. Leaves it in the
    /// trash if the move failed.
    func restore(_ note: Note) {
        guard let restored = store.restoreNote(note) else { return }
        trashedNotes.removeAll { $0.id == note.id }
        notes.insert(restored, at: 0)
        notes.sort(by: Self.pinnedThenModified)
        refreshAttachments(for: restored)

        // The mirror was removed when the note was trashed — put it back.
        if obsidianConfigProvider().autoExport {
            exportToObsidian(restored)
        }
    }

    /// Permanently deletes a trashed note's folder from disk. Keeps it listed if
    /// the folder is still there.
    func deletePermanently(_ note: Note) {
        guard store.deleteNote(note) else { return }
        trashedNotes.removeAll { $0.id == note.id }
        dropAttachments(for: note.id)
    }

    /// Current on-disk content of a note.
    func content(for note: Note) -> String {
        store.loadContent(for: note)
    }

    /// Full-fidelity rich archive of a note (colours, fonts, pasted formatting),
    /// or `nil` for notes saved before rich storage existed.
    func richContent(for note: Note) -> Data? {
        store.loadRichData(for: note)
    }

    // MARK: - Obsidian mirror

    /// Writes (or rewrites) a note's `.md` copy in the Obsidian vault and stamps
    /// it with the export date. Returns `false` and sets `obsidianError` when the
    /// vault folder can't be written to. Called automatically on save when the
    /// mirror is enabled, and from the "Wyślij do Obsidian" button.
    @discardableResult
    func exportToObsidian(_ note: Note) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return false }
        let current = notes[index]
        do {
            let outcome = try ObsidianExport.export(
                note: current,
                markdown: store.loadContent(for: current),
                category: category(of: current),
                noteFolder: store.folderURL(for: current),
                vaultFolder: obsidianConfigProvider().folder,
                previousRelativePath: current.obsidianPath
            )
            notes[index].obsidianExportedAt = outcome.exportedAt
            notes[index].obsidianPath = outcome.relativePath
            store.updateMeta(notes[index])
            obsidianError = nil
            return true
        } catch {
            obsidianError = error.localizedDescription
            return false
        }
    }

    /// Mirrors every note into the vault. Returns how many were written.
    @discardableResult
    func exportAllToObsidian() -> Int {
        notes.reduce(into: 0) { count, note in
            if exportToObsidian(note) { count += 1 }
        }
    }

    /// Moves the mirror after the vault folder changed: drops the copies from
    /// `oldFolder` and rewrites them where the mirror now points. Only notes that
    /// already had a copy are moved. Returns how many were rewritten.
    @discardableResult
    func relocateObsidianMirror(from oldFolder: URL) -> Int {
        let mirrored = notes.filter { $0.obsidianPath != nil }
        for note in mirrored {
            guard let path = note.obsidianPath else { continue }
            ObsidianExport.removeMirror(relativePath: path, vaultFolder: oldFolder, noteID: note.id)
        }
        return mirrored.reduce(into: 0) { count, note in
            if exportToObsidian(note) { count += 1 }
        }
    }

    /// Clears a stuck export error (after the user fixed the vault path).
    func clearObsidianError() { obsidianError = nil }

    /// Debounced auto-export: a burst of autosaves while typing produces a single
    /// vault write once the note has been quiet for a few seconds, so Obsidian's
    /// file watcher doesn't see the note change on every keystroke pause.
    private func scheduleObsidianExport(for note: Note) {
        obsidianExportTasks[note.id]?.cancel()
        obsidianExportTasks[note.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.obsidianExportTasks[note.id] = nil
            self?.exportToObsidian(note)
        }
    }

    /// Drops a note's copy from the vault, so a note deleted in NoteM also
    /// disappears from Obsidian. Only removes files this note created.
    private func removeObsidianMirror(for note: Note) {
        guard let path = note.obsidianPath else { return }
        ObsidianExport.removeMirror(
            relativePath: path,
            vaultFolder: obsidianConfigProvider().folder,
            noteID: note.id
        )
    }

    // MARK: - Categories (physical folders)

    /// Distinct non-Inbox category names present in the current note list, sorted.
    var categories: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for note in notes {
            let cat = category(of: note)
            guard !cat.isEmpty, cat != CategoryEngine.inbox, seen.insert(cat).inserted else { continue }
            result.append(cat)
        }
        return result.sorted()
    }

    // MARK: - Tags

    /// All tags in use with how many notes carry each, sorted alphabetically.
    var tagCounts: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for note in notes {
            for tag in note.tags { counts[tag, default: 0] += 1 }
        }
        return counts
            .map { (tag: $0.key, count: $0.value) }
            .sorted { $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending }
    }

    /// Replaces a note's tags (trimmed, de-duplicated) and persists them to
    /// `meta.json` without touching content or the `modified` timestamp.
    func setTags(_ tags: [String], for note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        let cleaned = Self.normalizeTags(tags)
        let previous = notes[index].tags
        guard cleaned != previous else { return }
        notes[index].tags = cleaned
        // Roll the chip back if meta.json didn't take it, so the tag bar can't
        // show a tag the note doesn't actually carry.
        if !store.updateMeta(notes[index]) { notes[index].tags = previous }
    }

    /// Trims, drops empties, and removes case-insensitive duplicates (keeping
    /// the first spelling), preserving order.
    private static func normalizeTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in tags {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            if seen.insert(tag.lowercased()).inserted { result.append(tag) }
        }
        return result
    }

    // MARK: - Wiki links & backlinks

    /// The note matching `title` (case-insensitive), if any.
    func note(forTitle title: String) -> Note? {
        let query = title.trimmingCharacters(in: .whitespaces)
        return notes.first { $0.title.caseInsensitiveCompare(query) == .orderedSame }
    }

    /// Notes that link to `note` (its incoming wiki links).
    func backlinks(to note: Note) -> [Note] {
        notes.filter { $0.id != note.id && $0.links.contains(note.id) }
    }

    /// Resolves `[[Title]]` references in `content` to target note IDs, skipping
    /// the note itself and unresolved titles.
    private func resolveLinks(in content: String, excluding selfID: UUID) -> [UUID] {
        var ids: [UUID] = []
        var seen = Set<UUID>()
        for title in MarkdownStyler.wikiTitles(in: content) {
            guard let target = note(forTitle: title), target.id != selfID else { continue }
            if seen.insert(target.id).inserted { ids.append(target.id) }
        }
        return ids
    }

    // MARK: - Attachments & links

    /// Rebuilds the whole attachment cache by reading every note off the disk.
    /// Only for `reload()` — a single save uses `refreshAttachments(for:)`, so
    /// typing doesn't trigger a full scan of the notes folder every second.
    private func rebuildAttachments() {
        attachmentsByNote = Dictionary(
            uniqueKeysWithValues: notes.map { ($0.id, attachmentRefs(for: $0)) }
        )
        recomposeAttachments()
    }

    /// Rescans one note and refreshes the flat list. No other note is read.
    private func refreshAttachments(for note: Note) {
        attachmentsByNote[note.id] = attachmentRefs(for: note)
        recomposeAttachments()
    }

    /// Drops a note from the cache (trashed or permanently deleted).
    private func dropAttachments(for noteID: UUID) {
        attachmentsByNote.removeValue(forKey: noteID)
        recomposeAttachments()
    }

    /// Flattens the cache into `attachments`, keeping the notes-list order.
    /// Memory only — no disk access.
    private func recomposeAttachments() {
        attachments = notes.flatMap { attachmentsByNote[$0.id] ?? [] }
    }

    /// Everything the "Załączniki" view shows for one note: files (images and
    /// other documents) from its `attachments/` folder, plus links detected
    /// inside its markdown content.
    private func attachmentRefs(for note: Note) -> [AttachmentRef] {
        var result: [AttachmentRef] = []
        // Files physically copied into the note's attachments/ folder — this
        // catches drag-dropped and pasted images too, which live as visual
        // attachments rather than as `![](…)` markdown.
        for filename in store.attachmentFilenames(for: note) {
            let ext = (filename as NSString).pathExtension.lowercased()
            let kind: AttachmentRef.Kind = AttachmentRef.imageExtensions.contains(ext) ? .image : .file
            result.append(AttachmentRef(
                noteID: note.id,
                noteTitle: note.title,
                kind: kind,
                label: filename,
                target: "attachments/\(filename)"
            ))
        }
        // Web / mail links written anywhere in the note's markdown.
        for link in Self.webLinks(in: store.loadContent(for: note)) {
            result.append(AttachmentRef(
                noteID: note.id,
                noteTitle: note.title,
                kind: .link,
                label: link,
                target: link
            ))
        }
        return result
    }

    /// All distinct http/https/mailto links in `content`, in order of appearance.
    private static func webLinks(in content: String) -> [String] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let ns = content as NSString
        var seen = Set<String>()
        var links: [String] = []
        for match in detector.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" || scheme == "mailto" else { continue }
            let string = url.absoluteString
            if seen.insert(string).inserted { links.append(string) }
        }
        return links
    }

    // MARK: - Task notes

    /// Notes flagged as planned task lists, for the "Zadania" view. Keeps the
    /// notes-list order.
    var taskNotes: [Note] {
        notes.filter(\.isTaskList)
    }

    /// Number of active (not-yet-done) task-notes — shown as a badge next to the
    /// "Zadania" sidebar row.
    var activeTaskCount: Int {
        notes.filter { $0.isTaskList && !$0.taskDone }.count
    }

    /// Persists `content` for `note`, deriving the title from the first line.
    ///
    /// No-op if the note is no longer in the list (e.g. it was just deleted) —
    /// this prevents a trailing autosave from recreating a deleted note.
    /// `richData` is the full-fidelity archive of the editor's attributed string;
    /// pass `nil` for markdown-only saves (quick capture, task completion), which
    /// clears any stale rich cache so display rebuilds from markdown.
    func save(_ note: Note, content: String, richData: Data? = nil, referencedAttachments: Set<String>? = nil) {
        // Use the model's own copy for the authoritative folder path: the note
        // may have been moved by the categorization engine since the editor
        // loaded it, so the caller's `folderPath` can be stale.
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }

        var current = notes[index]
        current.title = Self.deriveTitle(from: content)
        current.links = resolveLinks(in: content, excluding: current.id)
        // The text didn't reach the disk: leave the list showing the last version
        // that did, rather than marking the note as saved. `storeError` says why.
        guard var saved = store.saveNote(current, content: content, richData: richData) else { return }

        // Auto-file into a category folder based on the rules (first match wins).
        if let newFolderPath = CategoryEngine.targetFolderPath(
            content: content,
            currentFolderPath: saved.folderPath,
            rules: rulesProvider()
        ), let moved = store.moveNote(saved, toFolderPath: newFolderPath) {
            saved = moved
        }

        // Drop attachment files the user removed from the note (only when the
        // caller supplied the still-referenced set, i.e. from the full editor).
        if let referencedAttachments {
            store.pruneAttachments(for: saved, keeping: referencedAttachments)
        }

        notes[index] = saved
        notes.sort(by: Self.pinnedThenModified)
        refreshAttachments(for: saved)

        if obsidianConfigProvider().autoExport {
            scheduleObsidianExport(for: saved)
        }
    }

    /// Sort order for the notes list: pinned notes first, then newest-modified.
    static func pinnedThenModified(_ a: Note, _ b: Note) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        return a.modified > b.modified
    }

    /// Toggles a note's pinned state, persists it, and re-sorts the list.
    /// A failed write is undone so the pin can't disagree with the disk.
    func togglePin(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index].pinned.toggle()
        guard store.updateMeta(notes[index]) else {
            notes[index].pinned.toggle()
            return
        }
        notes.sort(by: Self.pinnedThenModified)
    }

    /// Toggles whether a note is a planned task list and persists it. Doesn't
    /// touch content or the `modified` timestamp.
    func toggleTaskList(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index].isTaskList.toggle()
        if !store.updateMeta(notes[index]) { notes[index].isTaskList.toggle() }
    }

    /// Toggles a task-note's done state (ticked off in "Zadania") and persists it.
    func toggleTaskDone(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index].taskDone.toggle()
        if !store.updateMeta(notes[index]) { notes[index].taskDone.toggle() }
    }

    /// Derives a display title from the first non-empty line of the content,
    /// stripping leading markdown markers (headers, list bullets) and emphasis.
    private static func deriveTitle(from content: String) -> String {
        var line = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""

        // Checklist item: strip "- [ ] " / "- [x] " down to its text.
        if let (_, body) = MarkdownStyler.parseChecklist(line) {
            line = body.trimmingCharacters(in: .whitespaces)
        }

        // Leading header hashes.
        while line.hasPrefix("#") { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespaces)

        // Leading list markers ("- ", "* ", "• ", "1. ").
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            line.removeFirst(marker.count)
        }
        if let dot = line.firstIndex(of: "."),
           line[line.startIndex..<dot].allSatisfy(\.isNumber),
           line.index(after: dot) < line.endIndex,
           line[line.index(after: dot)] == " " {
            line = String(line[line.index(dot, offsetBy: 2)...])
        }

        line = line.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? Loc.t("Nowa notatka", "New note") : String(line.prefix(60))
    }
}
