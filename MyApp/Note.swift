import Foundation

/// A single note in NoteM.
///
/// On disk, each note lives in its own folder (`folderPath`, relative to the
/// store root) that contains a `note.md` (plain text for now) and a `meta.json`.
/// `folderPath` and the note's textual content are *not* persisted inside
/// `meta.json` — `folderPath` is derived from where the folder sits on disk,
/// and the content lives in `note.md`.
struct Note: Identifiable, Equatable {
    let id: UUID
    var title: String
    /// Optional manual prefix / number for the note.
    var number: String?
    var tags: [String]
    var created: Date
    var modified: Date
    /// Category path relative to the store root, e.g. "Projects/2026-07-08_10-00".
    var folderPath: String
    var links: [UUID]
    /// Pinned notes are kept at the top of the list.
    var pinned: Bool
    /// Marks the note as a planned task list — only these notes appear in the
    /// "Zadania" view.
    var isTaskList: Bool
    /// Whether a task-list note has been ticked off as done in the "Zadania" view.
    var taskDone: Bool
    /// When the note was moved to the trash, or `nil` if it's active.
    var deletedAt: Date?
    /// The `folderPath` the note lived at before being trashed, so it can be
    /// restored to the same place. `nil` for active notes.
    var originalFolderPath: String?
    /// Text recognized (OCR) in image attachments, keyed by the filename inside
    /// `attachments/`. Hidden metadata — never inserted into the note content.
    var ocrTexts: [String: String]

    init(
        id: UUID = UUID(),
        title: String,
        number: String? = nil,
        tags: [String] = [],
        created: Date = Date(),
        modified: Date = Date(),
        folderPath: String,
        links: [UUID] = [],
        pinned: Bool = false,
        isTaskList: Bool = false,
        taskDone: Bool = false,
        deletedAt: Date? = nil,
        originalFolderPath: String? = nil,
        ocrTexts: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.number = number
        self.tags = tags
        self.created = created
        self.modified = modified
        self.folderPath = folderPath
        self.links = links
        self.pinned = pinned
        self.isTaskList = isTaskList
        self.taskDone = taskDone
        self.deletedAt = deletedAt
        self.originalFolderPath = originalFolderPath
        self.ocrTexts = ocrTexts
    }
}

/// The subset of `Note` that is serialized into `meta.json`.
///
/// Deliberately excludes `folderPath` (reconstructed from the on-disk location)
/// and the note's content (stored in `note.md`).
struct NoteMeta: Codable {
    let id: UUID
    var title: String
    var number: String?
    var tags: [String]
    var created: Date
    var modified: Date
    var links: [UUID]
    /// Optional so pre-pin `meta.json` files still decode (missing ⇒ not pinned).
    var pinned: Bool?
    /// Optional so pre-task-list `meta.json` files still decode (missing ⇒ false).
    var isTaskList: Bool?
    /// Optional so older `meta.json` files still decode (missing ⇒ false).
    var taskDone: Bool?
    /// Trash bookkeeping; absent in the metadata of active notes.
    var deletedAt: Date?
    var originalFolderPath: String?
    /// OCR text per image attachment filename. Optional so older `meta.json`
    /// files still decode (missing ⇒ nothing recognized yet).
    var ocrTexts: [String: String]?
}

extension Note {
    /// Builds the persistable metadata for this note.
    var meta: NoteMeta {
        NoteMeta(
            id: id,
            title: title,
            number: number,
            tags: tags,
            created: created,
            modified: modified,
            links: links,
            pinned: pinned,
            isTaskList: isTaskList,
            taskDone: taskDone,
            deletedAt: deletedAt,
            originalFolderPath: originalFolderPath,
            ocrTexts: ocrTexts.isEmpty ? nil : ocrTexts
        )
    }

    /// Reconstructs a full `Note` from its metadata plus the folder path it was
    /// found at (relative to the store root).
    init(meta: NoteMeta, folderPath: String) {
        self.init(
            id: meta.id,
            title: meta.title,
            number: meta.number,
            tags: meta.tags,
            created: meta.created,
            modified: meta.modified,
            folderPath: folderPath,
            links: meta.links,
            pinned: meta.pinned ?? false,
            isTaskList: meta.isTaskList ?? false,
            taskDone: meta.taskDone ?? false,
            deletedAt: meta.deletedAt,
            originalFolderPath: meta.originalFolderPath,
            ocrTexts: meta.ocrTexts ?? [:]
        )
    }
}
