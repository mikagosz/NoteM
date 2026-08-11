import Foundation
import Testing
@testable import NoteM

/// The export stamp (`obsidianPath` / `obsidianExportedAt`) is the only thing the
/// crystal on a note, `meta.json` and "send all" consult — none of them look in
/// the vault. So the stamp saying "there is a copy" while the copy is gone is not
/// a cosmetic slip: nothing in the app will ever offer to send that note again.
///
/// Found by automated end-to-end testing on 2026-08-09: send → trash → restore left
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
        let note = model.createNote(content: "Trash control note")
        #expect(model.exportToObsidian(note), "The export must succeed, or the test is not testing what it claims")
        let exported = model.notes.first { $0.id == note.id }
        #expect(exported?.obsidianPath != nil)
        return exported ?? note
    }

    // MARK: 1. Manual bridge: restoring clears the stamp, because the copy stays gone

    @Test func restoreWithoutAutoExport_clearsTheStamp() throws {
        let (model, _, _) = makeModel(autoExport: false)
        let note = makeExportedNote(in: model)

        model.delete(note)          // trashing deletes the copy in the vault
        let trashed = try #require(model.trashedNotes.first { $0.id == note.id })
        model.restore(trashed)

        let restored = try #require(model.notes.first { $0.id == note.id })
        #expect(restored.obsidianPath == nil,
                "The crystal must not glow green over a file that does not exist")
        #expect(restored.obsidianExportedAt == nil)
    }

    // MARK: 2. Automatic bridge: the copy comes back, so the stamp stays

    @Test func restoreWithAutoExport_keepsTheStampBecauseTheCopyIsBack() throws {
        let (model, _, vault) = makeModel(autoExport: true)
        let note = makeExportedNote(in: model)
        let path = try #require(model.notes.first { $0.id == note.id }?.obsidianPath)

        model.delete(note)
        #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent(path).path),
                "Trashing must take the copy out of the vault")

        let trashed = try #require(model.trashedNotes.first { $0.id == note.id })
        model.restore(trashed)

        let restored = try #require(model.notes.first { $0.id == note.id })
        #expect(restored.obsidianPath != nil, "The copy is back, so the stamp tells the truth")
        #expect(FileManager.default.fileExists(atPath: vault.appendingPathComponent(path).path),
                "…and it is only true when the file really sits in the vault")
    }

    // MARK: 3. A note never sent passes through the trash unchanged

    @Test func restoreOfANeverExportedNote_changesNothing() throws {
        let (model, _, _) = makeModel(autoExport: false)
        let note = model.createNote(content: "Never sent")
        #expect(model.notes.first { $0.id == note.id }?.obsidianPath == nil)

        model.delete(note)
        let trashed = try #require(model.trashedNotes.first { $0.id == note.id })
        model.restore(trashed)

        let restored = try #require(model.notes.first { $0.id == note.id })
        #expect(restored.obsidianPath == nil)
        #expect(restored.obsidianExportedAt == nil)
    }
}
