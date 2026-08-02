import AppKit
import Foundation
import Testing
@testable import NoteM

/// `note.md` is the portable copy of a note — the one the HTML export, the
/// Obsidian mirror and any other markdown editor read. Anything the editor can
/// produce has to survive the trip out to markdown and back, so these tests walk
/// text → `NSAttributedString` → text and demand the same string on both ends.
@MainActor
struct MarkdownStylerTests {

    /// A note folder holding one real PNG in `attachments/`, so image round-trips
    /// exercise the same path the app takes (the file has to load as an image).
    private func makeNoteFolder(imageNamed name: String) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteMTests-md-" + UUID().uuidString, isDirectory: true)
        let attachments = folder.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: attachments.appendingPathComponent(name))
        }
        return folder
    }

    private func roundTrip(_ markdown: String, noteFolder: URL? = nil) -> String {
        MarkdownStyler.markdown(
            from: MarkdownStyler.attributedString(fromMarkdown: markdown, noteFolder: noteFolder)
        )
    }

    // MARK: - Block structure

    @Test func headersSurviveTheRoundTrip() {
        #expect(roundTrip("# Tytuł") == "# Tytuł")
        #expect(roundTrip("## Podtytuł") == "## Podtytuł")
        #expect(roundTrip("### Mniejszy") == "### Mniejszy")
    }

    @Test func listsSurviveTheRoundTrip() {
        #expect(roundTrip("- jeden\n- dwa") == "- jeden\n- dwa")
        #expect(roundTrip("1. jeden\n2. dwa") == "1. jeden\n2. dwa")
    }

    @Test func checklistsKeepTheirState() {
        #expect(roundTrip("- [ ] do zrobienia") == "- [ ] do zrobienia")
        #expect(roundTrip("- [x] zrobione") == "- [x] zrobione")
    }

    @Test func mixedDocumentKeepsItsShape() {
        let markdown = """
        # Lista zakupów
        wstęp
        - mleko
        - chleb

        - [ ] zadzwonić
        """
        #expect(roundTrip(markdown) == markdown)
    }

    // MARK: - Inline

    @Test func emphasisAndLinksSurviveTheRoundTrip() {
        #expect(roundTrip("**gruby**") == "**gruby**")
        #expect(roundTrip("*pochyły*") == "*pochyły*")
        #expect(roundTrip("[NoteM](https://example.com)") == "[NoteM](https://example.com)")
    }

    @Test func wikiLinksSurviveTheRoundTrip() {
        #expect(roundTrip("zobacz [[Inna notatka]] dalej") == "zobacz [[Inna notatka]] dalej")
    }

    // MARK: - Images (P1-01)

    /// The regression this whole file exists for: an image used to serialize as a
    /// bare U+FFFC placeholder, so it vanished from note.md, from the HTML export
    /// and from the Obsidian copy while still looking fine inside the app.
    @Test func imagesSerializeBackToMarkdown() {
        let folder = makeNoteFolder(imageNamed: "zdjecie.png")
        defer { try? FileManager.default.removeItem(at: folder) }

        let markdown = "![](attachments/zdjecie.png)"
        let attributed = MarkdownStyler.attributedString(fromMarkdown: markdown, noteFolder: folder)
        #expect(attributed.string.contains("\u{FFFC}"), "obrazek ma być wstawiony jako załącznik")

        let out = MarkdownStyler.markdown(from: attributed)
        #expect(out == markdown)
        #expect(!out.contains("\u{FFFC}"))
    }

    @Test func imageInsideAParagraphKeepsTheSurroundingText() {
        let folder = makeNoteFolder(imageNamed: "zdjecie.png")
        defer { try? FileManager.default.removeItem(at: folder) }

        let markdown = "przed\n![](attachments/zdjecie.png)\npo"
        #expect(roundTrip(markdown, noteFolder: folder) == markdown)
    }

    /// A checkbox is a text attachment too. It must keep going through the
    /// checklist branch instead of being mistaken for an image file.
    @Test func checkboxIsNotMistakenForAnImage() {
        let markdown = "- [ ] zadanie"
        let out = roundTrip(markdown)
        #expect(out == markdown)
        #expect(!out.contains("attachments/"))
    }

    @Test func fileAttachmentLinksAreLeftAlone() {
        #expect(roundTrip("[umowa.pdf](attachments/umowa.pdf)") == "[umowa.pdf](attachments/umowa.pdf)")
    }

    // MARK: - Attachment bookkeeping

    @Test func attachmentFilenamesCoverImagesAndFiles() {
        let names = MarkdownStyler.attachmentFilenames(
            inMarkdown: "![](attachments/a.png)\n[umowa](attachments/b.pdf)\nzwykły tekst"
        )
        #expect(names == ["a.png", "b.pdf"])
    }
}
