import Foundation
import Testing
@testable import NoteM

/// `NoteStore` is where a bug costs the user their text, so these cover both the
/// happy path and — the point of the exercise — that a write which doesn't reach
/// the disk says so instead of failing silently.
@MainActor
struct NoteStoreTests {

    // MARK: - Create & save

    @Test func createNoteWritesFolderAndIsFoundAgain() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Pierwsza")

        #expect(temp.exists(note.folderPath + "/note.md"))
        #expect(temp.exists(note.folderPath + "/meta.json"))
        #expect(temp.store.loadAllNotes().map(\.id) == [note.id])
        #expect(temp.errors.isEmpty)
    }

    @Test func newNotesStartInInbox() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Pierwsza")
        #expect(note.folderPath.hasPrefix(CategoryEngine.inbox + "/"))
    }

    /// The folder name is precise to the second, so two notes made in the same
    /// second used to land in one folder and the second overwrote the first.
    @Test func notesCreatedInTheSameSecondGetTheirOwnFolders() {
        let temp = TempStore()
        let first = temp.store.createNote(title: "Pierwsza")
        let second = temp.store.createNote(title: "Druga")

        #expect(first.folderPath != second.folderPath)
        #expect(Set(temp.store.loadAllNotes().map(\.id)) == [first.id, second.id])
        #expect(Set(temp.store.loadAllNotes().map(\.title)) == ["Pierwsza", "Druga"])
    }

    @Test func saveRoundTripsContent() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Notatka")

        let saved = temp.store.saveNote(note, content: "Treść notatki\nDruga linia")
        #expect(saved != nil)
        #expect(temp.store.loadContent(for: note) == "Treść notatki\nDruga linia")
        #expect(temp.errors.isEmpty)
    }

    @Test func saveBumpsModified() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Notatka")
        let saved = temp.store.saveNote(note, content: "x")
        #expect((saved?.modified ?? .distantPast) >= note.modified)
    }

    @Test func saveWritesAndClearsTheRichArchive() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Notatka")

        temp.store.saveNote(note, content: "x", richData: Data("rich".utf8))
        #expect(temp.store.loadRichData(for: note) == Data("rich".utf8))

        // A markdown-only save drops the stale archive so display falls back to md.
        temp.store.saveNote(note, content: "x", richData: nil)
        #expect(temp.store.loadRichData(for: note) == nil)
        #expect(temp.errors.isEmpty)
    }

    @Test func secondSaveLeavesAHistorySnapshot() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Notatka")
        temp.store.saveNote(note, content: "wersja pierwsza")
        temp.store.saveNote(note, content: "wersja druga")

        let historyDir = temp.url(NoteStore.historyDir + "/" + note.id.uuidString)
        let snapshots = (try? FileManager.default.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: nil)) ?? []
        #expect(snapshots.contains { $0.pathExtension == "md" })
    }

    // MARK: - Failures are reported, not swallowed

    @Test func saveReportsAndRefusesWhenTheDiskWontTakeIt() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Notatka")
        temp.blockRoot()

        #expect(temp.store.saveNote(note, content: "tego nie da się zapisać") == nil)
        #expect(!temp.errors.isEmpty)
    }

    @Test func trashReportsAndRefusesWhenTheFolderIsAlreadyGone() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Notatka")
        try? FileManager.default.removeItem(at: temp.url(note.folderPath))

        #expect(temp.store.trashNote(note) == nil)
        #expect(!temp.errors.isEmpty)
    }

    @Test func addAttachmentReportsAndReturnsNilForAMissingSource() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Notatka")
        let missing = temp.root.appendingPathComponent("nie-ma-mnie.png")

        #expect(temp.store.addAttachment(fileURL: missing, toNote: note) == nil)
        #expect(!temp.errors.isEmpty)
    }

    @Test func updateMetaReportsFailure() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Notatka")
        temp.blockRoot()

        #expect(temp.store.updateMeta(note) == false)
        #expect(!temp.errors.isEmpty)
    }

    // MARK: - Trash

    @Test func trashMovesTheFolderAndKeepsItsOrigin() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Do kosza")
        let original = note.folderPath

        let trashed = temp.store.trashNote(note)
        #expect(trashed?.folderPath == NoteStore.trashDir + "/" + note.id.uuidString)
        #expect(trashed?.originalFolderPath == original)
        #expect(trashed?.deletedAt != nil)
        #expect(!temp.exists(original))
        #expect(temp.store.loadAllNotes().isEmpty)
        #expect(temp.store.loadTrashedNotes().map(\.id) == [note.id])
    }

    @Test func restorePutsTheNoteBackWhereItCameFrom() throws {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Wraca")
        temp.store.saveNote(note, content: "treść")
        let trashed = try #require(temp.store.trashNote(note))

        let restored = try #require(temp.store.restoreNote(trashed))
        #expect(restored.folderPath == note.folderPath)
        #expect(restored.deletedAt == nil)
        #expect(restored.originalFolderPath == nil)
        #expect(temp.store.loadContent(for: restored) == "treść")
        #expect(temp.store.loadTrashedNotes().isEmpty)
    }

    @Test func restoreSidestepsAFolderThatIsOccupiedNow() throws {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Wraca")
        let trashed = try #require(temp.store.trashNote(note))
        // Something else took the old spot while the note sat in the trash.
        try FileManager.default.createDirectory(at: temp.url(note.folderPath), withIntermediateDirectories: true)

        let restored = try #require(temp.store.restoreNote(trashed))
        #expect(restored.folderPath != note.folderPath)
        #expect(restored.folderPath.hasPrefix(note.folderPath))
    }

    @Test func emptyTrashOnlyDropsWhatIsOlderThanTheWindow() throws {
        let temp = TempStore()
        let old = temp.store.createNote(title: "Stara")
        let fresh = temp.store.createNote(title: "Świeża")
        var oldTrashed = try #require(temp.store.trashNote(old))
        let freshTrashed = try #require(temp.store.trashNote(fresh))

        // Backdate the old one past the retention window.
        oldTrashed.deletedAt = Date().addingTimeInterval(-40 * 86_400)
        temp.store.updateMeta(oldTrashed)

        temp.store.emptyTrash(olderThanDays: 30)
        #expect(temp.store.loadTrashedNotes().map(\.id) == [freshTrashed.id])
    }

    @Test func deleteIsIdempotent() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Znika")

        #expect(temp.store.deleteNote(note) == true)
        #expect(!temp.exists(note.folderPath))
        // Already gone is the caller's goal met — not a failure to report.
        #expect(temp.store.deleteNote(note) == true)
        #expect(temp.errors.isEmpty)
    }

    @Test func trashedNotesStayOutOfTheMainList() throws {
        let temp = TempStore()
        let kept = temp.store.createNote(title: "Zostaje")
        let gone = temp.store.createNote(title: "Do kosza")
        _ = try #require(temp.store.trashNote(gone))

        #expect(temp.store.loadAllNotes().map(\.id) == [kept.id])
    }

    // MARK: - Move & metadata

    @Test func moveRelocatesTheFolder() throws {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Przenoszona")
        temp.store.saveNote(note, content: "treść")

        let moved = try #require(temp.store.moveNote(note, toFolderPath: "Praca/2026-01-01"))
        #expect(moved.folderPath == "Praca/2026-01-01")
        #expect(temp.store.loadContent(for: moved) == "treść")
        #expect(!temp.exists(note.folderPath))
    }

    @Test func moveDisambiguatesAnOccupiedDestination() throws {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Przenoszona")
        try FileManager.default.createDirectory(at: temp.url("Praca/zajete"), withIntermediateDirectories: true)

        let moved = try #require(temp.store.moveNote(note, toFolderPath: "Praca/zajete"))
        #expect(moved.folderPath != "Praca/zajete")
        #expect(moved.folderPath.hasPrefix("Praca/zajete-"))
    }

    @Test func moveReturnsNilForANoteThatIsNotOnDisk() {
        let temp = TempStore()
        let phantom = Note(title: "Widmo", folderPath: "Inbox/nie-ma-mnie")
        #expect(temp.store.moveNote(phantom, toFolderPath: "Praca/x") == nil)
    }

    @Test func updateMetaPersistsTagsWithoutTouchingContent() throws {
        let temp = TempStore()
        var note = temp.store.createNote(title: "Otagowana")
        temp.store.saveNote(note, content: "treść")

        note.tags = ["praca", "pilne"]
        #expect(temp.store.updateMeta(note) == true)

        let reloaded = try #require(temp.store.loadAllNotes().first)
        #expect(reloaded.tags == ["praca", "pilne"])
        #expect(temp.store.loadContent(for: reloaded) == "treść")
    }

    @Test func categoryCoverColourRoundTrips() {
        let temp = TempStore()
        #expect(temp.store.setCategoryColorID("ocean", forCategory: "Praca") == true)
        #expect(temp.store.categoryColorID(forCategory: "Praca") == "ocean")

        temp.store.setCategoryColorID(nil, forCategory: "Praca")
        #expect(temp.store.categoryColorID(forCategory: "Praca") == nil)
    }

    // MARK: - Attachments

    @Test func attachmentIsCopiedInAndListed() throws {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Z załącznikiem")
        let source = temp.makeSourceFile(named: "zdjecie.png")

        let name = try #require(temp.store.addAttachment(fileURL: source, toNote: note))
        #expect(name == "zdjecie.png")
        #expect(temp.exists(note.folderPath + "/attachments/zdjecie.png"))
        #expect(temp.store.attachmentFilenames(for: note) == ["zdjecie.png"])
        // The original is a copy source, not a move source.
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func attachmentWithATakenNameGetsASuffix() throws {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Z załącznikami")
        temp.store.addAttachment(fileURL: temp.makeSourceFile(named: "plik.txt"), toNote: note)

        let second = try #require(temp.store.addAttachment(fileURL: temp.makeSourceFile(named: "plik.txt"), toNote: note))
        #expect(second == "plik-1.txt")
        #expect(temp.store.attachmentFilenames(for: note) == ["plik-1.txt", "plik.txt"])
    }

    @Test func pruneKeepsOnlyReferencedAttachments() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Sprzątanie")
        temp.store.addAttachment(fileURL: temp.makeSourceFile(named: "zostaje.png"), toNote: note)
        temp.store.addAttachment(fileURL: temp.makeSourceFile(named: "znika.png"), toNote: note)

        temp.store.pruneAttachments(for: note, keeping: ["zostaje.png"])
        #expect(temp.store.attachmentFilenames(for: note) == ["zostaje.png"])
        #expect(temp.errors.isEmpty)
    }

    // MARK: - Manifest

    @Test func manifestAdvancesAfterAWrite() throws {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Notatka")
        let first = try #require(temp.store.readManifestDate())

        temp.store.saveNote(note, content: "zmiana")
        let second = try #require(temp.store.readManifestDate())
        #expect(second >= first)
    }
}
