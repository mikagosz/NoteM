import AppKit
import Foundation
import SwiftUI

/// Mostek do Obsidiana: kopiuje notatki NoteM do sejfu jako zwykłe pliki `.md`
/// z frontmatterem YAML, żeby Obsidian (i Claude czytający sejf) widział je jako
/// normalne notatki markdown.
///
/// Kierunek jest jednostronny — NoteM jest źródłem prawdy, kopia w sejfie jest
/// nadpisywana przy każdym eksporcie. Dlatego przed nadpisaniem / usunięciem
/// pliku sprawdzamy w jego frontmatterze `notem-id`: ruszamy wyłącznie pliki,
/// które sami wcześniej utworzyliśmy dla tej samej notatki. Plik napisany ręcznie
/// w Obsidianie nigdy nie zostanie nadpisany — eksport wybierze wtedy inną nazwę.
enum ObsidianExport {

    /// Korzeń sejfu Obsidiana.
    private static let vaultRoot =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Mobile Documents/iCloud~md~obsidian/Documents/ObsidianVault",
                isDirectory: true
            )

    /// Nazwa folderu w korzeniu sejfu, do którego trafiają notatki z NoteM.
    /// Emoji jest częścią nazwy katalogu w sejfie — sejf przeszedł na foldery
    /// z emoji 2026-08-02 i ta stała musi się z nim zgadzać.
    static let folderName = "🗒️ Inbox NoteM"

    /// Domyślny folder w sejfie, do którego trafiają notatki.
    static let defaultVaultFolder = vaultRoot.appendingPathComponent(folderName, isDirectory: true).path

    /// Ścieżki, które kiedyś były domyślne. Zapisane ustawienie wskazujące na
    /// którąkolwiek z nich przestawiamy na bieżący `defaultVaultFolder`:
    ///
    /// - notatka projektowa NoteM w „Programy MacOS” (w obu wariantach nazwy,
    ///   sprzed i po przejściu sejfu na emoji) — dokumentacja projektu ma tam
    ///   zostać, notatki idą do korzenia sejfu;
    /// - „Notatki NoteM” — poprzednia nazwa folderu docelowego w korzeniu.
    ///
    /// Migracja jest potrzebna, bo eksport tworzy brakujący katalog sam
    /// (`export(...)`), więc bez niej stara ścieżka odrodziłaby się jako pusty
    /// folder w sejfie zamiast zgłosić błąd.
    static let legacyVaultFolders: [String] = [
        "Programy MacOS/11-NoteM",
        "🟡 Programy MacOS/11-NoteM",
        "Notatki NoteM",
    ].map { vaultRoot.appendingPathComponent($0, isDirectory: true).path }

    /// Podfolder na załączniki skopiowane razem z notatkami.
    static let attachmentsDir = "Zalaczniki"

    /// Klucz frontmattera, po którym rozpoznajemy własne pliki.
    private static let idKey = "notem-id"

    // MARK: - Wynik i błędy

    /// Co powstało w sejfie: ścieżka pliku względem folderu eksportu i moment zapisu.
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

    /// Zapisuje notatkę w sejfie i zwraca ścieżkę oraz datę eksportu.
    ///
    /// - Parameters:
    ///   - category: kategoria notatki w NoteM — staje się podfolderem w sejfie.
    ///   - noteFolder: folder notatki w NoteM (źródło załączników).
    ///   - vaultFolder: folder docelowy w sejfie Obsidiana.
    ///   - previousRelativePath: gdzie notatka leżała po poprzednim eksporcie;
    ///     jeśli zmieniła tytuł lub kategorię, stary plik jest sprzątany.
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
        // Wywołanie w domknięciu, nie `map(slug)`: `slug` sięga po `Loc`, więc
        // zostaje na głównym aktorze, a przekazanie jej jako wartości do `map`
        // wychodziłoby poza izolację (ostrzeżenie, a w Swift 6 błąd).
        let relativeFolder = folder.split(separator: "/").map { slug($0) }.joined(separator: "/")
        let baseName = slug(note.title.isEmpty ? Loc.t("Notatka", "Note") : note.title)

        // Wybierz nazwę pliku, która jest wolna albo należy do tej samej notatki.
        let fileName = availableFileName(
            base: baseName,
            in: vaultFolder.appendingPathComponent(relativeFolder, isDirectory: true),
            noteID: note.id
        )
        let relativePath = relativeFolder + "/" + fileName
        let destination = vaultFolder.appendingPathComponent(relativePath)

        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Załączniki lądują w podfolderze nazwanym jak plik notatki (razem z
        // ewentualnym sufiksem), więc dwie notatki o tym samym tytule nie dzielą
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

        // Notatka mogła zmienić tytuł albo kategorię — usuń poprzednią kopię
        // razem z jej folderem załączników, żeby w sejfie nie zostawały sieroty.
        if let previousRelativePath, previousRelativePath != relativePath {
            removeMirror(relativePath: previousRelativePath, vaultFolder: vaultFolder, noteID: note.id)
        }

        return Outcome(relativePath: relativePath, exportedAt: now)
    }

    /// Usuwa kopię notatki z sejfu razem z jej folderem załączników — ale tylko
    /// jeśli plik faktycznie należy do tej notatki.
    static func removeMirror(relativePath: String, vaultFolder: URL, noteID: UUID) {
        let fileURL = vaultFolder.appendingPathComponent(relativePath)
        // Przeczytaj kopię, zanim zniknie: jej własne osadzenia mówią dokładnie,
        // które pliki w „Zalaczniki” należą do tej notatki. Kasowanie całego
        // folderu po nazwie zabrałoby też pliki, które użytkownik sam tam włożył,
        // gdyby nazwa folderu pokryła się ze slugiem notatki.
        let ourAttachments = embeddedAttachmentPaths(in: (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "")
        guard removeOwnedFile(at: fileURL, noteID: noteID) else { return }

        let fm = FileManager.default
        for path in ourAttachments {
            guard let decodedPath = confinedVaultPath(path) else { continue }
            try? fm.removeItem(at: vaultFolder.appendingPathComponent(decodedPath))
        }

        // Folder znika tylko wtedy, gdy nic w nim nie zostało.
        let base = (fileURL.lastPathComponent as NSString).deletingPathExtension
        let attachments = vaultFolder
            .appendingPathComponent(attachmentsDir, isDirectory: true)
            .appendingPathComponent(base, isDirectory: true)
        if let remaining = try? fm.contentsOfDirectory(atPath: attachments.path), remaining.isEmpty {
            try? fm.removeItem(at: attachments)
        }
    }

    /// Ścieżki `Zalaczniki/…` osadzone w kopii notatki — zarówno obrazki
    /// (`![[Zalaczniki/notatka/plik.png]]`), jak i pliki
    /// (`[[Zalaczniki/notatka/umowa.pdf|umowa.pdf]]`). Zwykłe linki wiki do innych
    /// notatek nie mają tego przedrostka, więc się tu nie łapią.
    private static func embeddedAttachmentPaths(in markdown: String) -> [String] {
        let prefix = NSRegularExpression.escapedPattern(for: attachmentsDir)
        let pattern = "!?\\[\\[(" + prefix + "/[^\\]|]+)"
        let ns = markdown as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces) }
    }

    /// Ścieżka względna, która na pewno nie wychodzi poza sejf.
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
        lines.append("tagi: [" + note.tags.map(yamlString).joined(separator: ", ") + "]")
        lines.append("utworzono: " + stamp(note.created))
        lines.append("zmodyfikowano: " + stamp(note.modified))
        lines.append("wyeksportowano: " + stamp(exportedAt))
        lines.append("przypieta: \(note.pinned)")
        lines.append("lista-zadan: \(note.isTaskList)")
        lines.append("zrodlo: NoteM")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Cytowany skalar YAML — bezpieczny dla dwukropków, cudzysłowów i emoji.
    /// `nonisolated`, bo funkcja jest czysto tekstowa i jest przekazywana jako
    /// wartość do `map` w kontekście bez izolacji aktora.
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

    // MARK: - Załączniki

    /// Kopiuje załączniki notatki do sejfu i zamienia odwołania `attachments/…`
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

        /// Kopiuje pojedynczy plik do sejfu; zwraca ścieżkę do wpisania w notatce.
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

        // Posprzątaj po załącznikach, których notatka już nie używa.
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
        // Nazwa musi zostać pojedynczym plikiem — żadnego wychodzenia z folderu.
        guard !name.isEmpty, !name.contains("/"), name != ".." else { return nil }
        return name
    }

    // MARK: - Nazwy plików

    /// Zamienia tytuł na nazwę pliku bezpieczną dla dysku i Obsidiana.
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

    /// Nazwa `.md` wolna albo należąca już do tej notatki. Cudzych plików
    /// (bez naszego `notem-id` albo z innym) nie ruszamy — dostajemy sufiks.
    private static func availableFileName(base: String, in folder: URL, noteID: UUID) -> String {
        let candidate = base + ".md"
        if isFree(folder.appendingPathComponent(candidate), noteID: noteID) { return candidate }

        // Stabilny sufiks — ta sama notatka zawsze dostaje tę samą nazwę.
        let suffixed = base + "-" + noteID.uuidString.prefix(8).lowercased() + ".md"
        return suffixed
    }

    /// Czy pod tym adresem można pisać: pusto albo nasz plik dla tej notatki.
    private static func isFree(_ url: URL, noteID: UUID) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return ownerID(of: url) == noteID
    }

    /// Usuwa plik tylko wtedy, gdy jego frontmatter wskazuje na tę notatkę.
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

/// Znaczek Obsidiana — kryształ z `Assets.xcassets`. Stan niesie sam obrazek:
/// fioletowy (oryginalny) znaczy, że notatki jeszcze nie ma w sejfie, zielony,
/// że jest już wysłana.
struct ObsidianMark: View {
    /// Czy notatka ma już kopię w sejfie.
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

/// Pływający przycisk „wyślij do Obsidiana" — kryształ na materiałowym krążku,
/// żeby był widoczny i na czarnym, i na białym tle notatki.
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

            // Reszta ustawień ma sens dopiero po połączeniu z sejfem.
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
                    // Bez tego długa podpowiedź ucina się zamiast zawinąć.
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
        // Zabierz kopie ze starego folderu, żeby nie zostały tam sieroty.
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
