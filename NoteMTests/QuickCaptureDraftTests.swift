import AppKit
import Foundation
import Testing
@testable import NoteM

/// The quick-capture scratchpad: text left in a panel survives quitting and
/// reopens in that panel, until Save turns it into a note or Close discards it.
@MainActor
struct QuickCaptureDraftTests {

    /// A drafts root of its own per test, in the temporary directory.
    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteMTests-brudnopisy-\(UUID().uuidString)", isDirectory: true)
    }

    private func bold(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 15),
            .foregroundColor: NSColor.systemRed
        ])
    }

    @Test func aNewDraftLeavesNoTraceUntilSomethingIsWritten() {
        let root = tempRoot()
        let draft = QuickCaptureDraft.new(in: root)
        #expect(FileManager.default.fileExists(atPath: draft.folder.path) == false)
        #expect(draft.hasContent == false)
        #expect(QuickCaptureDraft.all(in: root).isEmpty)
    }

    /// The whole point: what comes back after a restart is what was typed,
    /// formatting included — plain text back would look like half the work lost.
    @Test func textAndFormattingSurviveTheRoundTrip() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = QuickCaptureDraft.new(in: root)

        try draft.write(richData: NoteRichArchive.data(from: bold("lista zakupów")), meta: .init())

        // Read back through a fresh value, as the next launch does.
        let reopened = try #require(QuickCaptureDraft.all(in: root).first)
        #expect(reopened.id == draft.id)
        let content = try #require(reopened.readContent())
        #expect(content.string == "lista zakupów")
        let font = try #require(content.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(content.attribute(.foregroundColor, at: 0, effectiveRange: nil) != nil)
    }

    @Test func panelStateSurvivesTheRoundTrip() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = QuickCaptureDraft.new(in: root)
        let before = Date()

        try draft.write(richData: NoteRichArchive.data(from: bold("x")),
                        meta: .init(isTaskList: true, origin: CGPoint(x: 120, y: 340)))

        let meta = draft.readMeta()
        #expect(meta.isTaskList)
        #expect(meta.origin == CGPoint(x: 120, y: 340))
        #expect(meta.savedAt >= before)
    }

    /// Several panels = several drafts, and they must not get mixed up.
    @Test func severalDraftsStaySeparateAndComeBackOldestFirst() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = QuickCaptureDraft.new(in: root)
        let second = QuickCaptureDraft.new(in: root)
        try first.write(richData: NoteRichArchive.data(from: bold("pierwsza")), meta: .init())
        try second.write(richData: NoteRichArchive.data(from: bold("druga")), meta: .init())

        let all = QuickCaptureDraft.all(in: root)
        #expect(all.map(\.id) == [first.id, second.id])
        #expect(all.map { $0.readContent()?.string } == ["pierwsza", "druga"])
    }

    /// Removing is what both Save and Close end with — nothing may be left to reopen.
    @Test func removingLeavesNothingToReopen() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = QuickCaptureDraft.new(in: root)
        try draft.write(richData: NoteRichArchive.data(from: bold("x")), meta: .init())
        #expect(QuickCaptureDraft.all(in: root).count == 1)   // positive control

        draft.remove()
        #expect(QuickCaptureDraft.all(in: root).isEmpty)
        #expect(FileManager.default.fileExists(atPath: draft.folder.path) == false)
        draft.remove()   // called twice on the way out — must not complain
    }

    /// A folder with neither text nor files (a crash between creating it and
    /// writing into it) is swept, and foreign folders are left alone.
    @Test func emptyFoldersAreSweptAndForeignOnesIgnored() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let foreign = root.appendingPathComponent("nie-brudnopis", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)

        #expect(QuickCaptureDraft.all(in: root).isEmpty)
        #expect(FileManager.default.fileExists(atPath: empty.path) == false)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    /// A file dropped into the panel before quitting is still there after the
    /// restart, and still reaches the note on Save under the name the markdown uses.
    @Test func stagedFilesComeBackWithTheDraftAndReachTheNote() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = QuickCaptureDraft.new(in: root)

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteMTests-\(UUID().uuidString).png")
        try Data([0x01, 0x02]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let name = try #require(QuickCaptureStaging(folder: draft.folder).stage(source))
        #expect(draft.hasContent)   // a file alone is worth reopening

        // Next launch: a new staging object over the same folder.
        let reopened = QuickCaptureStaging(folder: draft.folder)
        #expect(reopened.files.map(\.lastPathComponent) == [name])

        let temp = TempStore()
        let model = NotesModel(store: temp.store)
        let note = model.createNote(content: "![](attachments/\(name))", richData: nil, isTaskList: false)
        for file in reopened.files {
            let live = try #require(model.notes.first(where: { $0.id == note.id }))
            _ = model.addAttachment(fileURL: file, to: live)
        }
        let live = try #require(model.notes.first(where: { $0.id == note.id }))
        let onDisk = temp.root.appendingPathComponent(live.folderPath)
            .appendingPathComponent("attachments/\(name)")
        #expect(FileManager.default.fileExists(atPath: onDisk.path))
    }

    /// Drafts must never land where notes are scanned, and a test host must not
    /// touch the real ones — a test copy once wrote into the real notes this way.
    @Test func draftsLiveOutsideTheStoreAndFollowTheTestRedirect() {
        let drafts = StorageLocation.quickCaptureDraftsRoot.standardizedFileURL.path
        let store = StorageLocation.localRoot.standardizedFileURL.path
        #expect(drafts.hasPrefix(store + "/") == false)
        #expect(drafts != store)
        // This test runs inside the `xcodebuild test` host, which redirects every root.
        let realRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        #expect(drafts.hasPrefix(realRoot) == false)
    }

    @Test func aPanelOnADisconnectedDisplayIsNotRestoredThere() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = CGSize(width: 360, height: 400)
        #expect(QuickCaptureManager.isOnScreen(CGPoint(x: 100, y: 100), size: size, screens: [screen]))
        // Off to the right, where a second monitor used to be.
        #expect(QuickCaptureManager.isOnScreen(CGPoint(x: 2000, y: 100), size: size, screens: [screen]) == false)
        // A sliver still visible is not enough to grab.
        #expect(QuickCaptureManager.isOnScreen(CGPoint(x: 1420, y: 100), size: size, screens: [screen]) == false)
    }
}
