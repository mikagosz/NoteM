import AppKit
import Foundation
import SwiftUI

/// The Obsidian bridge: copies NoteM notes into the vault as plain `.md` files
/// with YAML front matter, so that Obsidian (and anything else reading the vault)
/// sees them as
/// normalne notatki markdown.
///
/// The direction is one-way — NoteM is the source of truth and the vault copy is
/// overwritten on every export. That is why, before overwriting or deleting a file,
/// its front matter is checked for `notem-id`: only files we created for that same
/// note are ever touched. A file written by hand in Obsidian is never overwritten —
/// the export picks a different name instead.
enum ObsidianExport {

    /// Root of the Obsidian vault.
    ///
    /// Taken from `StorageLocation`, so a test build redirected away from the
    /// real data cannot mirror notes into the actual vault in iCloud.
    private static var vaultRoot: URL { StorageLocation.vaultRoot }

    /// Name of the folder at the vault root that receives NoteM's notes.
    /// The emoji is part of the folder name in the vault — the vault moved to
    /// emoji folders on 2026-08-02 and this constant has to match it.
    static let folderName = "🗒️ Inbox NoteM"

    /// Default folder in the vault that receives the notes.
    static let defaultVaultFolder = vaultRoot.appendingPathComponent(folderName, isDirectory: true).path

    /// Paths that used to be the default. A stored setting pointing at any of them
    /// is moved to the current `defaultVaultFolder`:
    ///
    /// - notatka projektowa NoteM w „Programy MacOS” (w obu wariantach nazwy,
    ///   before and after the vault moved to emoji) — the project documentation
    ///   stays there, the notes go to the vault root;
    /// - „Notatki NoteM” — poprzednia nazwa folderu docelowego w korzeniu.
    ///
    /// The migration is needed because the export creates a missing folder itself
    /// (`export(...)`), so without it an old path would quietly reappear as an empty
    /// folder in the vault instead of reporting an error.
    static let legacyVaultFolders: [String] = [
        "Programy MacOS/11-NoteM",
        "🟡 Programy MacOS/11-NoteM",
        "Notatki NoteM",
    ].map { vaultRoot.appendingPathComponent($0, isDirectory: true).path }

    /// Subfolder for attachments copied along with the notes.
    static let attachmentsDir = "Zalaczniki"

    /// The front matter key by which our own files are recognised.
    private static let idKey = "notem-id"

    // MARK: - Result and errors

    /// What was produced in the vault: the file path relative to the export folder,
    /// and when it was written.
    struct Outcome {
        let relativePath: String
        let exportedAt: Date
    }

