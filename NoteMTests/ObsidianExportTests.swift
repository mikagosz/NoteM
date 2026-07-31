import Foundation
import Testing
@testable import NoteM

/// The Obsidian bridge writes into the user's own vault, next to notes NoteM did
/// not create. These lock down the two rules that keep that safe: never touch a
/// file without our `notem-id`, and never let an attachment path climb out of
/// the vault folder.
@MainActor
struct ObsidianExportTests {

    /// A throwaway vault plus a note folder to export from.
    private func makeVault() -> (vault: URL, noteFolder: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteMVaultTests-" + UUID().uuidString, isDirectory: true)
        let vault = base.appendingPathComponent("Sejf", isDirectory: true)
        let noteFolder = base.appendingPathComponent("nota", isDirectory: true)
        try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: noteFolder.appendingPathComponent("attachments", isDirectory: true),
            withIntermediateDirectories: true
        )
        return (vault, noteFolder)
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - slug

    @Test func slugStripsCharactersThatBreakFilenames() {
        #expect(ObsidianExport.slug("Raport: 2026/07 *pilny*?") == "Raport 2026 07 pilny")
        #expect(ObsidianExport.slug("a[b]c#d^e|f") == "a b c d e f")
    }

    @Test func slugFallsBackForAnEmptyTitle() {
        #expect(!ObsidianExport.slug("").isEmpty)
        #expect(!ObsidianExport.slug("   ...   ").isEmpty)
    }

    @Test func slugStaysWithinAFilenameLengthLimit() {
        #expect(ObsidianExport.slug(String(repeating: "a", count: 300)).count == 80)
    }

    // MARK: - Export

    @Test func exportWritesTheNoteWithItsFrontmatter() throws {
        let (vault, noteFolder) = makeVault()
        let note = Note(title: "Zakupy", tags: ["dom"], folderPath: "Praca/x")

        let outcome = try ObsidianExport.export(
            note: note, markdown: "- mleko", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )

        #expect(outcome.relativePath == "Praca/Zakupy.md")
        let text = read(vault.appendingPathComponent(outcome.relativePath))
        #expect(text.hasPrefix("---\n"))
        #expect(text.contains("notem-id: " + note.id.uuidString))
        #expect(text.contains("tytul: \"Zakupy\""))
        #expect(text.contains("- mleko"))
    }

    @Test func exportingTwiceReusesTheSameFile() throws {
        let (vault, noteFolder) = makeVault()
        let note = Note(title: "Zakupy", folderPath: "Praca/x")

        let first = try ObsidianExport.export(
            note: note, markdown: "wersja 1", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )
        let second = try ObsidianExport.export(
            note: note, markdown: "wersja 2", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: first.relativePath
        )

        #expect(second.relativePath == first.relativePath)
        #expect(read(vault.appendingPathComponent(second.relativePath)).contains("wersja 2"))
    }

    @Test func exportNeverOverwritesAFileWrittenInObsidian() throws {
        let (vault, noteFolder) = makeVault()
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("Praca"), withIntermediateDirectories: true
        )
        let foreign = vault.appendingPathComponent("Praca/Zakupy.md")
        try Data("moja własna notatka".utf8).write(to: foreign)

        let note = Note(title: "Zakupy", folderPath: "Praca/x")
        let outcome = try ObsidianExport.export(
            note: note, markdown: "z NoteM", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )

