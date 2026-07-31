import SwiftUI
import UniformTypeIdentifiers

/// WYSIWYG editor for a single note. Content is stored on disk as markdown in
/// `note.md`; in the editor it's an `NSAttributedString`.
///
/// Autosaves ~1s after the last edit (debounced) and flushes on close / when
/// switching to another note (the parent keys this view by `note.id`).
struct NoteDetailView: View {
    let note: Note
    let model: NotesModel
    let settings: AppSettings
    /// Theme accent colour, so toolbar icons and the tag bar follow the theme.
    var accent: Color = .accentColor
    /// Opens another note (used by wiki links and the backlinks panel).
    var openNote: (UUID) -> Void = { _ in }

    @State private var controller = RichTextController()
    /// Markdown as last loaded/saved — used to avoid spurious saves.
    @State private var loadedMarkdown: String?
    @State private var saveTask: Task<Void, Never>?
    /// Set on any edit so colour-only changes (which don't alter the markdown)
    /// still trigger a save of the rich archive.
    @State private var dirty = false
    /// Black vs white note background; remembered across notes and launches.
    @AppStorage("noteDarkBackground") private var darkBackground = true
    /// Whether the drawing editor sheet is showing.
    @State private var showDrawing = false
    /// Live voice dictation (Priorytet 4).
    @State private var dictation = VoiceDictation()
    /// Where the current dictation session's text starts in the text view.
    @State private var dictationLocation: Int?
    /// UTF-16 length of the session text inserted so far, so each refined
    /// transcript replaces the previous one in place.
    @State private var dictationLength = 0
    /// Problem with dictation, shown as an alert.
    @State private var voiceError: String?
    /// Confirmation before the note is copied into the Obsidian vault.
    @State private var showObsidianConfirm = false
    /// Opens the Settings window (gear lives in the right toolbar cluster).
    @Environment(\.openSettings) private var openSettings

    /// Live task-list flag read from the model, so the toolbar toggle reflects
    /// changes immediately (the passed-in `note` is a snapshot).
    private var isTaskListNote: Bool {
        model.notes.first(where: { $0.id == note.id })?.isTaskList ?? note.isTaskList
    }

    /// Live Obsidian export stamp read from the model, so the toolbar button
    /// updates the moment the note is mirrored (the passed-in `note` is a snapshot).
    private var obsidianExportedAt: Date? {
        model.notes.first(where: { $0.id == note.id })?.obsidianExportedAt
    }