    enum ExportError: LocalizedError {
        case vaultFolderUnavailable(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .vaultFolderUnavailable(let path):
                return Loc.t("Nie mogę otworzyć folderu sejfu: \(path)",
                             "Cannot open the vault folder: \(path)")
            case .writeFailed(let name):
                return Loc.t("Nie udało się zapisać pliku \(name) w sejfie.",
                             "Failed to write \(name) to the vault.")
            }
        }
    }

    // MARK: - Eksport

    /// Writes the note into the vault and returns its path and export date.
    ///
    /// - Parameters:
    ///   - category: the note's category in NoteM — becomes a subfolder in the vault.
    ///   - noteFolder: the note's folder in NoteM (the source of attachments).
    ///   - vaultFolder: folder docelowy w sejfie Obsidiana.
    ///   - previousRelativePath: where the note sat after the previous export; if
    ///     its title or category changed, the old file is cleaned up.
    @discardableResult
    static func export(
        note: Note,
        markdown: String,
        category: String,
        noteFolder: URL,
        vaultFolder: URL,
        previousRelativePath: String?
    ) throws -> Outcome {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: vaultFolder, withIntermediateDirectories: true)
        } catch {
            throw ExportError.vaultFolderUnavailable(vaultFolder.path)
        }

        let now = Date()
        let folder = category.isEmpty ? CategoryEngine.inbox : category
        // Called inside a closure rather than as `map(slug)`: `slug` reaches for
        // `Loc`, so it stays on the main actor, and passing it as a value to `map`
        // would step outside that isolation (a warning, and an error in Swift 6).
        let relativeFolder = folder.split(separator: "/").map { slug($0) }.joined(separator: "/")
        let baseName = slug(note.title.isEmpty ? Loc.t("Notatka", "Note") : note.title)

        // Pick a filename that is either free or already belongs to this note.
        let fileName = availableFileName(
            base: baseName,
            in: vaultFolder.appendingPathComponent(relativeFolder, isDirectory: true),
            noteID: note.id
        )
        let relativePath = relativeFolder + "/" + fileName
        let destination = vaultFolder.appendingPathComponent(relativePath)

        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Attachments land in a subfolder named after the note's file (suffix and
        // all), so two notes with the same title do not share
        // jednego folderu, a `removeMirror` trafia potem w to samo miejsce.
        let attachmentsPrefix = attachmentsDir + "/" + (fileName as NSString).deletingPathExtension
        let body = rewriteAttachments(
            in: markdown,
            sourceFolder: noteFolder.appendingPathComponent("attachments", isDirectory: true),
            vaultFolder: vaultFolder,
            attachmentsPrefix: attachmentsPrefix
        )

        let document = frontMatter(for: note, category: folder, exportedAt: now) + "\n" + body
            + (body.hasSuffix("\n") ? "" : "\n")

        do {
            try document.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            throw ExportError.writeFailed(fileName)
        }

        // The note may have changed title or category — remove the previous copy
        // together with its attachment folder, so no orphans are left in the vault.
        if let previousRelativePath, previousRelativePath != relativePath {
            removeMirror(relativePath: previousRelativePath, vaultFolder: vaultFolder, noteID: note.id)
        }

        return Outcome(relativePath: relativePath, exportedAt: now)
    }

    /// Removes a note's copy from the vault along with its attachment folder — but
    /// only if the file really belongs to that note.
    static func removeMirror(relativePath: String, vaultFolder: URL, noteID: UUID) {
        let fileURL = vaultFolder.appendingPathComponent(relativePath)
        // Read the copy before it goes: its own embeds say exactly which files in
        // "Zalaczniki" belong to this note. Deleting the whole
        // folder by name would also take files the user put there themselves, if
        // the folder name happened to match the note's slug.
        let ourAttachments = embeddedAttachmentPaths(in: (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "")
        guard removeOwnedFile(at: fileURL, noteID: noteID) else { return }

        let fm = FileManager.default
        for path in ourAttachments {
            guard let decodedPath = confinedVaultPath(path) else { continue }
            try? fm.removeItem(at: vaultFolder.appendingPathComponent(decodedPath))
        }

        // The folder goes only when nothing is left in it.
        let base = (fileURL.lastPathComponent as NSString).deletingPathExtension
        let attachments = vaultFolder
            .appendingPathComponent(attachmentsDir, isDirectory: true)
            .appendingPathComponent(base, isDirectory: true)
        if let remaining = try? fm.contentsOfDirectory(atPath: attachments.path), remaining.isEmpty {
            try? fm.removeItem(at: attachments)
        }
    }

    /// The `Zalaczniki/…` paths embedded in the note's copy — both images
    /// (`![[Zalaczniki/notatka/plik.png]]`), jak i pliki
    /// (`[[Zalaczniki/note/contract.pdf|contract.pdf]]`). Ordinary wiki links to
    /// other notes carry no such prefix, so they are not picked up here.
    private static func embeddedAttachmentPaths(in markdown: String) -> [String] {
        let prefix = NSRegularExpression.escapedPattern(for: attachmentsDir)
        let pattern = "!?\\[\\[(" + prefix + "/[^\\]|]+)"
        let ns = markdown as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces) }
    }

    /// A relative path that provably cannot climb out of the vault.
    private static func confinedVaultPath(_ path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return components.joined(separator: "/")
    }

    // MARK: - Frontmatter

    /// Buduje blok YAML z metadanymi notatki (w tym znacznikiem eksportu).
    private static func frontMatter(for note: Note, category: String, exportedAt: Date) -> String {
        var lines = ["---"]
        lines.append("\(idKey): \(note.id.uuidString)")
        lines.append("tytul: " + yamlString(note.title))
        lines.append("kategoria: " + yamlString(category))
        // `tags` is the only key Obsidian interprets — under any other name (`tagi`)
        // the tags stay invisible to the tag pane, to `tag:` searches and to the graph.
        // The remaining keys are plain properties and may keep their Polish names.
        lines.append("tags: [" + note.tags.map(yamlString).joined(separator: ", ") + "]")
        lines.append("utworzono: " + stamp(note.created))
        lines.append("zmodyfikowano: " + stamp(note.modified))
        lines.append("wyeksportowano: " + stamp(exportedAt))
        lines.append("przypieta: \(note.pinned)")
        lines.append("lista-zadan: \(note.isTaskList)")
        lines.append("zrodlo: NoteM")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    /// A quoted YAML scalar — safe for colons, quotes and emoji.
    /// `nonisolated`, bo funkcja jest czysto tekstowa i jest przekazywana jako
    /// as a value to `map` in a context without actor isolation.
    nonisolated private static func yamlString(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"" + escaped + "\""
    }

    private static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    // MARK: - Attachments

    /// Copies the note's attachments into the vault and rewrites `attachments/…`
    /// na osadzenia w stylu Obsidiana (`![[Zalaczniki/notatka/plik.png]]`).
    private static func rewriteAttachments(
        in markdown: String,
        sourceFolder: URL,
        vaultFolder: URL,
        attachmentsPrefix: String
    ) -> String {
        let fm = FileManager.default
        let targetFolder = vaultFolder.appendingPathComponent(attachmentsPrefix, isDirectory: true)
        var copied = Set<String>()

        /// Copies one file into the vault; returns the path to write into the note.
        func copyIfNeeded(_ name: String) -> String? {
            let source = sourceFolder.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { return nil }
            if copied.insert(name).inserted {
                try? fm.createDirectory(at: targetFolder, withIntermediateDirectories: true)
                let destination = targetFolder.appendingPathComponent(name)
                try? fm.removeItem(at: destination)
                guard (try? fm.copyItem(at: source, to: destination)) != nil else { return nil }
            }
            return attachmentsPrefix + "/" + name
        }

        // Obrazki: ![alt](attachments/x) → ![[Zalaczniki/notatka/x]]
        var result = RegexReplace.apply(markdown, pattern: "!\\[([^\\]]*)\\]\\(attachments/([^)\\n]+)\\)") { groups in
            guard let name = decoded(groups[2]), let path = copyIfNeeded(name) else { return groups[0] }
            return "![[" + path + "]]"
        }
        // Pliki: [etykieta](attachments/x) → [[Zalaczniki/notatka/x|etykieta]]
        result = RegexReplace.apply(result, pattern: "\\[([^\\]]+)\\]\\(attachments/([^)\\n]+)\\)") { groups in
            guard let name = decoded(groups[2]), let path = copyIfNeeded(name) else { return groups[0] }
            return "[[" + path + "|" + groups[1] + "]]"
        }

        // Clean up after attachments the note no longer uses.
        if let existing = try? fm.contentsOfDirectory(at: targetFolder, includingPropertiesForKeys: nil) {
            for item in existing where !copied.contains(item.lastPathComponent) {
                try? fm.removeItem(at: item)
            }
        }
        return result
    }

    private static func decoded(_ rawName: String) -> String? {
        let trimmed = rawName.trimmingCharacters(in: .whitespaces)
        let name = trimmed.removingPercentEncoding ?? trimmed
        // The name has to stay a single file — no climbing out of the folder.
        guard !name.isEmpty, !name.contains("/"), name != ".." else { return nil }
        return name
    }

    // MARK: - Filenames

    /// Turns a title into a filename safe for the disk and for Obsidian.
    static func slug(_ text: some StringProtocol) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")
        var cleaned = String(text)
            .components(separatedBy: forbidden)
            .joined(separator: " ")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if cleaned.isEmpty { cleaned = Loc.t("Notatka", "Note") }
        return String(cleaned.prefix(80))
    }

    /// An `.md` name that is free or already belongs to this note. Somebody else's
    /// (bez naszego `notem-id` albo z innym) nie ruszamy — dostajemy sufiks.
    private static func availableFileName(base: String, in folder: URL, noteID: UUID) -> String {
        let candidate = base + ".md"
        if isFree(folder.appendingPathComponent(candidate), noteID: noteID) { return candidate }

        // A stable suffix — the same note always gets the same name.
        let suffixed = base + "-" + noteID.uuidString.prefix(8).lowercased() + ".md"
        return suffixed
    }

    /// Whether this address is writable: empty, or our own file for this note.
    private static func isFree(_ url: URL, noteID: UUID) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return ownerID(of: url) == noteID
    }

    /// Deletes the file only when its front matter points at this note.
    @discardableResult
    private static func removeOwnedFile(at url: URL, noteID: UUID) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path), ownerID(of: url) == noteID else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// Czyta `notem-id` z frontmattera pliku w sejfie (nil dla cudzych notatek).
    private static func ownerID(of url: URL) -> UUID? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n").makeIterator()
        guard lines.next()?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        while let line = lines.next() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { return nil }
            guard trimmed.hasPrefix(idKey + ":") else { continue }
            let value = trimmed.dropFirst((idKey + ":").count).trimmingCharacters(in: .whitespaces)
            return UUID(uuidString: value)
        }
        return nil
    }

}

