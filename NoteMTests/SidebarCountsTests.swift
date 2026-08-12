import Foundation
import Testing
@testable import NoteM

/// Sidebar badges and the Start page's preview cache, both of which used to be
/// computed the expensive or the wrong way (E3-P3-03, E3-P3-02).
@MainActor
struct SidebarCountsTests {

    private func note(title: String, folderPath: String, modified: Date = Date()) -> Note {
        Note(title: title, tags: [], modified: modified, folderPath: folderPath)
    }

    @Test func categoryCountsAreCountedOncePerFolder() {
        let temp = TempStore()
        let model = NotesModel(store: temp.store)
        for (index, folder) in [("a", "Praca"), ("b", "Praca"), ("c", "Inbox")].enumerated().map({ ($0.offset, $0.element.1) }) {
            let created = temp.store.createNote(title: "nota-\(index)")
            _ = temp.store.moveNote(created, toFolderPath: "\(folder)/2026-01-0\(index + 1)_10-00-00")
        }
        model.reload()

        let counts = model.categoryCounts
        #expect(counts["Praca"] == 2)
        #expect(counts["Inbox"] == 1)
        #expect(counts["Nie ma takiego"] == nil)
    }

    @Test func categoryCountsOfAnEmptyStoreAreEmpty() {
        let temp = TempStore()
        let model = NotesModel(store: temp.store)
        #expect(model.categoryCounts.isEmpty)
    }

    /// The Start page rebuilt its previews on `notes.count`, so editing a note
    /// left the old snippet on screen. The stamp has to move when only the
    /// modification date does.
    @Test func theChangeStampMovesWhenANoteIsEditedWithoutChangingTheCount() {
        let first = Date(timeIntervalSince1970: 1_000_000)
        let notes = [note(title: "a", folderPath: "Inbox/1", modified: first),
                     note(title: "b", folderPath: "Inbox/2", modified: first)]
        let before = notes.changeStamp

        var edited = notes
        edited[0].modified = first.addingTimeInterval(60)

        #expect(edited.count == notes.count)
        #expect(edited.changeStamp != before)
    }

    @Test func theChangeStampIsStableWhenNothingChanges() {
        let notes = [note(title: "a", folderPath: "Inbox/1", modified: Date(timeIntervalSince1970: 5)),
                     note(title: "b", folderPath: "Inbox/2", modified: Date(timeIntervalSince1970: 6))]
        #expect(notes.changeStamp == notes.changeStamp)
    }

    @Test func theChangeStampMovesWhenANoteIsAddedOrRemoved() {
        let notes = [note(title: "a", folderPath: "Inbox/1")]
        let plusOne = notes + [note(title: "b", folderPath: "Inbox/2")]
        #expect(plusOne.changeStamp != notes.changeStamp)
        #expect([Note]().changeStamp != notes.changeStamp)
    }
}
