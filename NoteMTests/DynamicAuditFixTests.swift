import AppKit
import Foundation
import Testing
@testable import NoteM

/// Cases found by the dynamic audit of 2026-11-12 — each test names its finding.
@MainActor
struct DynamicAuditFixTests {

    private func pngData(side: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 1, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    /// A note with one ordinary attachment (so `attachments/` exists — without it the
    /// system cannot walk `../` at all) and a picture lying outside the store.
    private func noteWithOutsidePicture() -> (temp: TempStore, note: Note, folder: URL, outside: Data, climb: String, outsideURL: URL) {
        let temp = TempStore()
        let note = temp.store.createNote(title: "x")
        let source = temp.root.appendingPathComponent("zrodlo.png")
        try? pngData(side: 2).write(to: source)
        _ = temp.store.addAttachment(fileURL: source, toNote: note)
        let outside = pngData(side: 3)
        let outsideURL = temp.root.deletingLastPathComponent().appendingPathComponent("NoteMTests-poza-\(note.id).png")
        try? outside.write(to: outsideURL)
        let folder = temp.store.folderURL(for: note)
        let depth = folder.pathComponents.count - temp.root.deletingLastPathComponent().pathComponents.count + 1
        let climb = String(repeating: "../", count: depth) + outsideURL.lastPathComponent
        return (temp, note, folder, outside, climb, outsideURL)
    }

    // MARK: - D-B-P0-01: attachments/../ in the text

    @Test(arguments: ["attachments/../x.png", "attachments/..%2Fx.png", "attachments/a/b.png",
                      "attachments/%2E%2E", "attachments/", "obrazki/x.png", "attachments/..", "attachments/."])
    func aTargetThatIsNotOnePlainFileIsRefused(_ target: String) {
        #expect(AttachmentPath.filename(fromTarget: target) == nil)
    }

    @Test func theHTMLExportDoesNotEmbedAPictureFromOutsideTheNote() {
        let (temp, note, folder, outside, climb, outsideURL) = noteWithOutsidePicture()
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        let pasted = "Notatka\n![](attachments/\(climb))\n![](attachments/zrodlo.png)"
        let markdown = MarkdownStyler.markdown(from: NSAttributedString(string: pasted, attributes: MarkdownStyler.defaultTypingAttributes))
        let attachments = folder.appendingPathComponent("attachments", isDirectory: true)
        let html = HTMLExport.document(title: "x", markdown: markdown,
                                       attachmentData: { try? Data(contentsOf: attachments.appendingPathComponent($0)) },
                                       wikiHref: { _ in nil })
        #expect(!html.contains(outside.base64EncodedString()))
        // Control: the note's own picture is still embedded.
        #expect(html.contains(pngData(side: 2).base64EncodedString()))
        _ = temp; _ = note
    }

    @Test func theDisplayDoesNotLoadAPictureFromOutsideTheNote() {
        let (temp, _, folder, _, climb, outsideURL) = noteWithOutsidePicture()
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        let outsideOnly = MarkdownStyler.attributedString(fromMarkdown: "![](attachments/\(climb))", noteFolder: folder)
        let own = MarkdownStyler.attributedString(fromMarkdown: "![](attachments/zrodlo.png)", noteFolder: folder)
        #expect(outsideOnly.containsAttachments == false)
        #expect(own.containsAttachments)
        _ = temp
    }

    // MARK: - D-S-P1-01: names with brackets

    @Test(arguments: ["Faktura (1).pdf", "a)b.txt", "nawias].pdf", "[x].doc", "100% pewne.pdf", "zażółć gęślą.pdf", "zwykly.pdf"])
    func aNameSurvivesTheMarkdownRoundTrip(_ name: String) {
        let target = AttachmentPath.markdownTarget(for: name)
        let line = "[\(AttachmentPath.linkLabel(for: name))](\(target))"
        #expect(MarkdownStyler.attachmentFilenames(inMarkdown: line) == [name])
    }

    @Test func anAttachmentWithBracketsIsNotPrunedOnSave() {
        let temp = TempStore()
        var note = temp.store.createNote(title: "x")
        let names = ["Faktura (1).pdf", "a)b.txt", "nawias].pdf", "zwykly.pdf"]
        var text = "x"
        var added: [String] = []
        for name in names {
            let source = temp.root.appendingPathComponent(name)
            try? Data("plik".utf8).write(to: source)
            guard let filename = temp.store.addAttachment(fileURL: source, toNote: note) else { continue }
            added.append(filename)
            text += "\n[\(AttachmentPath.linkLabel(for: name))](\(AttachmentPath.markdownTarget(for: filename)))"
        }
        let markdown = MarkdownStyler.markdown(from: NSAttributedString(string: text, attributes: MarkdownStyler.defaultTypingAttributes))
        if let saved = temp.store.saveNote(note, content: markdown) { note = saved }
        temp.store.pruneAttachments(for: note, keeping: Set(MarkdownStyler.attachmentFilenames(inMarkdown: markdown)), markdown: markdown)
        #expect(Set(temp.store.attachmentFilenames(for: note)) == Set(added))
    }

    /// Notes written before 1.1.10 hold the names unescaped — the markdown guard keeps them.
    @Test func anOldUnescapedNameIsKeptToo() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "x")
        let source = temp.root.appendingPathComponent("Faktura (1).pdf")
        try? Data("plik".utf8).write(to: source)
        let filename = temp.store.addAttachment(fileURL: source, toNote: note)!
        let markdown = "x\n[Faktura (1).pdf](attachments/\(filename))"
        temp.store.pruneAttachments(for: note, keeping: Set(MarkdownStyler.attachmentFilenames(inMarkdown: markdown)), markdown: markdown)
        #expect(temp.store.attachmentFilenames(for: note) == [filename])
        // Control: a file the text really does not mention still goes.
        let other = temp.root.appendingPathComponent("nieuzywany.pdf")
        try? Data("x".utf8).write(to: other)
        _ = temp.store.addAttachment(fileURL: other, toNote: note)
        temp.store.pruneAttachments(for: note, keeping: [], markdown: markdown)
        #expect(temp.store.attachmentFilenames(for: note) == [filename])
    }

    // MARK: - D-S-P2-01: note.md that is not UTF-8

    @Test func textInAnotherEncodingIsNotReadAsEmpty() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Ważna")
        let md = temp.store.folderURL(for: note).appendingPathComponent("note.md")

        try? "Ważna\nzażółć".data(using: .utf16)!.write(to: md)
        #expect(temp.store.loadContent(for: note) == "Ważna\nzażółć")
        #expect(temp.errors.count == 1)

        var bad = Data("Ważna\nzażółć".utf8); bad.insert(0xFF, at: 3)
        try? bad.write(to: md)
        let read = temp.store.loadContent(for: note)
        #expect(read.contains("zażółć"))
        // Reported once per note, not on every read.
        #expect(temp.errors.count == 1)

        // Control: UTF-8 reads as is and reports nothing.
        try? Data("czysto".utf8).write(to: md)
        #expect(temp.store.loadContent(for: note) == "czysto")
    }

    // MARK: - D-S-P2-02 and D-B-P3-01: paths from meta.json

    @Test(arguments: ["../../poza", "Inbox/../../poza", "..", "/../x"])
    func restoringWithAPathOutsideTheStoreGoesToInbox(_ original: String) throws {
        let temp = TempStore()
        let note = temp.store.createNote(title: "x")
        var trashed = try #require(temp.store.trashNote(note))
        trashed.originalFolderPath = original
        let restored = try #require(temp.store.restoreNote(trashed))
        #expect(restored.folderPath.hasPrefix(CategoryEngine.inbox + "/"))
        #expect(!restored.folderPath.contains(".."))
        #expect(temp.exists(restored.folderPath + "/meta.json"))
        #expect(!temp.errors.isEmpty)
    }

    @Test func restoringWithAnOrdinaryPathStillWorks() throws {
        let temp = TempStore()
        let note = temp.store.createNote(title: "x")
        var trashed = try #require(temp.store.trashNote(note))
        trashed.originalFolderPath = "Praca/projekt"
        let restored = try #require(temp.store.restoreNote(trashed))
        #expect(restored.folderPath == "Praca/projekt")
        #expect(temp.errors.isEmpty)
    }

    @Test func movingOutsideTheStoreIsRefused() {
        let temp = TempStore()
        let note = temp.store.createNote(title: "x")
        #expect(temp.store.moveNote(note, toFolderPath: "../poza") == nil)
        #expect(temp.exists(note.folderPath + "/meta.json"))
    }

    @Test func removingTheMirrorNeverLeavesTheVault() throws {
        let base = TestScratch.folder("lustro")
        let vault = base.appendingPathComponent("sejf", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let victim = base.appendingPathComponent("ofiara.md")
        try "---\nnotem-id: \(id.uuidString)\n---\nx\n".write(to: victim, atomically: true, encoding: .utf8)
        ObsidianExport.removeMirror(relativePath: "../ofiara.md", vaultFolder: vault, noteID: id, ownedAttachments: [])
        #expect(FileManager.default.fileExists(atPath: victim.path))
        // Control: the same file inside the vault is ours and goes.
        let own = vault.appendingPathComponent("ofiara.md")
        try FileManager.default.copyItem(at: victim, to: own)
        ObsidianExport.removeMirror(relativePath: "ofiara.md", vaultFolder: vault, noteID: id, ownedAttachments: [])
        #expect(!FileManager.default.fileExists(atPath: own.path))
    }

    // MARK: - D-S-P3-02: huge pictures

    @Test func aHugePictureIsDecodedAtTheDisplayLimitButKeepsItsSize() throws {
        let url = TestScratch.folder("obraz").appendingPathComponent("duzy.png")
        try pngData(side: 5000).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(ThumbnailCache.displayImage(at: url))
        #expect(image.size == NSSize(width: 5000, height: 5000))
        // `representations` reports size × screen scale, not the decoded bitmap — ask the bitmap.
        let decoded = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(max(decoded.width, decoded.height) <= ThumbnailCache.displayMaxPixels)
    }

    @Test func anOrdinaryPictureIsDecodedAsBefore() throws {
        let url = TestScratch.folder("obraz").appendingPathComponent("maly.png")
        try pngData(side: 40).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(ThumbnailCache.displayImage(at: url))
        #expect(image.size == NSImage(contentsOf: url)?.size)
    }

    // MARK: - D-S-P3-03: huge HTML on the clipboard

    @Test func aHugeHTMLPasteGoesInAsPlainText() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NoteMTests-duzy-html"))
        pasteboard.clearContents()
        pasteboard.declareTypes([.html, .string], owner: nil)
        let html = "<p><b>tekst</b></p>" + String(repeating: "<p>x</p>", count: HTMLPasteGuard.maxImportBytes / 8 + 10)
        pasteboard.setData(Data(html.utf8), forType: .html)
        pasteboard.setString("zwykły tekst", forType: .string)
        let textView = NoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let controller = RichTextController()
        textView.controller = controller
        controller.attach(textView)
        let started = Date()
        #expect(textView.paste(from: pasteboard))
        #expect(textView.string == "zwykły tekst")
        #expect(Date().timeIntervalSince(started) < 2)
    }
}
