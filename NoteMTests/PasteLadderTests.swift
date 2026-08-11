import AppKit
import Foundation
import Testing
@testable import NoteM

/// The clipboard is the one input every other process on this Mac can write to,
/// and until now only the HTML guard had tests. These drive the whole ladder —
/// NoteM's own type, RTFD, RTF, HTML, plain text — on a **private pasteboard**,
/// never `NSPasteboard.general`, so running the suite doesn't touch whatever the
/// user has on their clipboard.
@MainActor
struct PasteLadderTests {

    private func editor() -> NoteTextView {
        let textView = NoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let controller = RichTextController()
        textView.controller = controller
        controller.attach(textView)
        return textView
    }

    private func board(_ name: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NoteMTests-\(name)"))
        pasteboard.clearContents()
        return pasteboard
    }

    /// NoteM's own archive of `attributed`, exactly as `copy` writes it.
    private func noteMPayload(_ attributed: NSAttributedString) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(attributed, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    // MARK: - Which rung wins

    @Test func noteMsOwnTypeBeatsEverythingElse() {
        let rich = NSMutableAttributedString(string: "nagłówek")
        rich.addAttribute(.headerLevel, value: 2, range: NSRange(location: 0, length: 8))

        let pasteboard = board("own-type")
        pasteboard.declareTypes([.noteMRichText, .string], owner: nil)
        pasteboard.setData(noteMPayload(rich), forType: .noteMRichText)
        pasteboard.setString("zwykły tekst", forType: .string)

        let textView = editor()
        #expect(textView.paste(from: pasteboard))
        #expect(textView.string == "nagłówek")
        // The custom attribute is why this rung exists at all — RTF drops it.
        #expect(textView.textStorage?.attribute(.headerLevel, at: 0, effectiveRange: nil) as? Int == 2)
    }

    @Test func richTextBeatsPlainText() throws {
        let source = NSAttributedString(string: "pogrubione", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 18)
        ])
        let rtf = try #require(source.rtf(from: NSRange(location: 0, length: source.length),
                                          documentAttributes: [:]))

        let pasteboard = board("rtf")
        pasteboard.declareTypes([.rtf, .string], owner: nil)
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setString("pogrubione", forType: .string)

        let textView = editor()
        #expect(textView.paste(from: pasteboard))
        let font = textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test func plainTextIsTheLastResort() {
        let pasteboard = board("plain")
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("sam tekst", forType: .string)

        let textView = editor()
        #expect(textView.paste(from: pasteboard))
        #expect(textView.string == "sam tekst")
    }

    /// Nothing usable on the board means AppKit's own paste should run, so the
    /// ladder has to say "not mine" rather than swallow the command.
    @Test func anEmptyBoardFallsThroughToAppKit() {
        let textView = editor()
        #expect(textView.paste(from: board("empty")) == false)
        #expect(textView.string.isEmpty)
    }

    // MARK: - The hostile payload

    /// Any process running as this user can put a `com.notem.richtext` payload on
    /// the clipboard, so that rung decodes with an explicit class list. The
    /// payload carries the foreign class **inside** a real attributed string —
    /// a bare foreign object proves nothing, which is the lesson from the note
    /// archive tests.
    @Test func aPayloadAskingForAnUnknownClassIsRefusedAndTheNextRungRuns() {
        let smuggled = NSMutableAttributedString(string: "wygląda jak notatka")
        smuggled.addAttribute(NSAttributedString.Key("obcy"),
                              value: NSPredicate(value: true),
                              range: NSRange(location: 0, length: 5))

        let pasteboard = board("hostile")
        pasteboard.declareTypes([.noteMRichText, .string], owner: nil)
        pasteboard.setData(noteMPayload(smuggled), forType: .noteMRichText)
        pasteboard.setString("bezpieczny tekst", forType: .string)

        let textView = editor()
        #expect(textView.paste(from: pasteboard))
        // The refused rung is skipped, not fatal: the plain text still pastes.
        #expect(textView.string == "bezpieczny tekst")
    }

    /// Control sample for the test above: the same shape of payload without the
    /// foreign class does decode, so "refused" is about what the archive asks
    /// for and not about how the test writes it.
    @Test func theSamePayloadWithoutTheForeignClassDecodes() {
        let clean = NSAttributedString(string: "wygląda jak notatka")

        let pasteboard = board("clean")
        pasteboard.declareTypes([.noteMRichText, .string], owner: nil)
        pasteboard.setData(noteMPayload(clean), forType: .noteMRichText)
        pasteboard.setString("bezpieczny tekst", forType: .string)

        let textView = editor()
        #expect(textView.paste(from: pasteboard))
        #expect(textView.string == "wygląda jak notatka")
    }

    // MARK: - Paste and match style (⌥⇧⌘V)

    @Test func matchStyleDropsTheSourcesOwnStyling() throws {
        let source = NSAttributedString(string: "z internetu", attributes: [
            .font: NSFont.systemFont(ofSize: 42),
            .backgroundColor: NSColor.systemYellow
        ])
        let rtf = try #require(source.rtf(from: NSRange(location: 0, length: source.length),
                                          documentAttributes: [:]))

        let pasteboard = board("match-style")
        pasteboard.declareTypes([.rtf], owner: nil)
        pasteboard.setData(rtf, forType: .rtf)

        let textView = editor()
        #expect(textView.pasteAsPlainText(from: pasteboard))
        #expect(textView.string == "z internetu")

        let font = textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == MarkdownStyler.bodyFont.pointSize)
        #expect(textView.textStorage?.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
    }

    @Test func matchStyleWithNothingRichFallsThroughToAppKit() {
        let pasteboard = board("match-style-empty")
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("sam tekst", forType: .string)

        let textView = editor()
        // No RTFD/RTF/HTML: AppKit's own plain-text paste is the right answer.
        #expect(textView.pasteAsPlainText(from: pasteboard) == false)
    }
}

