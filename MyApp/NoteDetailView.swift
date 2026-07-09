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
    /// Opens the Settings window (gear lives in the right toolbar cluster).
    @Environment(\.openSettings) private var openSettings

    /// Live task-list flag read from the model, so the toolbar toggle reflects
    /// changes immediately (the passed-in `note` is a snapshot).
    private var isTaskListNote: Bool {
        model.notes.first(where: { $0.id == note.id })?.isTaskList ?? note.isTaskList
    }

    var body: some View {
        VStack(spacing: 0) {
            TagBar(
                tags: note.tags,
                suggestions: model.tagCounts.map(\.tag),
                accent: accent,
                onAdd: { model.setTags(note.tags + [$0], for: note) },
                onRemove: { tag in model.setTags(note.tags.filter { $0 != tag }, for: note) }
            )
            Divider()
            RichTextEditor(controller: controller, darkBackground: darkBackground)

            let backlinks = model.backlinks(to: note)
            if !backlinks.isEmpty {
                Divider()
                BacklinksPanel(notes: backlinks, onOpen: openNote)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FormatBar(controller: controller)
        }
        .navigationTitle(note.title)
        .toolbar {
            // Left cluster: search, task-list toggle, pin, export PDF, print.
            ToolbarItem(placement: .automatic) {
                Button { controller.showFindBar() } label: {
                    Label("Szukaj w notatce", systemImage: "magnifyingglass")
                        .foregroundStyle(accent)
                }
                .help("Szukaj w notatce (⌘F)")
            }
            ToolbarItem(placement: .automatic) {
                Button { model.toggleTaskList(note) } label: {
                    Label(isTaskListNote ? "Usuń z zadań" : "Oznacz jako zadania",
                          systemImage: isTaskListNote ? "checklist.checked" : "checklist")
                        .foregroundStyle(accent)
                }
                .help(isTaskListNote
                      ? "Ta notatka jest listą zadań — kliknij, by zdjąć oznaczenie"
                      : "Oznacz notatkę jako listę zadań (pojawi się w „Zadania”)")
            }
            ToolbarItem(placement: .automatic) {
                Button { model.togglePin(note) } label: {
                    Label(note.pinned ? "Odepnij" : "Przypnij",
                          systemImage: note.pinned ? "pin.fill" : "pin")
                        .foregroundStyle(accent)
                }
                .help(note.pinned ? "Odepnij notatkę" : "Przypnij notatkę na górze")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: exportToPDF) {
                    Label("Eksportuj PDF", systemImage: "arrow.down.doc")
                        .foregroundStyle(accent)
                }
                .help("Eksportuj notatkę jako PDF")
            }
            ToolbarItem(placement: .automatic) {
                Button(action: printNote) {
                    Label("Drukuj", systemImage: "printer")
                        .foregroundStyle(accent)
                }
                .help("Drukuj notatkę")
            }

            // Flexible spacer breaks the glass background into a second cluster
            // and pushes it to the far right.
            ToolbarSpacer(.flexible)

            // Right cluster: background toggle + settings (gear far right).
            ToolbarItem(placement: .automatic) {
                Button { darkBackground.toggle() } label: {
                    Label(darkBackground ? "Białe tło" : "Czarne tło",
                          systemImage: darkBackground ? "sun.max" : "moon")
                        .foregroundStyle(accent)
                }
                .help(darkBackground ? "Przełącz na białe tło" : "Przełącz na czarne tło")
            }
            ToolbarItem(placement: .automatic) {
                Button { openSettings() } label: {
                    Image(systemName: "gear")
                        .foregroundStyle(accent)
                }
                .help("Ustawienia")
            }
        }
        .task { load() }
        .onDisappear {
            saveTask?.cancel()
            flush()
            controller.hideFloatingPanel()
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
        guard dirty || markdown != loadedMarkdown else { return }
        let richData = NoteRichArchive.data(from: attributed)
        model.save(note, content: markdown, richData: richData)
        loadedMarkdown = markdown
        dirty = false
    }
}

/// "Linkuje tutaj" — notes that reference the current note via a wiki link.
struct BacklinksPanel: View {
    let notes: [Note]
    let onOpen: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Linkuje tutaj (\(notes.count))", systemImage: "arrow.turn.up.left")
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
                TextField("dodaj tag…", text: $input)
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
            .help("Usuń tag")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(accent.opacity(0.15)))
    }
}