        #expect(outcome.relativePath != "Praca/Zakupy.md")
        #expect(read(foreign) == "moja własna notatka")
    }

    @Test func retitlingCleansUpThePreviousCopy() throws {
        let (vault, noteFolder) = makeVault()
        var note = Note(title: "Stary tytuł", folderPath: "Praca/x")

        let first = try ObsidianExport.export(
            note: note, markdown: "treść", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )
        note.title = "Nowy tytuł"
        let second = try ObsidianExport.export(
            note: note, markdown: "treść", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: first.relativePath
        )

        #expect(second.relativePath == "Praca/Nowy tytuł.md")
        #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent(first.relativePath).path))
    }

    @Test func exportFailsLoudlyWhenTheVaultFolderIsUnreachable() throws {
        let (vault, noteFolder) = makeVault()
        // A regular file exactly where the vault folder should be.
        try? FileManager.default.removeItem(at: vault)
        FileManager.default.createFile(atPath: vault.path, contents: Data())

        let note = Note(title: "Zakupy", folderPath: "Praca/x")
        #expect(throws: ObsidianExport.ExportError.self) {
            try ObsidianExport.export(
                note: note, markdown: "treść", category: "Praca",
                noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
            )
        }
    }

    @Test func anEmptyCategoryLandsInInbox() throws {
        let (vault, noteFolder) = makeVault()
        let note = Note(title: "Luzem", folderPath: "x")

        let outcome = try ObsidianExport.export(
            note: note, markdown: "treść", category: "",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )
        #expect(outcome.relativePath.hasPrefix(CategoryEngine.inbox + "/"))
    }

    // MARK: - Attachments

    @Test func attachmentsAreCopiedAndRewrittenAsVaultEmbeds() throws {
        let (vault, noteFolder) = makeVault()
        let source = noteFolder.appendingPathComponent("attachments/rysunek.png")
        try Data("obrazek".utf8).write(to: source)

        let note = Note(title: "Z obrazkiem", folderPath: "Praca/x")
        let outcome = try ObsidianExport.export(
            note: note, markdown: "![rysunek](attachments/rysunek.png)", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )

        let text = read(vault.appendingPathComponent(outcome.relativePath))
        #expect(text.contains("![[" + ObsidianExport.attachmentsDir + "/Z obrazkiem/rysunek.png]]"))
        #expect(FileManager.default.fileExists(
            atPath: vault.appendingPathComponent(ObsidianExport.attachmentsDir + "/Z obrazkiem/rysunek.png").path
        ))
    }

    @Test func anAttachmentPathCannotClimbOutOfTheVault() throws {
        let (vault, noteFolder) = makeVault()
        let note = Note(title: "Złośliwa", folderPath: "Praca/x")

        let outcome = try ObsidianExport.export(
            note: note,
            markdown: "![x](attachments/../../../../etc/passwd)\n![y](attachments/%2e%2e%2fsekret.txt)",
            category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )

        let text = read(vault.appendingPathComponent(outcome.relativePath))
        // Nothing was copied, so both links are left exactly as written.
        #expect(text.contains("![x](attachments/../../../../etc/passwd)"))
        #expect(text.contains("![y](attachments/%2e%2e%2fsekret.txt)"))
        #expect(!FileManager.default.fileExists(
            atPath: vault.appendingPathComponent(ObsidianExport.attachmentsDir).path
        ))
    }

    @Test func attachmentsNoLongerUsedAreDroppedFromTheVault() throws {
        let (vault, noteFolder) = makeVault()
        try Data("a".utf8).write(to: noteFolder.appendingPathComponent("attachments/pierwszy.png"))
        try Data("b".utf8).write(to: noteFolder.appendingPathComponent("attachments/drugi.png"))
        let note = Note(title: "Sprzątanie", folderPath: "Praca/x")

        _ = try ObsidianExport.export(
            note: note, markdown: "![a](attachments/pierwszy.png)\n![b](attachments/drugi.png)",
            category: "Praca", noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )
        // The user removed one image from the note.
        _ = try ObsidianExport.export(
            note: note, markdown: "![a](attachments/pierwszy.png)",
            category: "Praca", noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: "Praca/Sprzątanie.md"
        )

        let dir = vault.appendingPathComponent(ObsidianExport.attachmentsDir + "/Sprzątanie")
        let left = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        #expect(left.map(\.lastPathComponent) == ["pierwszy.png"])
    }

    // MARK: - removeMirror

    @Test func removeMirrorDeletesOurCopyAndItsAttachments() throws {
        let (vault, noteFolder) = makeVault()
        try Data("obrazek".utf8).write(to: noteFolder.appendingPathComponent("attachments/rysunek.png"))
        let note = Note(title: "Do usunięcia", folderPath: "Praca/x")

        let outcome = try ObsidianExport.export(
            note: note, markdown: "![r](attachments/rysunek.png)", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )
        ObsidianExport.removeMirror(relativePath: outcome.relativePath, vaultFolder: vault, noteID: note.id)

        #expect(!FileManager.default.fileExists(atPath: vault.appendingPathComponent(outcome.relativePath).path))
        #expect(!FileManager.default.fileExists(
            atPath: vault.appendingPathComponent(ObsidianExport.attachmentsDir + "/Do usunięcia").path
        ))
    }

    @Test func removeMirrorLeavesSomebodyElsesFileAlone() throws {
        let (vault, _) = makeVault()
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("Praca"), withIntermediateDirectories: true
        )
        let foreign = vault.appendingPathComponent("Praca/Cudza.md")
        try Data("nie moja notatka".utf8).write(to: foreign)

        ObsidianExport.removeMirror(relativePath: "Praca/Cudza.md", vaultFolder: vault, noteID: UUID())
        #expect(read(foreign) == "nie moja notatka")
    }

    @Test func removeMirrorLeavesACopyBelongingToAnotherNote() throws {
        let (vault, noteFolder) = makeVault()
        let mine = Note(title: "Moja", folderPath: "Praca/x")
        let outcome = try ObsidianExport.export(
            note: mine, markdown: "treść", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )

        // Same path, different note id — must not be touched.
        ObsidianExport.removeMirror(relativePath: outcome.relativePath, vaultFolder: vault, noteID: UUID())
        #expect(FileManager.default.fileExists(atPath: vault.appendingPathComponent(outcome.relativePath).path))
    }
}
