import Foundation
import Testing
@testable import NoteM

/// Pasting HTML used to make NoteM fetch whatever the fragment pointed at, which
/// a README promising no network connections has no room for.
///
/// What these check is the guard's output, not the absence of a request — proving
/// *that* needs a live server and is recorded as a measurement in the audit note
/// (2026-08-11: two requests before, zero after, same fragment, same importer).
/// Here the question is narrower and deterministic: does a remote reference come
/// out the other side?
@MainActor
struct HTMLPasteGuardTests {

    private func strip(_ html: String) -> String {
        HTMLPasteGuard.withoutRemoteResources(html)
    }

    /// The case that was measured making a request.
    @Test func anImageByURLLosesItsSource() {
        let out = strip("<p>tekst</p><img src=\"http://example.com/a.png\" width=\"10\">")
        #expect(!out.contains("http://example.com"))
        #expect(out.contains("tekst"))
        // The tag may stay; with nothing to point at it fetches nothing.
        #expect(!out.contains("src="))
    }

    /// Case, quoting and `srcset` are all part of the same job — HTML on a
    /// pasteboard is written by whoever wrote the page, not by us.
    @Test func theShapeOfTheAttributeDoesNotMatter() {
        #expect(!strip("<IMG SRC='https://example.com/a.png'>").contains("example.com"))
        #expect(!strip("<img srcset=\"https://example.com/a2x.png 2x\">").contains("example.com"))
        #expect(!strip("<img src=https://example.com/a.png>").contains("example.com"))
    }

    /// `//host/path` resolves to https — remote by any other name.
    @Test func aProtocolRelativeURLCountsAsRemote() {
        #expect(!strip("<img src=\"//example.com/a.png\">").contains("example.com"))
    }

    @Test func stylesheetsAndTheirElementsGo() {
        #expect(!strip("<link rel=\"stylesheet\" href=\"http://example.com/s.css\">").contains("example.com"))
        #expect(!strip("<style>@import url('http://example.com/s.css');</style>").contains("example.com"))
        #expect(!strip("<div style=\"background-image:url(http://example.com/b.png)\">x</div>")
            .contains("example.com"))
    }

    /// The one that would quietly undo everything else: a remote `<base>` turns
    /// every relative path in the document into a remote one.
    @Test func aRemoteBaseIsRemoved() {
        let out = strip("<head><base href=\"http://example.com/\"></head><body><img src=\"a.png\"></body>")
        #expect(!out.contains("example.com"))
        #expect(!out.contains("<base"))
    }

    @Test func embeddedPlayersAndScriptsGo() {
        #expect(!strip("<iframe src=\"http://example.com/x\"></iframe>").contains("example.com"))
        #expect(!strip("<script src=\"http://example.com/x.js\"></script>").contains("example.com"))
        #expect(!strip("<video><source src=\"http://example.com/v.mp4\"></video>").contains("example.com"))
    }

    /// A link is not a fetch. Stripping `<a href>` would cost the user something
    /// real and buy nothing — the importer does not open it.
    @Test func linksSurvive() {
        let out = strip("<p>zobacz <a href=\"http://example.com/artykul\">to</a></p>")
        #expect(out.contains("http://example.com/artykul"))
        #expect(out.contains("zobacz"))
    }

    /// An image whose bytes are already in the clipboard needs no network, so it
    /// stays — this is what makes the guard cheap in the common case.
    @Test func inlineDataImagesSurvive() {
        let uri = "data:image/png;base64,iVBORw0KGgo="
        #expect(strip("<img src=\"\(uri)\">").contains(uri))
        // As does an ordinary relative path: with no base it resolves to nothing.
        #expect(strip("<img src=\"obrazki/a.png\">").contains("obrazki/a.png"))
    }

    /// Bytes that are not UTF-8 are handed on untouched rather than dropped: a
    /// paste that silently turned into nothing would be a worse bug than the one
    /// this guards against.
    @Test func undecodableDataPassesThroughUnchanged() {
        let data = Data([0xFF, 0xFE, 0x00, 0x01])
        #expect(HTMLPasteGuard.withoutRemoteResources(data) == data)
    }

    // MARK: - Audyt SBW 2026-09-23, E2-B-P1-01 — adres w innej postaci niż dosłowna

    /// Warianty B–F z sondy audytu. Każdy przechodził przez filtr 1.1.0 bez zmian,
    /// bo importer najpierw dekoduje, a dopiero potem czyta adres.
    @Test func encodedAndEscapedAddressesAreStrippedToo() {
        let warianty = [
            "B": #"<img src="&#104;ttp://127.0.0.1:18765/B.png">"#,
            "C": #"<img src="http:&#47;&#47;127.0.0.1:18765/C.png">"#,
            "D": #"<div style="background:url(&quot;http://127.0.0.1:18765/D.png&quot;)">x</div>"#,
            "E": #"<svg><image href="http://127.0.0.1:18765/E.png"/></svg>"#,
            "F": #"<div style="background:u\72l(http://127.0.0.1:18765/F.png)">x</div>"#,
            "G": #"<img src="&#x68;ttp&#58;//127.0.0.1:18765/G.png">"#,
        ]
        for (nazwa, html) in warianty {
            #expect(!strip(html).contains("18765"), "wariant \(nazwa) przeszedł: \(strip(html))")
        }
    }

    /// Kontrola dodatnia: zwykłe formatowanie i tekst zostają.
    @Test func plainStylingSurvivesTheStricterRules() {
        let out = strip(#"<p style="color:#c00; font-weight:bold">ważne</p>"#)
        #expect(out.contains("color:#c00"))
        #expect(out.contains("ważne"))
    }

    @Test func aStyleBlockWithACSSEscapeGoesWhole() {
        #expect(!strip(#"<style>p{background:u\72l(http://127.0.0.1:18765/H.png)}</style><p>x</p>"#).contains("18765"))
    }
}
