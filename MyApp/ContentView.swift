import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// What the sidebar can point at: the collected-tasks view or a specific note.
enum SidebarSelection: Hashable {
    case tasks
    case note(UUID)
}

struct ContentView: View {
    @State private var model = NotesModel()
    @State private var selection: SidebarSelection?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Zadania", systemImage: "checklist")
                        .tag(SidebarSelection.tasks)
                }
                Section("Notatki") {
                    ForEach(model.notes) { note in
                        NoteRow(note: note)
                            .tag(SidebarSelection.note(note.id))
                            .contextMenu {
                                Button("Usuń", role: .destructive) {
                                    delete(note)
                                }
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
            switch selection {
            case .tasks:
                TasksView(model: model) { noteID in
                    selection = .note(noteID)
                }
            case .note(let id):
                if let note = model.notes.first(where: { $0.id == id }) {
                    NoteDetailView(note: note, model: model)
                        .id(note.id)
                } else {
                    ContentUnavailableView("Wybierz notatkę", systemImage: "note.text")
                }
            case .none:
                ContentUnavailableView("Wybierz notatkę", systemImage: "note.text")
            }
        }
    }

    private func addNote() {
        let note = model.createNote()
        selection = .note(note.id)
    }

    private func delete(_ note: Note) {
        if selection == .note(note.id) {
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

/// Collected unchecked checklist items from every note. Tapping a row opens the
/// source note; the checkbox marks the item done in that note.
struct TasksView: View {
    let model: NotesModel
    let openNote: (UUID) -> Void

    @State private var tasks: [TaskItem] = []

    var body: some View {
        Group {
            if tasks.isEmpty {
                ContentUnavailableView(
                    "Brak zadań",
                    systemImage: "checklist",
                    description: Text("Niezaznaczone punkty checklisty ze wszystkich notatek pojawią się tutaj.")
                )
            } else {
                List {
                    ForEach(tasks) { task in
                        TaskRow(
                            task: task,
                            onComplete: { complete(task) },
                            onOpen: { openNote(task.noteID) }
                        )
                    }
                }
            }
        }
        .navigationTitle("Zadania")
        .onAppear { reload() }
    }

    private func reload() {
        tasks = model.openTasks()
    }

    private func complete(_ task: TaskItem) {
        model.completeTask(task)
        reload()
    }
}

/// A single row in the "Zadania" view.
private struct TaskRow: View {
    let task: TaskItem
    let onComplete: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onComplete) {
                Image(systemName: "square")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Oznacz jako zrobione")

            VStack(alignment: .leading, spacing: 2) {
                Text(task.text.isEmpty ? "(puste zadanie)" : task.text)
                Text(task.noteTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

#Preview {
    ContentView()
}
