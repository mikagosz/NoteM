import SwiftUI

@main struct MyApp: App {
    @State private var settings = AppSettings()
    @State private var model = NotesModel()

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings, model: model)
        }

        Settings {
            SettingsView(settings: settings, model: model)
        }
    }
}

/// Preferences window with a tab per settings area.
struct SettingsView: View {
    let settings: AppSettings
    let model: NotesModel

    var body: some View {
        TabView {
            RulesSettingsView(settings: settings)
                .tabItem { Label("Katalogowanie", systemImage: "folder") }
            QuickCaptureSettingsView(settings: settings) {
                QuickCaptureManager.shared.refresh()
            }
            .tabItem { Label("Quick capture", systemImage: "bolt") }
            AppearanceSettingsView(settings: settings)
                .tabItem { Label("Wygląd", systemImage: "paintpalette") }
            SyncSettingsView(settings: settings, model: model) {
                SyncManager.shared.refresh()
            }
            .tabItem { Label("Synchronizacja", systemImage: "arrow.triangle.2.circlepath") }
            TrashSettingsView(settings: settings)
                .tabItem { Label("Kosz", systemImage: "trash") }
        }
        .frame(width: 560, height: 420)
    }
}

/// What the sidebar can point at: the collected-tasks view or a specific note.
enum SidebarSelection: Hashable {
    case tasks
    case trash
    case note(UUID)
}

struct ContentView: View {
    let settings: AppSettings
    let model: NotesModel

    @State private var selection: SidebarSelection?
    /// When set, the notes list shows only notes carrying this tag.
    @State private var tagFilter: String?
    /// Whether the conflict-resolution sheet is showing.
    @State private var showConflicts = false

    private var filteredNotes: [Note] {
        guard let tagFilter else { return model.notes }
        return model.notes.filter { $0.tags.contains(tagFilter) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if !model.conflicts.isEmpty {
                    Section {
                        Button {
                            showConflicts = true
                        } label: {
                            Label("Konflikty synchronizacji: \(model.conflicts.count)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Rozwiąż konflikty z innego Maca")
                    }
                }

                Section {
                    Label("Zadania", systemImage: "checklist")
                        .tag(SidebarSelection.tasks)
                    HStack {
                        Label("Kosz", systemImage: "trash")
                        if !model.trashedNotes.isEmpty {
                            Spacer()
                            Text("\(model.trashedNotes.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .tag(SidebarSelection.trash)
                }

                if !model.tagCounts.isEmpty {
                    Section("Tagi") {
                        ForEach(model.tagCounts, id: \.tag) { entry in
                            TagFilterRow(
                                tag: entry.tag,
                                count: entry.count,
                                isActive: tagFilter == entry.tag
                            ) {
                                tagFilter = (tagFilter == entry.tag) ? nil : entry.tag
                            }
                        }
                    }
                }

                Section {
                    ForEach(filteredNotes) { note in
                        NoteRow(note: note, coverColor: AppTheme.color(id: model.categoryColorID(of: note)))
                            .tag(SidebarSelection.note(note.id))
                            .contextMenu {
                                categoryColorMenu(for: note)
                                Button("Usuń", role: .destructive) {
                                    delete(note)
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text("Notatki")
                        if let tagFilter {
                            Spacer()
                            Button {
                                self.tagFilter = nil
                            } label: {
                                Label("#\(tagFilter)", systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .help("Wyczyść filtr tagu")
                        }
                    }
                }
            }
            .onAppear {
                model.rulesProvider = { settings.rules }
                model.trashRetentionProvider = { settings.trashRetentionDays }
                model.switchStorage(syncEnabled: settings.syncEnabled, moveExisting: false)
                QuickCaptureManager.shared.start(model: model, settings: settings)
                SyncManager.shared.start(model: model, settings: settings)
            }
            .sheet(isPresented: $showConflicts) {
                ConflictResolverView(model: model) { showConflicts = false }
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
            case .trash:
                TrashView(model: model)
            case .note(let id):
                if let note = model.notes.first(where: { $0.id == id }) {
                    NoteDetailView(note: note, model: model) { targetID in
                        selection = .note(targetID)
                    }
                    .id(note.id)
                } else {
                    ContentUnavailableView("Wybierz notatkę", systemImage: "note.text")
                }
            case .none:
                ContentUnavailableView("Wybierz notatkę", systemImage: "note.text")
            }
        }
        .tint(settings.theme.accent)
        .background(settings.theme.tintedBackground.ignoresSafeArea())
    }

    /// Context-menu submenu to set a note's category (folder) cover colour.
    @ViewBuilder
    private func categoryColorMenu(for note: Note) -> some View {
        let category = model.category(of: note)
        if !category.isEmpty {
            Menu("Kolor folderu „\(category)”") {
                ForEach(AppTheme.all) { theme in
                    Button {
                        model.setCategoryColor(theme.id, for: note)
                    } label: {
                        Label(theme.name, systemImage: "circle.fill")
                    }
                }
                Divider()
                Button("Brak koloru") { model.setCategoryColor(nil, for: note) }
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
    var coverColor: Color? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let coverColor {
                RoundedRectangle(cornerRadius: 2)
                    .fill(coverColor)
                    .frame(width: 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(note.modified, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Trash view: deleted notes with restore / permanent-delete actions.
struct TrashView: View {
    let model: NotesModel

    var body: some View {
        Group {
            if model.trashedNotes.isEmpty {
                ContentUnavailableView(
                    "Kosz jest pusty",
                    systemImage: "trash",
                    description: Text("Usunięte notatki trafiają tutaj i można je przywrócić.")
                )
            } else {
                List {
                    ForEach(model.trashedNotes) { note in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title)
                                    .lineLimit(1)
                                if let deletedAt = note.deletedAt {
                                    Text("Usunięto \(deletedAt, format: .dateTime.day().month().year().hour().minute())")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Przywróć") { model.restore(note) }
                            Button("Usuń trwale", role: .destructive) { model.deletePermanently(note) }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Kosz")
    }
}

/// Sidebar row for a tag filter: name + note count, highlighted when active.
struct TagFilterRow: View {
    let tag: String
    let count: Int
    let isActive: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Label(tag, systemImage: isActive ? "tag.fill" : "tag")
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : .primary)
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
    ContentView(settings: AppSettings(), model: NotesModel())
}
