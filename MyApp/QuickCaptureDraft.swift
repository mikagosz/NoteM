import AppKit
import Foundation

/// An unsaved quick note that survives quitting the app — the scratchpad
/// behaviour asked for on 2026-08-11 ("like the macOS Stickies").
///
/// Text typed into a quick-capture panel is a **draft**, not a note. It stays in
/// the panel across quits, crashes and restarts until the user decides: **Save**
/// turns it into a note in `Inbox` and deletes the draft, the red **Close**
/// throws it away on purpose. On the next launch every waiting draft reopens by
/// itself, where its panel stood.
///
/// One folder per panel under `StorageLocation.quickCaptureDraftsRoot`:
///
///     <id>/draft.rich     the full attributed text (`NoteRichArchive`), images included
///     <id>/draft.json     the rest of the panel: task-list flag and on-screen position
///     <id>/attachments/   dropped and pasted files — the same shape as a note folder
///
/// The folder doubles as the panel's `QuickCaptureStaging` folder, so markdown
/// written while typing already says `attachments/<name>` and Save only has to
/// copy the files across, exactly as before. It used to live in the temporary
/// directory, which the system sweeps; a draft that is meant to outlive a
/// restart cannot.
struct QuickCaptureDraft: Identifiable, Equatable {

    /// What the panel needs besides the text.
    struct Meta: Codable, Equatable {
        var isTaskList = false
        /// Bottom-left corner of the panel in screen coordinates; `nil` until the
        /// panel has been on screen. Restored as-is only if it still lands on a
        /// display — see `QuickCaptureManager.restoreDrafts`.
        var origin: CGPoint?
        /// Last write, so drafts reopen in the order they were worked on.
        var savedAt = Date()
    }

    let id: UUID
    let folder: URL

    /// A new, empty draft. Nothing is written until there is something to keep:
    /// a panel opened and closed without typing leaves no trace on disk.
    static func new(in root: URL = StorageLocation.quickCaptureDraftsRoot) -> QuickCaptureDraft {
        let id = UUID()
        return QuickCaptureDraft(id: id, folder: root.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    /// Every draft waiting in `root`, oldest first. A folder that holds nothing
    /// worth reopening — no text and no files, e.g. left behind by a crash between
    /// creating the folder and writing into it — is removed on the way.
    static func all(in root: URL = StorageLocation.quickCaptureDraftsRoot) -> [QuickCaptureDraft] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        var drafts: [QuickCaptureDraft] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let id = UUID(uuidString: entry.lastPathComponent) else { continue }
            let draft = QuickCaptureDraft(id: id, folder: entry)
            if draft.hasContent {
                drafts.append(draft)
            } else {
                draft.remove()
            }
        }
        return drafts.sorted { $0.readMeta().savedAt < $1.readMeta().savedAt }
    }

    var richURL: URL { folder.appendingPathComponent("draft.rich") }
    var metaURL: URL { folder.appendingPathComponent("draft.json") }
    var attachmentsURL: URL { folder.appendingPathComponent("attachments", isDirectory: true) }

    /// Whether there is anything to bring back: text, or at least one file.
    var hasContent: Bool {
        FileManager.default.fileExists(atPath: richURL.path) || !stagedFiles().isEmpty
    }

    /// The saved text with its formatting, or `nil` when there is none (or the
    /// archive is refused by secure decoding — then the panel opens empty rather
    /// than instantiating classes it does not know).
    func readContent() -> NSAttributedString? {
        guard let data = try? Data(contentsOf: richURL),
              case .decoded(let attributed) = NoteRichArchive.read(data) else { return nil }
        return attributed
    }

    func readMeta() -> Meta {
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return Meta() }
        return meta
    }

    /// Files already sitting in `attachments/`, so a reopened panel can still
    /// hand them to the note when it is finally saved.
    func stagedFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: attachmentsURL.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted().map { attachmentsURL.appendingPathComponent($0) }
    }

    /// Writes text and panel state. Atomic writes, so a crash mid-save leaves the
    /// previous version rather than half a file.
    func write(richData: Data, meta: Meta) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try richData.write(to: richURL, options: .atomic)
        var stamped = meta
        stamped.savedAt = Date()
        try JSONEncoder().encode(stamped).write(to: metaURL, options: .atomic)
    }

    /// Deletes the draft with everything in it. Safe to call more than once.
    func remove() {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
