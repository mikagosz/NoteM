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

/// Settings window with a sidebar layout.
struct SettingsView: View {
    let settings: AppSettings
    let model: NotesModel

    @State private var pane: SettingsPane? = .appearance

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(SettingsPane.allCases, id: \.self) { p in
                    Label(p.title, systemImage: p.icon).tag(p)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Ustawienia")
            .navigationSplitViewColumnWidth(ideal: 180)
        } detail: {
            Group {
                switch pane ?? .appearance {
                case .general:        GeneralSettingsView()
                case .appearance:     AppearanceSettingsView(settings: settings)
                case .categorization: RulesSettingsView(settings: settings)
                case .smartFolders:   SmartFoldersSettingsView(settings: settings)
                case .quickCapture:
                    QuickCaptureSettingsView(settings: settings) { QuickCaptureManager.shared.refresh() }
                case .sync:
                    SyncSettingsView(settings: settings, model: model) { SyncManager.shared.refresh() }
                case .trash:          TrashSettingsView(settings: settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 700, height: 460)
    }
}

private enum SettingsPane: String, Hashable, CaseIterable {
    case general, appearance, categorization, smartFolders, quickCapture, sync, trash

    var title: String {
        switch self {
        case .general:        return "Ogólne"
        case .appearance:     return "Wygląd"
        case .categorization: return "Katalogowanie"
        case .smartFolders:   return "Inteligentne foldery"
        case .quickCapture:   return "Quick Capture"
        case .sync:           return "Synchronizacja"
        case .trash:          return "Kosz"
        }
    }

    var icon: String {
        switch self {
        case .general:        return "gearshape"
        case .appearance:     return "paintpalette"
        case .categorization: return "folder.badge.gearshape"
        case .smartFolders:   return "folder.badge.questionmark"
        case .quickCapture:   return "bolt.fill"
        case .sync:           return "arrow.triangle.2.circlepath"
        case .trash:          return "trash"
        }
    }
}

private struct GeneralSettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "note.text")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("NoteM").font(.largeTitle.bold())
            Text("Notatki na każdą okazję").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Settings pane for managing smart folders.
private struct SmartFoldersSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Inteligentne foldery")
                .font(.headline)
            Text("Inteligentne foldery to zapisane wyszukiwania, które automatycznie zbierają pasujące notatki. "
                 + "Dwa wbudowane foldery (Dzisiejsze, Przypięte) są zawsze dostępne.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                Section("Wbudowane") {
                    ForEach(SmartFolder.predefined) { sf in
                        Label(sf.name, systemImage: sf.icon)
                            .foregroundStyle(.secondary)
                    }
                }
                if !settings.smartFolders.isEmpty {
                    Section("Własne") {
                        ForEach(settings.smartFolders) { sf in
                            Label(sf.name, systemImage: sf.icon)
                        }
                        .onDelete { settings.smartFolders.remove(atOffsets: $0) }
                    }
                }
            }
            .frame(minHeight: 160)

            if showAdd {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Nazwa folderu", text: $newName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Tag (np. projekt)", text: $newTag)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Anuluj") { showAdd = false; newName = ""; newTag = "" }
                            Spacer()
                            Button("Dodaj") { commitAdd() }
                                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                          || newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            } else {
                Button { showAdd = true } label: {
                    Label("Dodaj folder (tag contains)", systemImage: "plus")
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func commitAdd() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let tag  = newTag.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !tag.isEmpty else { return }
        settings.addSmartFolder(SmartFolder(
            id: UUID(),
            name: name,
            icon: "folder.badge.questionmark",
            conditions: [.tagContains(tag)],
            conjunctive: true
        ))
        showAdd = false; newName = ""; newTag = ""
    }
}

/// What the sidebar can point at: the collected-tasks view, trash, or a specific note.
enum SidebarSelection: Hashable {
    case tasks
    case trash
    case note(UUID)
}

/// Active filter on the note list (mutually exclusive; only one applies at a time).
enum NoteListFilter: Hashable {
    case tag(String)
    case folder(String)
    case smartFolder(UUID)
}

struct ContentView: View {
    let settings: AppSettings
    let model: NotesModel

    @Environment(\.openSettings) private var openSettings
    @State private var selection: SidebarSelection?
    /// Active filter on the notes list (tag, folder, or smart folder).
    @State private var noteFilter: NoteListFilter?
    /// Whether the conflict-resolution sheet is showing.
    @State private var showConflicts = false

