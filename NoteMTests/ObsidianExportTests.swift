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

    /// Obsidian only reads `tags:` (or `tag:`); under any other key the tags are
    /// invisible to the tag pane, to `tag:` searches and to the graph.
    @Test func frontmatterUsesTheTagKeyObsidianUnderstands() throws {
        let (vault, noteFolder) = makeVault()
        let note = Note(title: "Zakupy", tags: ["dom", "pilne"], folderPath: "Praca/x")

        let outcome = try ObsidianExport.export(
            note: note, markdown: "- mleko", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )

        let text = read(vault.appendingPathComponent(outcome.relativePath))
        #expect(text.contains("\ntags: [\"dom\", \"pilne\"]\n"))
        #expect(!text.contains("tagi:"))
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

    /// The same rule, one step further in. When the plain title is taken, the
    /// export falls back to `<title>-<id fragment>.md` — and that name used to be
    /// returned without asking who owns it, so a file the user happened to name
    /// that way would be overwritten. The invariant has no "unlikely" clause.
    @Test func exportDoesNotOverwriteAForeignFileSittingOnTheSuffixedName() throws {
        let (vault, noteFolder) = makeVault()
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("Praca"), withIntermediateDirectories: true
        )
        let note = Note(title: "Zakupy", folderPath: "Praca/x")
        let suffix = note.id.uuidString.prefix(8).lowercased()

        // Both the plain name and the suffixed one are taken by somebody else.
        let plain = vault.appendingPathComponent("Praca/Zakupy.md")
        let suffixed = vault.appendingPathComponent("Praca/Zakupy-\(suffix).md")
        try Data("cudza pierwsza".utf8).write(to: plain)
        try Data("cudza druga".utf8).write(to: suffixed)

        let outcome = try ObsidianExport.export(
            note: note, markdown: "z NoteM", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )

        #expect(outcome.relativePath != "Praca/Zakupy.md")
        #expect(outcome.relativePath != "Praca/Zakupy-\(suffix).md")
        #expect(read(plain) == "cudza pierwsza")
        #expect(read(suffixed) == "cudza druga")
        // …and the note did land somewhere, rather than being dropped.
        #expect(read(vault.appendingPathComponent(outcome.relativePath)).contains("z NoteM"))
    }

    /// A second export of the same note must reuse its own file rather than pile
    /// up numbered copies — the ownership check is what makes the suffixed name
    /// stable, and counting past a name we own would break that.
    @Test func theSuffixedNameIsReusedByItsOwnNote() throws {
        let (vault, noteFolder) = makeVault()
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("Praca"), withIntermediateDirectories: true
        )
        try Data("cudza".utf8).write(to: vault.appendingPathComponent("Praca/Zakupy.md"))

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

        let first = try ObsidianExport.export(
            note: note, markdown: "![a](attachments/pierwszy.png)\n![b](attachments/drugi.png)",
            category: "Praca", noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )
        // The user removed one image from the note.
        _ = try ObsidianExport.export(
            note: note, markdown: "![a](attachments/pierwszy.png)",
            category: "Praca", noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: "Praca/Sprzątanie.md",
            previousAttachments: first.attachments
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
        ObsidianExport.removeMirror(relativePath: outcome.relativePath, vaultFolder: vault, noteID: note.id,
                                    ownedAttachments: outcome.attachments)

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

    /// Deleting a note used to take the whole `Zalaczniki/<nazwa>` folder with
    /// it, name match and nothing else. Files the user put there themselves have
    /// to survive — only what our own copy embedded goes.
    @Test func removeMirrorKeepsFilesItDidNotPutThere() throws {
        let (vault, noteFolder) = makeVault()
        try Data("obrazek".utf8).write(to: noteFolder.appendingPathComponent("attachments/rysunek.png"))
        let note = Note(title: "Do usunięcia", folderPath: "Praca/x")

        let outcome = try ObsidianExport.export(
            note: note, markdown: "![r](attachments/rysunek.png)", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )

        // Something NoteM did not put there, in the same folder.
        let folder = vault.appendingPathComponent(ObsidianExport.attachmentsDir + "/Do usunięcia")
        let foreign = folder.appendingPathComponent("moje-zdjecie.png")
        try Data("cudze".utf8).write(to: foreign)

        ObsidianExport.removeMirror(relativePath: outcome.relativePath, vaultFolder: vault, noteID: note.id,
                                    ownedAttachments: outcome.attachments)

        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("rysunek.png").path))
        #expect(read(foreign) == "cudze")
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

    // MARK: - Audyt SBW 2026-09-23, E1-S-P1-02: lustro kasuje tylko swoje

    /// (a) Folder w sejfie o nazwie notatki, a w nim plik użytkownika. Do 1.1.0
    /// eksport kasował wszystko, czego sam nie skopiował — także przy notatce bez
    /// załączników.
    @Test func exportLeavesTheUsersFileInAFolderNamedLikeTheNote() throws {
        let (vault, noteFolder) = makeVault()
        let folder = vault.appendingPathComponent(ObsidianExport.attachmentsDir + "/Faktury")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let users = folder.appendingPathComponent("skan.pdf")
        try Data("moje".utf8).write(to: users)
        let note = Note(title: "Faktury", folderPath: "Praca/x")

        let first = try ObsidianExport.export(
            note: note, markdown: "bez załączników", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )
        _ = try ObsidianExport.export(
            note: note, markdown: "dalej bez", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: first.relativePath,
            previousAttachments: first.attachments
        )
        #expect(read(users) == "moje")
    }

    /// (b) Osadzenie dopisane ręcznie w kopii w Obsidianie nie wchodzi na listę.
    @Test func removeMirrorIgnoresEmbedsAddedInObsidian() throws {
        let (vault, noteFolder) = makeVault()
        let note = Note(title: "Edytowana", folderPath: "Praca/x")
        let outcome = try ObsidianExport.export(
            note: note, markdown: "treść", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )
        let other = vault.appendingPathComponent(ObsidianExport.attachmentsDir + "/Inne/zdjecie.png")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("cudze".utf8).write(to: other)
        let copy = vault.appendingPathComponent(outcome.relativePath)
        try (read(copy) + "\n![[" + ObsidianExport.attachmentsDir + "/Inne/zdjecie.png]]\n").write(to: copy, atomically: true, encoding: .utf8)

        ObsidianExport.removeMirror(relativePath: outcome.relativePath, vaultFolder: vault, noteID: note.id,
                                    ownedAttachments: outcome.attachments)
        #expect(!FileManager.default.fileExists(atPath: copy.path), "kontrola: kopia notatki ma zniknąć")
        #expect(read(other) == "cudze")
    }

    /// (c) Plik użytkownika o tej samej nazwie co załącznik nie jest nadpisywany.
    @Test func exportDoesNotOverwriteTheUsersFileWithTheSameName() throws {
        let (vault, noteFolder) = makeVault()
        try Data("z notatki".utf8).write(to: noteFolder.appendingPathComponent("attachments/skan.png"))
        let folder = vault.appendingPathComponent(ObsidianExport.attachmentsDir + "/Kolizja")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("moje".utf8).write(to: folder.appendingPathComponent("skan.png"))
        let note = Note(title: "Kolizja", folderPath: "Praca/x")

        let outcome = try ObsidianExport.export(
            note: note, markdown: "![s](attachments/skan.png)", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )
        #expect(read(folder.appendingPathComponent("skan.png")) == "moje")
        #expect(outcome.attachments == [ObsidianExport.attachmentsDir + "/Kolizja/skan (NoteM).png"])
        #expect(read(vault.appendingPathComponent(outcome.attachments[0])) == "z notatki")
    }

    /// (d) Kopia sprzed 1.1.1 (bez listy): usunięcie notatki nie kasuje załączników.
    @Test func removeMirrorWithoutAListDeletesNoAttachments() throws {
        let (vault, noteFolder) = makeVault()
        try Data("obrazek".utf8).write(to: noteFolder.appendingPathComponent("attachments/rysunek.png"))
        let note = Note(title: "Stara kopia", folderPath: "Praca/x")
        let outcome = try ObsidianExport.export(
            note: note, markdown: "![r](attachments/rysunek.png)", category: "Praca",
            noteFolder: noteFolder, vaultFolder: vault, previousRelativePath: nil
        )
        ObsidianExport.removeMirror(relativePath: outcome.relativePath, vaultFolder: vault, noteID: note.id)
        #expect(FileManager.default.fileExists(atPath: vault.appendingPathComponent(outcome.attachments[0]).path))
    }
}
