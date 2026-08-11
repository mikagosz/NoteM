import Foundation
import Testing
@testable import NoteM

/// The trash is the last place a note still exists, so the bulk actions behind
/// "select all" get the same scrutiny as the single-note ones: everything ticked
/// goes, nothing else does, and the count reported back is the truth.
///
/// > Every test here binds `temp` and ends inside `withExtendedLifetime`. That is
/// > not ceremony: `TempStore.deinit` deletes the store root, and ARC is free to
/// > release it right after its last use — which is *before* the assertions. The
/// > first version of this file dropped it into `_`, the store folder vanished
/// > mid-test, and restoring failed with "the folder is gone from the trash".
/// > Measured: the same test passes the moment the store is kept alive.
@MainActor
struct TrashBulkTests {

    /// Three notes in the trash, titled so they can be told apart.
    private func trashedTrio() -> (TempStore, NotesModel, [Note]) {
        let temp = TempStore()
        let model = NotesModel(store: temp.store)
        var notes: [Note] = []
        for title in ["pierwsza", "druga", "trzecia"] {
            notes.append(model.createNote(content: title, richData: nil, isTaskList: false))
        }
        for note in notes { model.delete(note) }
        return (temp, model, model.trashedNotes)
    }

    @Test func deletingSeveralAtOnceRemovesEveryOneOfThem() {
        let (temp, model, trashed) = trashedTrio()
        withExtendedLifetime(temp) {
            #expect(trashed.count == 3)

            let removed = model.deletePermanently(trashed)

            #expect(removed == 3)
            #expect(model.trashedNotes.isEmpty)
            #expect(model.notes.isEmpty)
        }
    }

    /// The case that matters for a "select some" batch: the ones not ticked stay.
    @Test func onlyTheGivenNotesGo() throws {
        let (temp, model, trashed) = trashedTrio()
        try withExtendedLifetime(temp) {
            let doomed = Array(trashed.prefix(2))
            let spared = try #require(trashed.last)

            let removed = model.deletePermanently(doomed)

            #expect(removed == 2)
            #expect(model.trashedNotes.count == 1)
            #expect(model.trashedNotes.first?.id == spared.id)
        }
    }

    @Test func deletingAnEmptySelectionChangesNothing() {
        let (temp, model, trashed) = trashedTrio()
        withExtendedLifetime(temp) {
            let removed = model.deletePermanently([])

            #expect(removed == 0)
            #expect(model.trashedNotes.count == trashed.count)
        }
    }

    @Test func restoringSeveralAtOncePutsThemAllBackOnTheList() {
        let (temp, model, trashed) = trashedTrio()
        withExtendedLifetime(temp) {
            model.restore(trashed)

            #expect(model.trashedNotes.isEmpty)
            #expect(model.notes.count == 3)
            #expect(model.storeError == nil)
        }
    }

    /// The files really have to go — a note that vanished from the list but stayed
    /// on disk would come back on the next reload, which is the opposite of what
    /// "delete permanently" promises.
    @Test func theFilesAreGoneFromDiskToo() {
        let (temp, model, trashed) = trashedTrio()
        withExtendedLifetime(temp) {
            model.deletePermanently(trashed)

            let reloaded = NotesModel(store: temp.store)
            #expect(reloaded.trashedNotes.isEmpty)
            #expect(reloaded.notes.isEmpty)
        }
    }

    /// The reported count has to be the truth, not the size of the batch handed in.
    ///
    /// The trash folder is made read-only, so the note folders are still there and
    /// `removeItem` fails on every one of them. A note that is still on disk has to
    /// stay in the trash — telling the user "3 deleted" while all three are lying
    /// there is how a list and a disk drift apart.
    ///
    /// Not `blockRoot()`: that removes the whole store, and then "deleted" is
    /// simply true — measured, the first version of this test asserted the wrong
    /// thing and failed for the right reason.
    @Test func aFailedRemovalIsNotCountedAsDeleted() {
        let (temp, model, trashed) = trashedTrio()
        withExtendedLifetime(temp) {
            let fileManager = FileManager.default
            let trashDir = temp.root.appendingPathComponent(".trash")
            try? fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: trashDir.path)
            defer {
                try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: trashDir.path)
            }
            // Control: the folders really are still on disk, so this measures a
            // refused removal and not a store that quietly disappeared.
            #expect(fileManager.fileExists(atPath: temp.root.appendingPathComponent(trashed[0].folderPath).path))

            let removed = model.deletePermanently(trashed)

            #expect(removed == 0)
            #expect(model.trashedNotes.count == 3)
        }
    }

    /// Control sample for the test above: without the deletion the same reload
    /// finds all three, so "empty" up there is the deletion's doing and not the
    /// reload simply looking in the wrong place.
    @Test func withoutTheDeletionTheSameReloadStillFindsThem() {
        let (temp, model, _) = trashedTrio()
        withExtendedLifetime(temp) {
            let reloaded = NotesModel(store: temp.store)
            #expect(reloaded.trashedNotes.count == 3)
        }
    }
}
