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
    private let store = NoteStore()

    /// Notes currently known to the UI, sorted by `modified` descending.
    private(set) var notes: [Note] = []

    /// Supplies the current auto-filing rules at save time. Set by the UI from
    /// `AppSettings`; defaults to no rules.
    var rulesProvider: () -> [CategoryRule] = { [] }

    init() {
        reload()
    }

    /// Reloads all notes from disk.
    func reload() {
        notes = store.loadAllNotes().sorted { $0.modified > $1.modified }
    }

    /// Creates a new empty note and inserts it at the top of the list.
    @discardableResult
    func createNote() -> Note {
        let note = store.createNote(title: "Nowa notatka")
        notes.insert(note, at: 0)
        return note
    }

    /// Deletes a note from disk and from the list.
    func delete(_ note: Note) {
        store.deleteNote(note)
        notes.removeAll { $0.id == note.id }
    }

    /// Current on-disk content of a note.
    func content(for note: Note) -> String {
        store.loadContent(for: note)
    }

    // MARK: - Collected tasks

    /// All unchecked checklist items (`- [ ]`) across every note, for the
    /// "Zadania" view. Order follows the notes list, then line order.
    func openTasks() -> [TaskItem] {
        var items: [TaskItem] = []
        for note in notes {
            let lines = store.loadContent(for: note).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = String(line.drop(while: { $0 == " " || $0 == "\t" }))
                guard let (checked, body) = MarkdownStyler.parseChecklist(trimmed), !checked else { continue }
                let text = MarkdownStyler.plainText(fromInline: body).trimmingCharacters(in: .whitespaces)
                items.append(TaskItem(noteID: note.id, noteTitle: note.title, lineIndex: index, text: text))
            }
        }
        return items
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
    func save(_ note: Note, content: String) {
        // Use the model's own copy for the authoritative folder path: the note
        // may have been moved by the categorization engine since the editor
        // loaded it, so the caller's `folderPath` can be stale.
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }

        var current = notes[index]
        current.title = Self.deriveTitle(from: content)
        var saved = store.saveNote(current, content: content)

        // Auto-file into a category folder based on the rules (first match wins).
        if let newFolderPath = CategoryEngine.targetFolderPath(
            content: content,
            currentFolderPath: saved.folderPath,
            rules: rulesProvider()
        ) {
            saved = store.moveNote(saved, toFolderPath: newFolderPath)
        }

        notes[index] = saved
        notes.sort { $0.modified > $1.modified }
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
        return line.isEmpty ? "Nowa notatka" : String(line.prefix(60))
    }
}