    /// Weekday + full date + time in the app language, e.g.
    /// "czwartek, 16 lipca 2026, 16:35" / "Thursday, July 16, 2026, 4:35 PM".
    private func dateTimeHeader(_ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: settings.language == .pl ? "pl_PL" : "en_US")
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: now)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Hide the tag bar while drawing so the drawing controls don't overlap it.
            if !showDrawing {
                TagBar(
                    tags: note.tags,
                    suggestions: model.tagCounts.map(\.tag),
                    accent: accent,
                    onAdd: { model.setTags(note.tags + [$0], for: note) },
                    onRemove: { tag in model.setTags(note.tags.filter { $0 != tag }, for: note) }
                )
                Divider()
            }
            RichTextEditor(controller: controller, darkBackground: darkBackground)
                // Day + date + live clock — top-center, hidden while drawing;
                // informational only, so it never steals clicks from the text.
                .overlay(alignment: .top) {
                    if !showDrawing {
                        TimelineView(.everyMinute) { context in
                            Text(dateTimeHeader(context.date))
                                .font(.caption)
                                .foregroundStyle(darkBackground ? Color.white.opacity(0.7) : Color.black.opacity(0.5))
                                .padding(.top, 6)
                        }
                        .allowsHitTesting(false)
                    }
                }

            let backlinks = model.backlinks(to: note)
            if !backlinks.isEmpty {
                Divider()
                BacklinksPanel(notes: backlinks, onOpen: openNote)
            }
        }
        // Float the tool capsule over the editor — no reserved bottom bar.
        .overlay(alignment: .bottom) {
            // Hide the note's format capsule while drawing (the drawing bar takes over).
            if !showDrawing {
                FormatBar(controller: controller, accent: accent,
                          onOpenDrawing: { showDrawing = true },
                          dictation: dictation,
                          onToggleDictation: { Task { await toggleDictation() } })
            }
        }
        // Mostek do Obsidiana — kryształ w prawym dolnym rogu notatki. Bez
        // połączenia sejfu w ustawieniach ikonka w ogóle się nie pojawia.
        .overlay(alignment: .bottomTrailing) {
            if settings.obsidianConnected, !showDrawing {
                ObsidianSendButton(
                    sent: obsidianExportedAt != nil,
                    help: obsidianExportedAt.map {
                        settings.t("W Obsidianie od \($0.noteMDisplay) — kliknij, by odświeżyć kopię",
                                   "In Obsidian since \($0.noteMDisplay) — click to refresh the copy")
                    } ?? settings.t("Wyślij notatkę do sejfu Obsidiana",
                                    "Send the note to the Obsidian vault")
                ) { showObsidianConfirm = true }
                .padding(.trailing, 14)
                .padding(.bottom, 14)
            }
        }
        .overlay {
            if showDrawing {
                DrawingEditorView { url in
                    showDrawing = false
                    guard let url, let textView = controller.textView as? NoteTextView else { return }
                    textView.window?.makeFirstResponder(textView)
                    textView.insertAttachments(from: [url])
                }
                .transition(.opacity)
            }
        }
        .navigationTitle(note.title)
        .toolbar {
            // Left cluster: undo, redo, search, task-list toggle, pin, export PDF, print.
            ToolbarItem(placement: .automatic) {
                Button { controller.undo() } label: {
                    Label(settings.t("Cofnij", "Undo"), systemImage: "arrow.uturn.backward")
                        .foregroundStyle(accent)
                }
                .help(settings.t("Cofnij ostatnią zmianę (⌘Z)", "Undo last change (⌘Z)"))
            }
            ToolbarItem(placement: .automatic) {
                Button { controller.redo() } label: {
                    Label(settings.t("Ponów", "Redo"), systemImage: "arrow.uturn.forward")
                        .foregroundStyle(accent)
                }
                .help(settings.t("Ponów cofniętą zmianę (⇧⌘Z)", "Redo change (⇧⌘Z)"))
            }
            ToolbarItem(placement: .automatic) {
                Button { controller.showFindBar() } label: {
                    Label(settings.t("Szukaj w notatce", "Find in note"), systemImage: "magnifyingglass")
                        .foregroundStyle(accent)
                }
                .help(settings.t("Szukaj w notatce (⌘F)", "Find in note (⌘F)"))
            }
            ToolbarItem(placement: .automatic) {
                Button { model.toggleTaskList(note) } label: {
                    Label(isTaskListNote ? settings.t("Usuń z zadań", "Remove from tasks")
                                         : settings.t("Oznacz jako zadania", "Mark as tasks"),
                          systemImage: isTaskListNote ? "checklist.checked" : "checklist")
                        .foregroundStyle(accent)
                }
                .help(isTaskListNote
                      ? settings.t("Ta notatka jest listą zadań — kliknij, by zdjąć oznaczenie",
                                   "This note is a task list — click to unmark it")
                      : settings.t("Oznacz notatkę jako listę zadań (pojawi się w „Zadania”)",
                                   "Mark the note as a task list (appears in “Tasks”)"))
            }
            ToolbarItem(placement: .automatic) {
                Button { model.togglePin(note) } label: {
                    Label(note.pinned ? settings.t("Odepnij", "Unpin") : settings.t("Przypnij", "Pin"),
                          systemImage: note.pinned ? "pin.fill" : "pin")
                        .foregroundStyle(accent)
                }
                .help(note.pinned ? settings.t("Odepnij notatkę", "Unpin note")
                                  : settings.t("Przypnij notatkę na górze", "Pin note to top"))
            }
            ToolbarItem(placement: .automatic) {
                Button(action: exportToPDF) {
                    Label(settings.t("Eksportuj PDF", "Export PDF"), systemImage: "arrow.down.doc")
                        .foregroundStyle(accent)
                }
                .help(settings.t("Eksportuj notatkę jako PDF", "Export note as PDF"))
            }
            // Eksport HTML (Priorytet 6): jeden samodzielny plik .html.
            ToolbarItem(placement: .automatic) {
                Button(action: exportToHTML) {
                    Label(settings.t("Eksportuj HTML", "Export HTML"), systemImage: "globe")
                        .foregroundStyle(accent)
                }
                .help(settings.t("Eksportuj notatkę jako stronę HTML", "Export note as an HTML page"))
            }
            ToolbarItem(placement: .automatic) {
                Button(action: printNote) {
                    Label(settings.t("Drukuj", "Print"), systemImage: "printer")
                        .foregroundStyle(accent)
                }
                .help(settings.t("Drukuj notatkę", "Print note"))
            }

            // Flexible spacer breaks the glass background into a second cluster
            // and pushes it to the far right.
            ToolbarSpacer(.flexible)

            // Right cluster: background toggle + settings (gear far right).
            ToolbarItem(placement: .automatic) {
                Button { darkBackground.toggle() } label: {
                    Label(darkBackground ? settings.t("Białe tło", "White background")
                                         : settings.t("Czarne tło", "Black background"),
                          systemImage: darkBackground ? "sun.max" : "moon")
                        .foregroundStyle(accent)
                }
                .help(darkBackground ? settings.t("Przełącz na białe tło", "Switch to white background")
                                     : settings.t("Przełącz na czarne tło", "Switch to black background"))
            }
            ToolbarItem(placement: .automatic) {
                Button { openSettings() } label: {
                    Image(systemName: "gear")
                        .foregroundStyle(accent)
                }
                .help(settings.t("Ustawienia", "Settings"))
            }
        }
        .confirmationDialog(
            obsidianExportedAt == nil
                ? settings.t("Wyeksportować notatkę do Obsidiana?", "Export the note to Obsidian?")
                : settings.t("Zaktualizować kopię w Obsidianie?", "Update the copy in Obsidian?"),
            isPresented: $showObsidianConfirm,
            titleVisibility: .visible
        ) {
            Button(settings.t("Wyślij", "Send")) { sendToObsidian() }
            Button(settings.t("Anuluj", "Cancel"), role: .cancel) {}
        } message: {
            Text(settings.t("Notatka trafi do sejfu Obsidiana jako plik .md. Kopia w sejfie zostanie nadpisana.",
                            "The note will be copied into the Obsidian vault as an .md file, overwriting the existing copy."))
        }
        .alert(settings.t("Notatka głosowa", "Voice note"),
               isPresented: Binding(get: { voiceError != nil },
                                    set: { if !$0 { voiceError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(voiceError ?? "")
        }
        .task { load() }
        .onDisappear {
            saveTask?.cancel()
            flush()
            // Belt and braces: never leave a reload blocked by a closed editor.
            model.endPendingEdits(for: note.id)
            controller.hideFloatingPanel()
            if dictation.phase != .idle {
                dictationLocation = nil
                Task { await dictation.stop() }
            }
        }
    }

    private func load() {
        let markdown = model.content(for: note)
        loadedMarkdown = markdown
        dirty = false
        let noteFolder = model.noteFolder(for: note)
        controller.noteFolder = noteFolder

        // Prefer the full-fidelity rich archive (colours, fonts, pasted
        // formatting, images); fall back to markdown for notes saved before rich
        // storage existed — they gain a note.rich on their next save.
        if let data = model.richContent(for: note),
           let attributed = NoteRichArchive.attributedString(from: data) {
            controller.setContent(attributed)
        } else {
            controller.setContent(MarkdownStyler.attributedString(fromMarkdown: markdown, noteFolder: noteFolder))
        }
        controller.onChange = { _ in
            dirty = true
            // Hold off any iCloud reload until this text is on disk — otherwise
            // a change arriving from another Mac would replace what's being typed.
            model.beginPendingEdits(for: note.id)
            scheduleSave()
        }
        controller.titlesProvider = { [model, note] in
            model.notes.filter { $0.id != note.id && !$0.title.isEmpty }.map(\.title)
        }
        controller.onOpenWikiLink = { [model] title in
            if let target = model.note(forTitle: title) { openNote(target.id) }
        }
        controller.onAddAttachment = { [model, note] fileURL in
            model.addAttachment(fileURL: fileURL, to: note)
        }
    }

    /// Mic button action: starts listening (text appears live at the caret),
    /// or stops the running dictation (Priorytet 4).
    private func toggleDictation() async {
        switch dictation.phase {
        case .listening:
            await dictation.stop()
        case .preparing:
            break
        case .idle:
            guard let textView = controller.textView else { return }
            textView.window?.makeFirstResponder(textView)
            dictationLocation = textView.selectedRange().location
            dictationLength = 0
            dictation.onTranscript = { applyTranscript($0) }
            let started = await dictation.start()
            if !started { voiceError = dictation.lastError }
        }
    }

    /// Replaces the current session's text in the note with the newest
    /// transcript, keeping the caret at its end. Tentative fragments arrive
    /// several times and refine in place until finalized.
    private func applyTranscript(_ text: String) {
        guard let textView = controller.textView, let location = dictationLocation else { return }
        let sessionRange = NSRange(location: location, length: dictationLength)
        guard sessionRange.upperBound <= (textView.string as NSString).length else {
            // The note changed under us (e.g. switched away) — stop writing.
            dictationLocation = nil
            return
        }
        textView.insertText(text, replacementRange: sessionRange)
        dictationLength = (text as NSString).length
        textView.setSelectedRange(NSRange(location: location + dictationLength, length: 0))
    }

    private func exportToPDF() {
        flush()
        guard let textView = controller.textView else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = note.title + ".pdf"
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            let info = NSPrintInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url as NSURL
            let margins: CGFloat = 72
            info.leftMargin = margins; info.rightMargin = margins
            info.topMargin = margins;  info.bottomMargin = margins
            info.verticalPagination = .automatic
            info.horizontalPagination = .fit
            let op = NSPrintOperation(view: textView, printInfo: info)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            op.run()
        }
    }

    /// Saves the note as a standalone HTML page (Priorytet 6, zadanie 6.1).
    private func exportToHTML() {
        flush()
        HTMLExport.exportWithPanel(
            title: note.title,
            markdown: model.content(for: note),
            attachmentsFolder: model.noteFolder(for: note).appendingPathComponent("attachments")
        )
    }

    /// Zapisuje bieżący tekst i wysyła notatkę do sejfu Obsidiana (ręcznie,
    /// niezależnie od tego, czy auto-eksport jest włączony).
    private func sendToObsidian() {
        flush()
        model.exportToObsidian(note)
    }

    private func printNote() {
        flush()
        guard let textView = controller.textView else { return }
        let info = NSPrintInfo()
        let margins: CGFloat = 72
        info.leftMargin = margins; info.rightMargin = margins
        info.topMargin = margins;  info.bottomMargin = margins
        info.verticalPagination = .automatic
        info.horizontalPagination = .fit
        let op = NSPrintOperation(view: textView, printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.run()
    }

    /// Debounced autosave.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    /// Saves both representations: markdown (`note.md`, for text features) and the
    /// full-fidelity rich archive (`note.rich`, the display source of truth).
    /// Saves when the markdown changed OR any edit happened (e.g. a colour change
    /// that leaves the markdown identical).
    private func flush() {
        guard let textView = controller.textView else { return }
        let attributed = textView.attributedString()
        let markdown = MarkdownStyler.markdown(from: attributed)
        guard dirty || markdown != loadedMarkdown else {
            model.endPendingEdits(for: note.id)
            return
        }
        let richData = NoteRichArchive.data(from: attributed)
        let referenced = referencedAttachmentNames(in: attributed, markdown: markdown)
        model.save(note, content: markdown, richData: richData, referencedAttachments: referenced)
        loadedMarkdown = markdown
        dirty = false
        // The text is on disk (or the save failed and told the user) — external
        // reloads may run again.
        model.endPendingEdits(for: note.id)
    }

    /// Names of attachment files the note still uses: inline image attachments
    /// (tagged with their filename) plus any `attachments/…` paths written in the
    /// markdown (file links). Files outside this set are pruned on save, so an
    /// image removed from the note also leaves the "Załączniki" view.
    private func referencedAttachmentNames(in attributed: NSAttributedString, markdown: String) -> Set<String> {
        var names: Set<String> = []
        attributed.enumerateAttribute(
            .noteMAttachmentName,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if let name = value as? String { names.insert(name) }
        }
        for name in MarkdownStyler.attachmentFilenames(inMarkdown: markdown) { names.insert(name) }
        return names
    }
}

/// "Linkuje tutaj" — notes that reference the current note via a wiki link.
struct BacklinksPanel: View {
    let notes: [Note]
    let onOpen: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(Loc.t("Linkuje tutaj (\(notes.count))", "Links here (\(notes.count))"), systemImage: "arrow.turn.up.left")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(notes) { note in
                Button {
                    onOpen(note.id)
                } label: {
                    Text(note.title)
                        .font(.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
    }
}

/// Compact tag editor shown above the editor: existing tags as removable chips,
/// a field to add new ones, and inline suggestions from tags already in use.
struct TagBar: View {
    let tags: [String]
    let suggestions: [String]
    var accent: Color = .accentColor
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void

    @State private var input = ""

    /// Existing tags matching what's being typed and not already applied.
    private var matches: [String] {
        let query = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return suggestions
            .filter { $0.lowercased().contains(query) && !tags.contains($0) }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "tag")
                    .foregroundStyle(accent)
                ForEach(tags, id: \.self) { tag in
                    TagChip(tag: tag, accent: accent) { onRemove(tag) }
                }
                TextField(Loc.t("dodaj tag…", "add tag…"), text: $input)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 90)
                    .onSubmit(commit)
                Spacer()
            }
            if !matches.isEmpty {
                HStack(spacing: 6) {
                    ForEach(matches, id: \.self) { suggestion in
                        Button(suggestion) {
                            onAdd(suggestion)
                            input = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func commit() {
        let tag = input.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { return }
        onAdd(tag)
        input = ""
    }
}

/// A single tag rendered as a capsule with a remove button.
struct TagChip: View {
    let tag: String
    var accent: Color = .accentColor
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(tag)
                .font(.caption)
                .foregroundStyle(accent)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(accent.opacity(0.7))
            .help(Loc.t("Usuń tag", "Remove tag"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(accent.opacity(0.15)))
    }
}