/// Files dropped or pasted into a quick note before the note exists.
@MainActor
struct QuickCaptureStagingTests {

    /// A real file to stage, in its own temporary folder.
    private func sampleFile(named name: String, bytes: [UInt8] = [0x01, 0x02]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteMTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    @Test func aStagedFileKeepsItsNameAndLandsInTheNoteShapedFolder() throws {
        let staging = QuickCaptureStaging()
        defer { staging.discard() }

        let name = try #require(staging.stage(try sampleFile(named: "zrzut.png")))
        #expect(name == "zrzut.png")
        #expect(staging.files.count == 1)
        // The editor is handed `folder` as the note folder and then reads
        // `attachments/<name>` inside it — that path has to exist.
        let expected = staging.folder.appendingPathComponent("attachments/zrzut.png")
        #expect(FileManager.default.fileExists(atPath: expected.path))
    }

    @Test func twoFilesWithTheSameNameGetDifferentOnes() throws {
        let staging = QuickCaptureStaging()
        defer { staging.discard() }

        let first = try #require(staging.stage(try sampleFile(named: "zrzut.png")))
        let second = try #require(staging.stage(try sampleFile(named: "zrzut.png")))
        #expect(first == "zrzut.png")
        #expect(second == "zrzut-1.png")
        // Both names have to lead somewhere: the markdown already points at them.
        #expect(staging.files.count == 2)
        for name in [first, second] {
            let url = staging.folder.appendingPathComponent("attachments/\(name)")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// The contract the whole design rests on: the name the markdown was written
    /// with is the name the file ends up under in the note. The editor writes
    /// `attachments/<name>` while the note does not exist yet, and the save path
    /// then copies the staged file into the freshly created note — if the store
    /// renamed it on the way in, the note would point at nothing.
    @Test func aStagedFileKeepsItsNameOnceItReachesTheNote() throws {
        let temp = TempStore()
        let model = NotesModel(store: temp.store)
        let staging = QuickCaptureStaging()
        defer { staging.discard() }

        let name = try #require(staging.stage(try sampleFile(named: "zrzut.png")))
        let markdown = "notatka z obrazkiem\n\n![](attachments/\(name))"

        // Exactly what `QuickCaptureManager.saveNote` does, in the same order.
        let note = model.createNote(content: markdown, richData: nil, isTaskList: false)
        for file in staging.files {
            let live = try #require(model.notes.first(where: { $0.id == note.id }))
            _ = model.addAttachment(fileURL: file, to: live)
        }

        let live = try #require(model.notes.first(where: { $0.id == note.id }))
        let onDisk = temp.root
            .appendingPathComponent(live.folderPath)
            .appendingPathComponent("attachments/\(name)")
        #expect(FileManager.default.fileExists(atPath: onDisk.path))
        // And the markdown really does point at that file.
        #expect(MarkdownStyler.attachmentFilenames(inMarkdown: markdown) == [name])
    }

    @Test func discardingLeavesNothingBehind() throws {
        let staging = QuickCaptureStaging()
        _ = staging.stage(try sampleFile(named: "zrzut.png"))
        #expect(FileManager.default.fileExists(atPath: staging.folder.path))

        staging.discard()
        #expect(FileManager.default.fileExists(atPath: staging.folder.path) == false)
        #expect(staging.files.isEmpty)
        // Called twice on the way out (save, then close) — must not complain.
        staging.discard()
    }
}
