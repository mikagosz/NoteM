import AppKit
import Foundation
import Testing
@testable import NoteM

/// `note.rich` is decoded with an explicit class list and nothing else. The gate
/// that used to bypass that list is gone: the store sits in the user's home
/// folder, the app is not sandboxed, and a file can arrive from the other Mac —
/// "our own storage" was never a trust boundary.
@MainActor
struct NoteRichArchiveTests {

    @Test func aNoteWrittenByThisAppComesBackWhole() {
        let original = NSMutableAttributedString(string: "kolorowy tekst")
        original.addAttribute(.foregroundColor, value: NSColor.systemRed,
                              range: NSRange(location: 0, length: 9))

        guard case .decoded(let decoded) = NoteRichArchive.read(NoteRichArchive.data(from: original)) else {
            Issue.record("Archiwum zapisane przez tę aplikację musi się odczytać")
            return
        }
        #expect(decoded.string == "kolorowy tekst")
        #expect(decoded.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .systemRed)
    }

    /// The exact case the old gate waved through, and the reason this test looks
    /// the way it does.
    ///
    /// The payload has to be a real `NSAttributedString` carrying a foreign class
    /// *inside* it. A bare foreign object is no test at all: the old insecure path
    /// would decode it and then fail the `as? NSAttributedString` cast, so it came
    /// back refused either way. Measured — with the gate put back, a first version
    /// of this test stayed green.
    @Test func anArchiveCarryingAClassOutsideTheListIsRefused() throws {
        let smuggled = NSMutableAttributedString(string: "wygląda jak notatka")
        smuggled.addAttribute(
            NSAttributedString.Key("obcy"),
            value: NSPredicate(value: true),   // not in `allowedClasses`
            range: NSRange(location: 0, length: 5)
        )
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(smuggled, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()

        #expect(NoteRichArchive.read(archiver.encodedData) == .refused)

        // Control sample: the same archiver and the same shape of note, minus the
        // foreign class, decodes — so `refused` above is about what the archive
        // asks for, not about how it was written.
        let ok = NSKeyedArchiver(requiringSecureCoding: false)
        ok.encode(NSAttributedString(string: "wygląda jak notatka"), forKey: NSKeyedArchiveRootObjectKey)
        ok.finishEncoding()
        #expect(NoteRichArchive.read(ok.encodedData) != .refused)
    }

    @Test func rubbishIsRefusedRatherThanCrashing() {
        #expect(NoteRichArchive.read(Data([0x00, 0x01, 0x02])) == .refused)
        #expect(NoteRichArchive.read(Data()) == .refused)
    }

    /// The clipboard path has always been secure-only; this pins it, because it is
    /// the one input that any other process on the machine can write to.
    @Test func theClipboardPathStaysSecureOnly() {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.encode(NSPredicate(value: true), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        #expect(NoteRichArchive.secureAttributedString(from: archiver.encodedData) == nil)
    }
}
