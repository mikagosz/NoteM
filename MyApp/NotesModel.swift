import Foundation
import Observation

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

    /// Persists `content` for `note`, deriving the title from the first line.
    ///
    /// No-op if the note is no longer in the list (e.g. it was just deleted) —
    /// this prevents a trailing autosave from recreating a deleted note.
    func save(_ note: Note, content: String) {
        guard notes.contains(where: { $0.id == note.id }) else { return }

        var updated = note
        updated.title = Self.deriveTitle(from: content)
        let saved = store.saveNote(updated, content: content)

        if let index = notes.firstIndex(where: { $0.id == saved.id }) {
            notes[index] = saved
        }
        notes.sort { $0.modified > $1.modified }
    }

    /// Derives a display title from the first non-empty line of the content,
    /// stripping leading markdown markers (headers, list bullets) and emphasis.
    private static func deriveTitle(from content: String) -> String {
        var line = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""

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
