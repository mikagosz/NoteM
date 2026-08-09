import Foundation
import Testing
@testable import NoteM

/// The export stamp (`obsidianPath` / `obsidianExportedAt`) is the only thing the
/// crystal on a note, `meta.json` and "send all" consult — none of them look in
/// the vault. So the stamp saying "there is a copy" while the copy is gone is not
/// a cosmetic slip: nothing in the app will ever offer to send that note again.
///
/// Found through the AppBridge bridge on 2026-08-09: send → trash → restore left
/// a green crystal over an empty vault.
@MainActor
struct NotesModelObsidianStampTests {

    /// A model on a throwaway store, plus a throwaway vault folder.
    private func makeModel(autoExport: Bool) -> (model: NotesModel, temp: TempStore, vault: URL) {
        let temp = TempStore()
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteMStampTests-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)

        let model = NotesModel(store: temp.store)
        model.obsidianConfigProvider = { (autoExport, vault) }
        return (model, temp, vault)
    }

    /// A note that already lives in the vault.
    private func makeExportedNote(in model: NotesModel) -> Note {
        let note = model.createNote(content: "Próba kontrolna kosza")
        #expect(model.exportToObsidian(note), "Eksport musi się udać, inaczej test nie bada tego, co miał")
        let exported = model.notes.first { $0.id == note.id }
        #expect(exported?.obsidianPath != nil)
        return exported ?? note
    }

    // MARK: 1. Ręczny mostek: przywrócenie zdejmuje znacznik, bo kopia nie wraca

    @Test func restoreWithoutAutoExport_clearsTheStamp() throws {
        let (model, _, _) = makeModel(autoExport: false)
        let note = makeExportedNote(in: model)

        model.delete(note)          // kosz kasuje kopię w sejfie
        let trashed = try #require(model.trashedNotes.first { $0.id == note.id })
        model.restore(trashed)

        let restored = try #require(model.notes.first { $0.id == note.id })
        #expect(restored.obsidianPath == nil,
                "Kryształ nie może świecić na zielono nad plikiem, którego nie ma")
        #expect(restored.obsidianExportedAt == nil)
    }

    // MARK: 2. Automatyczny mostek: kopia wraca, więc znacznik zostaje

    @Test func restoreWithAutoExport_keepsTheStampBecauseTheCopyIsBack() throws {
        let (model, _, vault) = makeModel(autoExport: true)
        let note = makeExportedNote(in: model)
        let path = try #require(model.notes.first { $0.id == note.id }?.obsidianPath)

        model.delete(note)
        #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent(path).path),
                "Kosz ma zabrać kopię z sejfu")

        let trashed = try #require(model.trashedNotes.first { $0.id == note.id })
        model.restore(trashed)

        let restored = try #require(model.notes.first { $0.id == note.id })
        #expect(restored.obsidianPath != nil, "Kopia wróciła, więc znacznik jest prawdą")
        #expect(FileManager.default.fileExists(atPath: vault.appendingPathComponent(path).path),
                "…a prawdą jest tylko wtedy, gdy plik faktycznie leży w sejfie")
    }

    // MARK: 3. Nigdy niewysłana notatka przechodzi kosz bez zmian

    @Test func restoreOfANeverExportedNote_changesNothing() throws {
        let (model, _, _) = makeModel(autoExport: false)
        let note = model.createNote(content: "Nigdy niewysłana")
        #expect(model.notes.first { $0.id == note.id }?.obsidianPath == nil)

        model.delete(note)
        let trashed = try #require(model.trashedNotes.first { $0.id == note.id })
        model.restore(trashed)

        let restored = try #require(model.notes.first { $0.id == note.id })
        #expect(restored.obsidianPath == nil)
        #expect(restored.obsidianExportedAt == nil)
    }
}