// MARK: - ObsidianMark

/// The Obsidian marker — a crystal from `Assets.xcassets`. The image itself carries
/// the state: violet (the original) means the note is not in the vault yet, green
/// means it has been sent.
struct ObsidianMark: View {
    /// Whether the note already has a copy in the vault.
    var sent: Bool
    var size: CGFloat = 16

    var body: some View {
        Image(sent ? "ObsidianCrystalSent" : "ObsidianCrystal")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

/// The floating "send to Obsidian" button — a crystal on a material disc, so it
/// stays visible over both a black and a white note background.
struct ObsidianSendButton: View {
    var sent: Bool
    var help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ObsidianMark(sent: sent, size: 22)
                .padding(7)
                .background(Circle().fill(.regularMaterial))
                .overlay(Circle().stroke(.quaternary, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - ObsidianSettingsView

/// Preferences pane: mirror on/off, vault folder, bulk export, and status.
struct ObsidianSettingsView: View {
    @Bindable var settings: AppSettings
    let model: NotesModel

    /// Result of the last bulk export, shown as a transient line.
    @State private var bulkResult: String?

    private var exportedCount: Int {
        model.notes.filter { $0.obsidianExportedAt != nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ObsidianMark(sent: settings.obsidianConnected, size: 20)
                Text(settings.t("Obsidian", "Obsidian"))
                    .font(.headline)
            }
            Text(settings.t("Kopiuj notatki do sejfu Obsidiana jako zwykłe pliki .md z frontmatterem, "
                            + "żeby Obsidian i Claude mogły je czytać. Kopiowanie jest jednostronne — "
                            + "NoteM nadpisuje swoje pliki w sejfie, ale nigdy nie rusza notatek napisanych w Obsidianie.",
                            "Copy notes into an Obsidian vault as plain .md files with front matter, so Obsidian "
                            + "and Claude can read them. The copy is one-way — NoteM overwrites its own files in "
                            + "the vault but never touches notes written in Obsidian."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(settings.t("Połącz NoteM z Obsidianem", "Connect NoteM with Obsidian"),
                   isOn: $settings.obsidianConnected)
                .font(.callout.bold())
            Text(settings.t("Bez połączenia NoteM w ogóle nie pokazuje ikonki Obsidiana przy notatkach.",
                            "Without a connection NoteM hides the Obsidian button on notes entirely."))
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Toggle(settings.t("Wysyłaj notatki automatycznie po zapisie", "Send notes automatically on save"),
                   isOn: $settings.obsidianAutoExport)
                .disabled(!settings.obsidianConnected)
                .padding(.leading, 18)

            if let error = model.obsidianError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(settings.t("Ukryj", "Dismiss")) { model.clearObsidianError() }
                        .font(.caption)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
            }

            // The rest of the settings only make sense once the vault is connected.
            VStack(alignment: .leading, spacing: 14) {
                Divider()

                Text(settings.t("Folder w sejfie", "Vault folder"))
                    .font(.callout.bold())
                HStack(spacing: 8) {
                    Text(settings.obsidianVaultPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(settings.t("Zmień…", "Change…"), action: chooseFolder)
                    Button(settings.t("Pokaż w Finderze", "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: settings.obsidianVaultPath)]
                        )
                    }
                }
                Text(settings.t("Domyślnie „\(ObsidianExport.folderName)” w korzeniu sejfu. W środku notatki trafiają "
                                + "do podfolderów nazwanych jak kategorie w NoteM, a załączniki do „\(ObsidianExport.attachmentsDir)”.",
                                "Defaults to “\(ObsidianExport.folderName)” in the vault root. Inside, notes land in "
                                + "subfolders named after their NoteM categories, attachments in “\(ObsidianExport.attachmentsDir)”."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    // Without this a long hint is truncated instead of wrapping.
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack(spacing: 8) {
                    Image(systemName: exportedCount > 0 ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(exportedCount > 0 ? .green : .secondary)
                    Text(settings.t("Wysłane do Obsidiana: \(exportedCount) z \(model.notes.count)",
                                    "Sent to Obsidian: \(exportedCount) of \(model.notes.count)"))
                        .font(.callout)
                    Spacer()
                    Button(settings.t("Wyślij wszystkie teraz", "Send all now")) {
                        let result = model.exportAllToObsidian()
                        let total = result.sent + result.failed
                        bulkResult = result.failed == 0
                            ? settings.t("Wysłano \(result.sent) notatek.", "Sent \(result.sent) notes.")
                            : settings.t("Wysłano \(result.sent) z \(total) notatek — \(result.failed) nieudanych.",
                                         "Sent \(result.sent) of \(total) notes — \(result.failed) failed.")
                    }
                }
                if let bulkResult {
                    Text(bulkResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.obsidianConnected)
            .opacity(settings.obsidianConnected ? 1 : 0.45)

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Lets the user point the mirror at a different folder in their vault.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: settings.obsidianVaultPath)
        panel.prompt = settings.t("Wybierz", "Choose")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let previous = URL(fileURLWithPath: settings.obsidianVaultPath)
        guard url.path != previous.path else { return }

        settings.obsidianVaultPath = url.path
        model.clearObsidianError()
        // Take the copies out of the old folder, so no orphans are left there.
        let result = model.relocateObsidianMirror(from: previous)
        if result.failed > 0 {
            bulkResult = settings.t(
                "Przeniesiono \(result.sent) notatek — \(result.failed) nie udało się zapisać w nowym folderze.",
                "Moved \(result.sent) notes — \(result.failed) could not be written to the new folder.")
        } else if result.sent > 0 {
            bulkResult = settings.t("Przeniesiono \(result.sent) notatek do nowego folderu.",
                                    "Moved \(result.sent) notes to the new folder.")
        } else {
            bulkResult = nil
        }
    }
}
