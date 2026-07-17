import Foundation
import Observation

/// One unchecked checklist item collected from a note, for the "Zadania" view.
struct TaskItem: Identifiable, Hashable {
    let noteID: UUID
    let noteTitle: String
    /// Zero-based line index of the item within its note's `note.md`.
    let lineIndex: Int
    /// Display text (inline markdown stripped).
    let text: String

    var id: String { "\(noteID.uuidString)#\(lineIndex)" }
}

/// Observable UI-facing wrapper around `NoteStore`.
///
/// Holds the in-memory list of notes (sorted newest-modified first) and
/// forwards create / save / delete to the file-backed store.
@MainActor
@Observable
final class NotesModel {
    private var store = NoteStore()

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

    /// Absolute URL of the current store root (local Documents or iCloud Drive).
    var rootURL: URL { store.rootURL }

    /// Absolute URL of a note's folder (for attachment resolution).
    func noteFolder(for note: Note) -> URL { store.folderURL(for: note) }

    /// Copies a file into the note's `attachments/` subfolder. Returns the
    /// resulting filename, or `nil` if the copy failed.
    @discardableResult
    func addAttachment(fileURL: URL, to note: Note) -> String? {
        let filename = store.addAttachment(fileURL: fileURL, toNote: note)
        rebuildAttachments()
        if let filename { scheduleOCR(filename: filename, noteID: note.id) }
        return filename
    }

    // MARK: - OCR (Zadanie 2.1)

    /// Runs Vision text recognition on a freshly added image attachment and
    /// stores the result in the note's metadata. Fire-and-forget: recognition
    /// awaits off the main thread, only the metadata update comes back here.
    private func scheduleOCR(filename: String, noteID: UUID) {
        guard ImageOCR.isSupportedImage(filename) else { return }
        guard let note = notes.first(where: { $0.id == noteID }) else { return }
        let fileURL = store.folderURL(for: note)
            .appendingPathComponent("attachments/\(filename)")
        Task { [weak self] in
            guard let text = await ImageOCR.recognizeText(in: fileURL) else { return }
            self?.applyOCR(text: text, filename: filename, noteID: noteID)
        }
    }

    /// Stores a manual correction of the recognized text, made by the user in
    /// the OCR panel (Zadanie 2.3).
    func setOCRText(_ text: String, filename: String, for note: Note) {
        applyOCR(text: text, filename: filename, noteID: note.id)
    }

    /// Writes the recognized text into the note's `meta.json` (hidden metadata —
    /// the note content is never touched).
    private func applyOCR(text: String, filename: String, noteID: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        var note = notes[index]
        guard note.ocrTexts[filename] != text else { return }
        note.ocrTexts[filename] = text
        notes[index] = store.updateMeta(note)
    }

    /// Supplies the trash auto-clean window (days). Set by the UI from settings.
    var trashRetentionProvider: () -> Int = { 30 }

    /// Supplies the current auto-filing rules at save time. Set by the UI from
    /// `AppSettings`; defaults to no rules.
    var rulesProvider: () -> [CategoryRule] = { [] }

    init() {
        reload()
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
        guard !cat.isEmpty else { return }
        store.setCategoryColorID(id, forCategory: cat)
        if let id {
            categoryColors[cat] = id
        } else {
            categoryColors.removeValue(forKey: cat)
        }
    }

    /// Reload triggered by an external filesystem change (e.g. another Mac via
    /// iCloud). Same as `reload()`, named for clarity at the call site.
    func reloadFromExternalChange() { reload() }

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
        if moveExisting {
            NoteStore.moveContents(from: store.rootURL, to: newRoot)
        }
        store = NoteStore(rootURL: newRoot)
        store.onWriteError = savedErrorHandler
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
    func delete(_ note: Note) {
        let trashed = store.trashNote(note)
        notes.removeAll { $0.id == note.id }
        trashedNotes.insert(trashed, at: 0)
        rebuildAttachments()
    }

