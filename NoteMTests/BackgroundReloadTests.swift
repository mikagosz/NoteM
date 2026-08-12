import Foundation
import Testing
@testable import NoteM

/// The first read of the store used to happen inside `NotesModel.init`, on the
/// main thread, while the first window was being built — measured at ~0,29 s for
/// 500 notes (second half of P2-05). It now runs on a background thread, and the
/// only thing that makes that safe is that the two paths produce the same notes.
@MainActor
struct BackgroundReloadTests {

    private func makeNotes(_ count: Int, in temp: TempStore) -> [Note] {
        (0..<count).map { index in
            let note = temp.store.createNote(title: "Notatka \(index)")
            _ = temp.store.saveNote(note, content: "Treść notatki numer \(index)")
            return note
        }
    }

    @Test func aModelBuiltWithoutLoadingIsEmptyUntilItLoads() async {
        let temp = TempStore()
        _ = makeNotes(3, in: temp)

        let model = NotesModel(store: temp.store, loadNow: false)
        #expect(model.notes.isEmpty)

        await model.reloadInBackground()
        #expect(model.notes.count == 3)
    }

    @Test func theBackgroundReadSeesExactlyWhatTheSynchronousOneSees() async {
        let temp = TempStore()
        _ = makeNotes(5, in: temp)

        let synchronous = NotesModel(store: temp.store)
        let background = NotesModel(store: temp.store, loadNow: false)
        await background.reloadInBackground()

        // Sets, not arrays: `meta.json` keeps `modified` to the second, so five
        // notes saved inside one second are a tie and the sort may order the tie
        // either way. What has to match is *which* notes came back.
        #expect(Set(background.notes.map(\.id)) == Set(synchronous.notes.map(\.id)))
        #expect(Set(background.notes.map(\.folderPath)) == Set(synchronous.notes.map(\.folderPath)))
        #expect(Set(background.notes.map(\.title)) == Set(synchronous.notes.map(\.title)))
        #expect(background.notes.count == synchronous.notes.count)
    }

    /// The trash is loaded by the same background pass — it used to be a second
    /// disk walk fired from the middle of the main-thread reload.
    @Test func trashedNotesComeBackFromTheBackgroundReadToo() async {
        let temp = TempStore()
        let notes = makeNotes(2, in: temp)
        _ = temp.store.trashNote(notes[0])

        let model = NotesModel(store: temp.store, loadNow: false)
        await model.reloadInBackground()

        #expect(model.notes.count == 1)
        #expect(model.trashedNotes.count == 1)
        #expect(model.trashedNotes[0].id == notes[0].id)
    }

    /// Reading the store is now `nonisolated`, i.e. callable from a background
    /// thread. This asserts it actually runs off the main thread rather than
    /// hopping back onto it, which would leave the original problem in place.
    @Test func theReadItselfRunsOffTheMainThread() async {
        let temp = TempStore()
        _ = makeNotes(2, in: temp)
        let root = temp.root

        // `pthread_main_np()` rather than `Thread.isMainThread`: the latter is
        // unavailable from an asynchronous context, which is exactly where the
        // read now happens.
        let wasMainThread = await Task.detached { () -> Bool in
            _ = NoteStore.readAllNotes(root: root)
            return pthread_main_np() != 0
        }.value
        #expect(wasMainThread == false)
    }

    /// The measurement the audit asked for before this change: how much of the
    /// start-up read is walking the tree and decoding `meta.json`, and how much is
    /// reading the note bodies. Printed rather than asserted — a timing threshold
    /// in a test suite fails on a busy machine, which teaches people to ignore it.
    @Test func measureWhereTheStartupReadGoes() {
        let temp = TempStore()
        let count = 500
        let notes = makeNotes(count, in: temp)

        let root = temp.root
        var start = Date()
        let scanned = NoteStore.readAllNotes(root: root)
        let scanSeconds = Date().timeIntervalSince(start)

        start = Date()
        for note in notes { _ = temp.store.loadContent(for: note) }
        let contentSeconds = Date().timeIntervalSince(start)

        let report = """
        P2-05 pomiar na \(count) notatkach:
          skan drzewa + meta.json : \(String(format: "%.3f", scanSeconds)) s
          odczyt treści (note.md) : \(String(format: "%.3f", contentSeconds)) s
        """
        // Written to a file as well as printed: `xcodebuild` swallows the test
        // bundle's stdout, and a measurement nobody can read is not a measurement.
        print(report)
        try? Data(report.utf8).write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteM-pomiar-P2-05.txt"))
        #expect(scanned.count == count)
    }
}
