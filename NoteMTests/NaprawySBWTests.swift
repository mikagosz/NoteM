import Foundation
import Testing
@testable import NoteM

/// Naprawy po audycie SBW 2026-09-23 (NoteM 1.1.1) — warstwa danych.
@MainActor
struct NaprawySBWTests {

    /// E1-S-P1-01. `note.rich` jako katalog: zapis `.atomic` rzuca, więc nowego
    /// archiwum nie da się zapisać. Do 1.1.0 `saveNote` oddawał notatkę jak po
    /// sukcesie, a `loadRichData` — stare dane, czyli treść sprzed zapisu.
    @Test func aFailedRichWriteDoesNotLeaveTheOldArchiveBehind() throws {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Pełny dysk")
        let folder = temp.store.folderURL(for: note)
        let rich = folder.appendingPathComponent("note.rich")
        try? FileManager.default.removeItem(at: rich)
        try FileManager.default.createDirectory(at: rich, withIntermediateDirectories: true)
        try Data("stare archiwum".utf8).write(to: rich.appendingPathComponent("w-srodku"))

        let saved = temp.store.saveNote(note, content: "nowa treść", richData: Data("nowe archiwum".utf8))

        // Stare archiwum zniknęło, więc wyświetlanie spada na aktualny note.md.
        #expect(saved != nil)
        #expect(temp.store.loadRichData(for: saved ?? note) == nil)
        #expect(temp.store.loadContent(for: saved ?? note) == "nowa treść")
    }

    /// Kontrola dodatnia: zwykły zapis dalej zapisuje archiwum.
    @Test func aNormalSaveStillWritesTheArchive() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Zwykła")
        let saved = temp.store.saveNote(note, content: "treść", richData: Data("archiwum".utf8))
        #expect(saved != nil)
        #expect(temp.store.loadRichData(for: saved ?? note) == Data("archiwum".utf8))
    }

    /// E1-S-P2-01. `meta.json` nie do odczytania — notatki nie ma na liście, ale
    /// odczyt podaje jej folder, żeby model mógł o niej powiedzieć.
    @Test func anUnreadableMetaIsReportedNotSilentlyDropped() throws {
        let temp = TempStore()
        let good = temp.store.createNote(title: "Dobra")
        let bad = temp.store.createNote(title: "Zepsuta")
        try Data("{ nie json".utf8).write(to: temp.store.folderURL(for: bad).appendingPathComponent("meta.json"))

        let wynik = temp.store.loadAllNotesReportingUnreadable()
        #expect(wynik.notes.map(\.id) == [good.id])
        #expect(wynik.unreadable == [bad.folderPath])
    }

    /// E1-S-P3-01. Wersja z konfliktu idzie do kosza jako osobna notatka (nowe id),
    /// a nie jest kasowana trwale.
    @Test func aLosingConflictVersionGoesToTheTrashUnderAFreshID() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Konflikt")
        let trashed = temp.store.trashConflictVersion(note)

        #expect(trashed != nil)
        #expect(trashed?.id != note.id)
        #expect(temp.store.loadTrashedNotes().contains { $0.id == trashed?.id })
        #expect(temp.store.loadAllNotes().isEmpty)
    }
}
