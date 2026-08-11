import Foundation
import Testing
@testable import NoteM

/// The "Attachments" index used to be rebuilt by reading every note off the disk
/// on every reload — and with sync on, a reload happens every seven seconds on
/// the main thread. These lock down the rule that replaced it: read a note again
/// when, and only when, its `modified` moved.
@MainActor
struct AttachmentIndexTests {

    /// Rewrites `modified` in a note's `meta.json` to `stamp`, the way a change
    /// arriving from the other Mac would. Done on the file rather than through
    /// the store because `saveNote` stamps the current time, and the whole point
    /// here is to control that value.
    private func setModifiedOnDisk(_ stamp: String, in metaURL: URL) throws {
        let text = try String(contentsOf: metaURL, encoding: .utf8)
        let patched = try #require(
            try? NSRegularExpression(pattern: "(\"modified\"\\s*:\\s*\")[^\"]+(\")")
        ).stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: "$1" + stamp + "$2"
        )
        #expect(patched != text)
        try Data(patched.utf8).write(to: metaURL)
    }

    @Test func aReloadReadsOnlyTheNotesWhoseModifiedMoved() throws {
        let temp = TempStore()
        let note = temp.store.createNote(title: "Notatka")
        let saved = try #require(temp.store.saveNote(note, content: "http://example.com/pierwszy"))

        let model = NotesModel(store: temp.store)
        #expect(model.attachments.map(\.target) == ["http://example.com/pierwszy"])

        // The text changes behind the model's back while `modified` stays put:
        // nothing says this note needs re-reading, so the reload must not read it.
        let folder = temp.url(saved.folderPath)
        try Data("http://example.com/drugi".utf8).write(to: folder.appendingPathComponent("note.md"))
        model.reload()
        #expect(model.attachments.map(\.target) == ["http://example.com/pierwszy"])

        // …and once `modified` moves, the same note is read again. Without this
        // half, the check above would also pass on a cache that never refreshes —
        // which would be the worse bug of the two.
        try setModifiedOnDisk("2030-01-01T10:00:00Z", in: folder.appendingPathComponent("meta.json"))
        model.reload()
        #expect(model.attachments.map(\.target) == ["http://example.com/drugi"])
    }

    /// The visible list follows the notes: a note deleted on the other Mac takes
    /// its attachments out of the "Attachments" view on the next reload.
    ///
    /// Note what this does *not* prove: whether the cache dictionary still holds
    /// the dead entry. It cannot — the flat list is built by walking `notes`, so
    /// a leaked entry is invisible here. Measured with a mutation: turning the
    /// wholesale assignment into a merge leaves this test green. The wholesale
    /// assignment is about memory, and memory is not what this checks.
    @Test func aNoteThatLeavesTheListLeavesTheIndex() throws {
        let temp = TempStore()
        let first = temp.store.createNote(title: "Pierwsza")
        _ = temp.store.saveNote(first, content: "http://example.com/pierwsza")
        let second = temp.store.createNote(title: "Druga")
        let savedSecond = try #require(temp.store.saveNote(second, content: "http://example.com/druga"))

        let model = NotesModel(store: temp.store)
        #expect(model.attachments.count == 2)

        // Deleted the way the other Mac would do it — the folder is simply gone.
        try FileManager.default.removeItem(at: temp.url(savedSecond.folderPath))
        model.reload()

        #expect(model.attachments.map(\.target) == ["http://example.com/pierwsza"])
    }
}
