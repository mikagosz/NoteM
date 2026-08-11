import Foundation
import OSLog

/// The system-log side of the failures the user already sees as a banner.
///
/// NoteM sends nothing anywhere, so a report like "my note didn't save" had
/// nothing to confront it with: no crash service, no log file, nothing to ask the
/// user to attach. These lines close exactly that gap and are read back with
///
///     log show --predicate 'subsystem == "com.mikagosz.NoteM"' --last 1h
///
/// The note itself stays out. Text, titles, tags, filenames and paths are never
/// written, and that is enforced by the shape of this type rather than by
/// remembering: the caller passes an `Event` from a fixed list, and the error is
/// reduced to its domain and code. There is no entry point taking free-form text,
/// so a note's content has no way in.
enum Log {

    /// What failed. One case per place that already tells the user something
    /// went wrong — the log and the banner fire from the same spot.
    enum Event: String {
        // Store — a write that did not reach the disk.
        case folderCreate           = "folder-create"
        case noteTextWrite          = "note-text-write"
        case noteMetaWrite          = "note-meta-write"
        case noteFormattingWrite    = "note-formatting-write"
        case noteFormattingRemove   = "note-formatting-remove"
        case noteFile               = "note-file"
        case noteDelete             = "note-delete"
        case trashMove              = "trash-move"
        case trashSlotClear         = "trash-slot-clear"
        case restoreMove            = "restore-move"
        case attachmentCopy         = "attachment-copy"
        case attachmentRemove       = "attachment-remove"
        case categoryColorWrite     = "category-color-write"

        // Store — the folder is not where the note says it is.
        case trashFolderMissing     = "trash-folder-missing"
        case restoreFolderMissing   = "restore-folder-missing"
        case attachmentNoteMissing  = "attachment-note-missing"
        case folderOutsideStore     = "folder-outside-store"

        // Obsidian mirror.
        case obsidianExport         = "obsidian-export"
    }

    /// Records `event` as a failure, with the error's domain and code when there
    /// is an error to name.
    static func failure(_ event: Event, _ error: Error? = nil) {
        // `.public` because everything in the message is either one of the
        // constants above or a numeric error code. Without it the unified log
        // redacts interpolated strings to `<private>` and the line says nothing.
        logger(for: event).error("\(message(event, error), privacy: .public)")
    }

    /// The exact text handed to the logger, split out so a test can prove what
    /// goes into it — and what never does.
    ///
    /// `localizedDescription` is deliberately not used: for file errors it embeds
    /// the path, and the path carries both the note's title and the account name.
    static func message(_ event: Event, _ error: Error?) -> String {
        guard let error else { return event.rawValue + " failed" }
        let details = error as NSError
        return "\(event.rawValue) failed: \(details.domain) \(details.code)"
    }

    private static let store = Logger(subsystem: subsystem, category: "store")
    private static let obsidian = Logger(subsystem: subsystem, category: "obsidian")

    /// Matches the bundle identifier, so the log can be filtered by subsystem the
    /// same way for every program in the family.
    private static let subsystem = "com.mikagosz.NoteM"

    private static func logger(for event: Event) -> Logger {
        switch event {
        case .obsidianExport: obsidian
        default: store
        }
    }
}
