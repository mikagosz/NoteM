import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var model = NotesModel()
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(model.notes) { note in
                    NoteRow(note: note)
                        .tag(note.id)
                        .contextMenu {
                            Button("Usuń", role: .destructive) {
                                delete(note)
                            }
                        }
                }
            }
            .navigationTitle("NoteM")
            .toolbar {
                ToolbarItem {
                    Button(action: addNote) {
                        Label("Nowa notatka", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let selection, let note = model.notes.first(where: { $0.id == selection }) {
                NoteDetailView(note: note, model: model)
                    .id(note.id)
            } else {
                ContentUnavailableView("Wybierz notatkę", systemImage: "note.text")
            }
        }
    }

    private func addNote() {
        let note = model.createNote()
        selection = note.id
    }

    private func delete(_ note: Note) {
        if selection == note.id {
            selection = nil
        }
        model.delete(note)
    }
}

/// Sidebar row: note title + last-modified date.
struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .font(.headline)
                .lineLimit(1)
            Text(note.modified, format: .dateTime.day().month().year().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
}
