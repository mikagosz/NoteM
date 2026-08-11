import Foundation
import Testing
@testable import NoteM

/// Switching between local and iCloud storage is the only operation that moves the
/// whole library at once, and the only way for a note to leave the app's view
/// without being deleted.
///
/// The version before these tests skipped any top-level entry that already existed
/// at the destination and said nothing about it. Since the top level is category
/// folders, the second switch (`Inbox` already in iCloud) left every note written
/// since the first one behind — on disk, but invisible in the app, with no message.
/// These tests exist so that cannot come back quietly.
@MainActor
struct StoreMoveTests {

    // MARK: - Scaffolding

    private func makeRoot(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteMMove-\(label)-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes `content` at `path` relative to `root`, making the folders on the way.
    private func write(_ content: String, to path: String, in root: URL) {
        let url = root.appendingPathComponent(path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(content.utf8).write(to: url)
    }

    private func read(_ path: String, in root: URL) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func exists(_ path: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    // MARK: - Tests

    @Test("An empty destination takes the whole store")
    func movesEverythingIntoAnEmptyDestination() {
        let source = makeRoot("src"), destination = makeRoot("dst")
        write("pierwsza", to: "Inbox/2026-08-11_10-00-00/note.md", in: source)
        write("druga", to: "Praca/2026-08-11_11-00-00/note.md", in: source)

        let outcome = NoteStore.moveContents(from: source, to: destination)

        #expect(outcome.isEmpty, "Nothing stood in the way, so nothing may be reported")
        #expect(read("Inbox/2026-08-11_10-00-00/note.md", in: destination) == "pierwsza")
        #expect(read("Praca/2026-08-11_11-00-00/note.md", in: destination) == "druga")
        #expect(!exists("Inbox/2026-08-11_10-00-00", in: source), "The note must not be left in both places")
    }

    /// The bug this whole file is about.
    @Test("A category folder that exists on both sides is merged, not skipped")
    func mergesIntoAnExistingCategoryFolder() {
        let source = makeRoot("src"), destination = makeRoot("dst")
        // Written on the second Mac / during the earlier switch.
        write("stara", to: "Inbox/2026-08-01_09-00-00/note.md", in: destination)
        // Written locally after sync was turned off — this is what used to vanish.
        write("nowa", to: "Inbox/2026-08-11_10-00-00/note.md", in: source)

        let outcome = NoteStore.moveContents(from: source, to: destination)

        #expect(outcome.isEmpty, "A merge that lost nothing has nothing to report")
        #expect(read("Inbox/2026-08-11_10-00-00/note.md", in: destination) == "nowa",
                "The locally written note has to arrive, not stay behind in the old root")
        #expect(read("Inbox/2026-08-01_09-00-00/note.md", in: destination) == "stara",
                "and it must not cost the note that was already there")
    }

    @Test("Merging leaves no phantom category behind in the old root")
    func emptiedFolderIsRemoved() {
        let source = makeRoot("src"), destination = makeRoot("dst")
        write("stara", to: "Inbox/2026-08-01_09-00-00/note.md", in: destination)
        write("nowa", to: "Inbox/2026-08-11_10-00-00/note.md", in: source)

        _ = NoteStore.moveContents(from: source, to: destination)

        #expect(!exists("Inbox", in: source),
                "An emptied category folder in the old root reads as a category that still has notes")
    }

    @Test("A file present on both sides is left alone and reported")
    func fileCollisionIsReportedAndNotOverwritten() {
        let source = makeRoot("src"), destination = makeRoot("dst")
        write("z iCloud", to: "Inbox/2026-08-11_10-00-00/note.md", in: destination)
        write("lokalna", to: "Inbox/2026-08-11_10-00-00/note.md", in: source)

        let outcome = NoteStore.moveContents(from: source, to: destination)

        #expect(read("Inbox/2026-08-11_10-00-00/note.md", in: destination) == "z iCloud",
                "This move never overwrites — the other version stays whole")
        #expect(read("Inbox/2026-08-11_10-00-00/note.md", in: source) == "lokalna",
                "and neither is the one left behind thrown away")
        #expect(outcome.conflicted.contains("Inbox/2026-08-11_10-00-00/note.md"),
                "Silence here is the whole bug: the user has to be told which note stayed and where")
        #expect(outcome.failed.isEmpty, "Nothing failed — it was refused, and the two are worded apart")
    }

    @Test("Conflicts are named by their path, not by the file name alone")
    func conflictNamesTheNote() {
        let source = makeRoot("src"), destination = makeRoot("dst")
        write("a", to: "Praca/2026-08-11_10-00-00/note.md", in: destination)
        write("b", to: "Praca/2026-08-11_10-00-00/note.md", in: source)

        let outcome = NoteStore.moveContents(from: source, to: destination)

        #expect(outcome.conflicted == ["Praca/2026-08-11_10-00-00/note.md"],
                "\"note.md\" on its own tells the user nothing — every note has one")
    }

    @Test("Rebuilt cache files are not reported as losses")
    func regeneratedFilesAreNotReported() {
        let source = makeRoot("src"), destination = makeRoot("dst")
        write("{}", to: "manifest.json", in: destination)
        write("{}", to: "semantic_index.json", in: destination)
        write("{}", to: "manifest.json", in: source)
        write("{}", to: "semantic_index.json", in: source)

        let outcome = NoteStore.moveContents(from: source, to: destination)

        #expect(outcome.isEmpty,
                "The store rewrites both of these on the next save; reporting them would bury the real losses")
    }

    @Test("The trash and the history travel with the notes")
    func trashAndHistoryComeAlong() {
        let source = makeRoot("src"), destination = makeRoot("dst")
        write("skasowana", to: ".trash/\(UUID().uuidString)/note.md", in: source)
        write("snapshot", to: ".history/\(UUID().uuidString)/2026-08-11_10-00-00-000.md", in: source)

        let outcome = NoteStore.moveContents(from: source, to: destination)

        #expect(outcome.isEmpty)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        #expect(entries.contains(".trash"), "A note in the trash is still recoverable — it may not be left behind")
        #expect(entries.contains(".history"), "History is the safety net under every save")
    }
}