    /// Restores a trashed note back to its original location.
    func restore(_ note: Note) {
        let restored = store.restoreNote(note)
        trashedNotes.removeAll { $0.id == note.id }
        notes.insert(restored, at: 0)
        notes.sort(by: Self.pinnedThenModified)
        rebuildAttachments()
    }

    /// Permanently deletes a trashed note's folder from disk.
    func deletePermanently(_ note: Note) {
        store.deleteNote(note)
        trashedNotes.removeAll { $0.id == note.id }
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
        guard cleaned != notes[index].tags else { return }
        notes[index].tags = cleaned
        store.updateMeta(notes[index])
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

    /// Rebuilds `attachments` by scanning every note: files (images and other
    /// documents) come from each note's `attachments/` folder, links are
    /// detected inside the note's markdown content. Notes keep their list order.
    private func rebuildAttachments() {
        var result: [AttachmentRef] = []
        for note in notes {
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
        }
        attachments = result
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

    // MARK: - Collected tasks

    /// All unchecked checklist items (`- [ ]`) across every note. Order follows
    /// the notes list, then line order.
    func openTasks() -> [TaskItem] {
        notes.flatMap { openTasks(in: $0) }
    }

    /// Unchecked checklist items (`- [ ]`) within a single note, in line order.
    func openTasks(in note: Note) -> [TaskItem] {
        var items: [TaskItem] = []
        let lines = store.loadContent(for: note).components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
            guard let (checked, body) = MarkdownStyler.parseChecklist(trimmed), !checked else { continue }
            let text = MarkdownStyler.plainText(fromInline: body).trimmingCharacters(in: .whitespaces)
            items.append(TaskItem(noteID: note.id, noteTitle: note.title, lineIndex: index, text: text))
        }
        return items
    }

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

    /// Marks a collected task as done (`- [ ]` → `- [x]`) in its source note and
    /// persists the change immediately.
    func completeTask(_ task: TaskItem) {
        guard let note = notes.first(where: { $0.id == task.noteID }) else { return }
        var lines = store.loadContent(for: note).components(separatedBy: "\n")
        guard task.lineIndex < lines.count else { return }

        let line = lines[task.lineIndex]
        let leading = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let trimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        guard let (checked, body) = MarkdownStyler.parseChecklist(trimmed), !checked else { return }

        lines[task.lineIndex] = leading + "- [x] " + body
        save(note, content: lines.joined(separator: "\n"))
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
        var saved = store.saveNote(current, content: content, richData: richData)

        // Auto-file into a category folder based on the rules (first match wins).
        if let newFolderPath = CategoryEngine.targetFolderPath(
            content: content,
            currentFolderPath: saved.folderPath,
            rules: rulesProvider()
        ) {
            saved = store.moveNote(saved, toFolderPath: newFolderPath)
        }

        // Drop attachment files the user removed from the note (only when the
        // caller supplied the still-referenced set, i.e. from the full editor).
        if let referencedAttachments {
            store.pruneAttachments(for: saved, keeping: referencedAttachments)
        }

        notes[index] = saved
        notes.sort(by: Self.pinnedThenModified)
        rebuildAttachments()
    }

    /// Sort order for the notes list: pinned notes first, then newest-modified.
    static func pinnedThenModified(_ a: Note, _ b: Note) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        return a.modified > b.modified
    }

    /// Toggles a note's pinned state, persists it, and re-sorts the list.
    func togglePin(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index].pinned.toggle()
        store.updateMeta(notes[index])
        notes.sort(by: Self.pinnedThenModified)
    }

    /// Toggles whether a note is a planned task list and persists it. Doesn't
    /// touch content or the `modified` timestamp.
    func toggleTaskList(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index].isTaskList.toggle()
        store.updateMeta(notes[index])
    }

    /// Toggles a task-note's done state (ticked off in "Zadania") and persists it.
    func toggleTaskDone(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index].taskDone.toggle()
        store.updateMeta(notes[index])
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
