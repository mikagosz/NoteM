import SwiftUI

/// Editor for a single note's plain-text content.
///
/// Autosaves ~1s after the last edit (debounced) and also flushes on close /
/// when switching to another note (via `onDisappear`, since the parent keys
/// this view by `note.id`).
struct NoteDetailView: View {
    let note: Note
    let model: NotesModel

    @State private var text: String = ""
    /// The content as last loaded/saved — used to avoid spurious saves.
    @State private var loadedContent: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .padding(8)
            .navigationTitle(note.title)
            .task {
                let current = model.content(for: note)
                loadedContent = current
                text = current
            }
            .onChange(of: text) { _, newValue in
                guard let loadedContent, newValue != loadedContent else { return }
                scheduleSave(newValue)
            }
            .onDisappear {
                saveTask?.cancel()
                flush()
            }
    }

    /// Debounced autosave: cancels any pending save and schedules a new one.
    private func scheduleSave(_ content: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            model.save(note, content: content)
            loadedContent = content
        }
    }

    /// Saves immediately if there are unsaved changes.
    private func flush() {
        guard text != loadedContent else { return }
        model.save(note, content: text)
        loadedContent = text
    }
}
