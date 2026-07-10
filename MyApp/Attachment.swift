import Foundation

/// A single attachment / image / link discovered across the notes, surfaced in
/// the "Załączniki" view so every reference from every note is browsable and
/// links back to the note it lives in.
///
/// Files (images and other documents) come from a note's `attachments/` folder
/// on disk; links are detected inside the note's markdown content.
struct AttachmentRef: Identifiable, Hashable {
    enum Kind: Hashable {
        case image   // an image file in the note's attachments/ folder
        case file    // a non-image file in the note's attachments/ folder
        case link    // an http/https/mailto link written in the note

        /// Section title for the grouped "Załączniki" view.
        func sectionTitle(_ s: AppSettings) -> String {
            switch self {
            case .image: return s.t("Zdjęcia", "Images")
            case .file:  return s.t("Załączniki", "Files")
            case .link:  return s.t("Linki", "Links")
            }
        }

        /// SF Symbol shown for a row of this kind (images use a thumbnail instead).
        var systemImage: String {
            switch self {
            case .image: return "photo"
            case .file:  return "doc"
            case .link:  return "link"
            }
        }
    }

    /// The note this reference was found in.
    let noteID: UUID
    let noteTitle: String
    let kind: Kind
    /// Human label: the filename for files/images, or the URL string for links.
    let label: String
    /// The raw target — an `attachments/…` relative path for files, or an
    /// absolute URL string for links.
    let target: String

    /// Stable, unique within the whole collection: a note's filenames are
    /// disambiguated on copy and its links are de-duplicated, so `noteID`
    /// plus `target` never collide.
    var id: String { "\(noteID.uuidString)|\(target)" }

    /// File extensions treated as inline images (mirrors the editor's drop logic).
    static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "gif", "heic", "tiff", "bmp", "webp", "svg"]
}
