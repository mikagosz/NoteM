import Foundation
import Testing
@testable import NoteM

/// The exported page is a standalone file opened straight from the disk, so it
/// runs with no origin to restrain it. Everything in it comes from note text —
/// including whatever the user pasted off a web page.
@MainActor
struct HTMLExportTests {

    private func document(_ markdown: String, attachment: Data? = nil) -> String {
        HTMLExport.document(
            title: "Notatka",
            markdown: markdown,
            attachmentData: { _ in attachment },
            wikiHref: { _ in nil }
        )
    }

    // MARK: - Structure

    @Test func headingsListsAndChecklistsBecomeHTML() {
        let html = document("# Tytuł\n- jeden\n- dwa\n1. raz\n- [x] zrobione")
        #expect(html.contains("<h1>Tytuł</h1>"))
        #expect(html.contains("<li>jeden</li>"))
        #expect(html.contains("<ol>"))
        #expect(html.contains("type=\"checkbox\" checked"))
    }

    @Test func attachmentImagesAreEmbeddedAsDataURIs() {
        let html = document("![kot](attachments/kot.png)", attachment: Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(html.contains("<img src=\"data:image/png;base64,"))
    }

    @Test func aMissingAttachmentDegradesToALabelInsteadOfABrokenImage() {
        let html = document("![kot](attachments/kot.png)", attachment: nil)
        #expect(html.contains("class=\"attachment\""))
        #expect(!html.contains("<img"))
    }

    // MARK: - Injection (P2-01)

    /// The audit's example: a link target closing the `href` attribute and
    /// opening an event handler.
    @Test func quotesInALinkTargetCannotOpenAnAttribute() {
        let html = document("[x](a\" onmouseover=\"alert(1))")
        #expect(!html.contains("onmouseover=\"alert(1)\""))
        #expect(html.contains("&quot;"))
    }

    @Test func quotesInPlainTextAreEscaped() {
        let html = document("powiedział \"cześć\" i poszedł")
        #expect(html.contains("&quot;cześć&quot;"))
    }

    @Test func javascriptLinksLoseTheirTarget() {
        let html = document("[kliknij](javascript:alert(1))")
        #expect(!html.contains("javascript:"))
        #expect(html.contains("kliknij"))
    }

    @Test func javascriptImageSourcesAreDropped() {
        let html = document("![x](javascript:alert(1))")
        #expect(!html.contains("javascript:"))
        #expect(!html.contains("<img"))
    }

    @Test func aDataURIThatIsntAnImageIsDropped() {
        let html = document("![x](data:text/html;base64,PHNjcmlwdD4=)")
        #expect(!html.contains("data:text/html"))
    }

    @Test func ordinaryWebLinksStayClickable() {
        let html = document("[NoteM](https://example.com/a?b=1)")
        #expect(html.contains("<a href=\"https://example.com/a?b=1\">NoteM</a>"))
    }

    @Test func mailtoLinksStayClickable() {
        let html = document("[napisz](mailto:ktos@example.com)")
        #expect(html.contains("<a href=\"mailto:ktos@example.com\">napisz</a>"))
    }

    @Test func markupInNoteTextIsEscapedNotRendered() {
        let html = document("<script>alert(1)</script>")
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
    }
}
