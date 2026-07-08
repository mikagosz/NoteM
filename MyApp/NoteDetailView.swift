import SwiftUI

/// WYSIWYG editor for a single note. Content is stored on disk as markdown in
/// `note.md`; in the editor it's an `NSAttributedString`.
///
/// Autosaves ~1s after the last edit (debounced) and flushes on close / when
/// switching to another note (the parent keys this view by `note.id`).
struct NoteDetailView: View {
    let note: Note
    let model: NotesModel

    @State private var controller = RichTextController()
    /// Markdown as last loaded/saved — used to avoid spurious saves.
    @State private var loadedMarkdown: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(controller: controller)
            Divider()
            TagBar(
                tags: note.tags,
                suggestions: model.tagCounts.map(\.tag),
                onAdd: { model.setTags(note.tags + [$0], for: note) },
                onRemove: { tag in model.setTags(note.tags.filter { $0 != tag }, for: note) }
            )
            Divider()
            RichTextEditor(controller: controller)
        }
        .navigationTitle(note.title)
        .task { load() }
        .onDisappear {
            saveTask?.cancel()
            flush()
        }
    }

    private func load() {
        let markdown = model.content(for: note)
        loadedMarkdown = markdown
        controller.setContent(MarkdownStyler.attributedString(fromMarkdown: markdown))
        controller.onChange = { _ in scheduleSave() }
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

    /// Serializes the editor to markdown and saves it if changed.
    private func flush() {
        guard let textView = controller.textView else { return }
        let markdown = MarkdownStyler.markdown(from: textView.attributedString())
        guard markdown != loadedMarkdown else { return }
        model.save(note, content: markdown)
        loadedMarkdown = markdown
    }
}

/// Compact tag editor shown above the editor: existing tags as removable chips,
/// a field to add new ones, and inline suggestions from tags already in use.
struct TagBar: View {
    let tags: [String]
    let suggestions: [String]
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
                    .foregroundStyle(.secondary)
                ForEach(tags, id: \.self) { tag in
                    TagChip(tag: tag) { onRemove(tag) }
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
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(tag)
                .font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Usuń tag")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary))
    }
}