    private var filteredNotes: [Note] {
        switch noteFilter {
        case .none:
            return model.notes
        case .tag(let tag):
            return model.notes.filter { $0.tags.contains(tag) }
        case .folder(let folder):
            return model.notes.filter { model.category(of: $0) == folder }
        case .smartFolder(let id):
            guard let sf = settings.allSmartFolders.first(where: { $0.id == id }) else { return model.notes }
            return model.notes.filter { sf.matches($0) }
        }
    }

    private var activeFilterLabel: String? {
        switch noteFilter {
        case .none: return nil
        case .tag(let t): return "#\(t)"
        case .folder(let f): return f
        case .smartFolder(let id): return settings.allSmartFolders.first(where: { $0.id == id })?.name
        }
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
                }

                if !settings.allSmartFolders.isEmpty {
                    Section("Inteligentne foldery") {
                        ForEach(settings.allSmartFolders) { sf in
                            let count = model.notes.filter { sf.matches($0) }.count
                            FolderFilterRow(
                                label: sf.name,
                                icon: sf.icon,
                                count: count,
                                isActive: noteFilter == .smartFolder(sf.id)
                            ) {
                                noteFilter = (noteFilter == .smartFolder(sf.id)) ? nil : .smartFolder(sf.id)
                            }
                        }
                    }
                }

                if !model.categories.isEmpty {
                    Section("Foldery") {
                        ForEach(model.categories, id: \.self) { folder in
                            let count = model.notes.filter { model.category(of: $0) == folder }.count
                            let tint = model.categoryColors[folder].flatMap { AppTheme.color(id: $0) }
                            FolderFilterRow(
                                label: folder,
                                icon: "folder.fill",
                                count: count,
                                isActive: noteFilter == .folder(folder),
                                iconTint: tint,
                                onSetColor: { id in model.setCategoryColor(id, for: model.notes.first { model.category(of: $0) == folder }!) }
                            ) {
                                noteFilter = (noteFilter == .folder(folder)) ? nil : .folder(folder)
                            }
                        }
                    }
                }

                if !model.tagCounts.isEmpty {
                    Section("Tagi") {
                        ForEach(model.tagCounts, id: \.tag) { entry in
                            TagFilterRow(
                                tag: entry.tag,
                                count: entry.count,
                                isActive: noteFilter == .tag(entry.tag)
                            ) {
                                noteFilter = (noteFilter == .tag(entry.tag)) ? nil : .tag(entry.tag)
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
                        if let label = activeFilterLabel {
                            Spacer()
                            Button {
                                noteFilter = nil
                            } label: {
                                Label(label, systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .help("Wyczyść filtr")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let error = SyncManager.shared.syncError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.icloud.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.background.opacity(0.95))
                    .overlay(alignment: .bottom) { Divider() }
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        noteFilter = nil
                        selection = .trash
                    } label: {
                        HStack {
                            Label("Kosz", systemImage: "trash")
                                .foregroundStyle(selection == .trash ? Color.accentColor : .primary)
                            if !model.trashedNotes.isEmpty {
                                Spacer()
                                Text("\(model.trashedNotes.count)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .background(.bar)
            }
            .navigationTitle("NoteM")
            .toolbar {
                // Left side — compose button sits near the NoteM title.
                ToolbarItem(placement: .navigation) {
                    Button(action: addNote) {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("Nowa notatka")
                }
                // Right side — settings gear always visible at top-right.
                ToolbarItem(placement: .primaryAction) {
                    Button { openSettings() } label: {
                        Image(systemName: "gear")
                    }
                    .help("Ustawienia")
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
                RoundedRectangle(cornerRadius: 3)
                    .fill(coverColor)
                    .frame(width: 7)
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

/// Sidebar row for a smart folder or physical folder filter.
struct FolderFilterRow: View {
    let label: String
    let icon: String
    let count: Int
    let isActive: Bool
    var iconTint: Color? = nil
    var onSetColor: ((String?) -> Void)? = nil
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Label {
                    Text(label)
                } icon: {
                    Image(systemName: icon)
                        .foregroundStyle(iconTint ?? Color.accentColor)
                }
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : .primary)
        .contextMenu {
            if let onSetColor {
                Menu("Kolor ikony folderu") {
                    ForEach(AppTheme.all) { theme in
                        Button {
                            onSetColor(theme.id)
                        } label: {
                            Label(theme.name, systemImage: "circle.fill")
                                .foregroundStyle(theme.accent)
                        }
                    }
                    Divider()
                    Button("Domyślny") { onSetColor(nil) }
                }
            }
        }
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
