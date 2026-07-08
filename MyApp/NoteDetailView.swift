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
