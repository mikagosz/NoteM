import SwiftUI
import AppKit

/// Fully invisible overlay scroller: draws nothing, so the scrollbar never shows
/// while the content still scrolls via wheel/trackpad. Staying `NSScroller`
/// subclass (compatible with overlay) keeps the scroll view's layout intact.
final class ThinScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    // Report zero width so that even if the List momentarily flips its scroller
    // back to the (legacy) system style on a content change, the scroll view
    // doesn't inset its content — otherwise trailing content (the sidebar badge
    // numbers) flickers inward for that instant. Scrolling still works via
    // wheel/trackpad; the scroller is invisible and non-interactive anyway.
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 0 }

    // Draw nothing — no knob, no track, no arrows.
    override func draw(_ dirtyRect: NSRect) {}
    override func drawKnob() {}
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

/// Applies the thin overlay scroller to a single scroll view.
@MainActor private func applyThinScroller(to scroll: NSScrollView) {
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    if scroll.hasVerticalScroller, !(scroll.verticalScroller is ThinScroller) {
        scroll.verticalScroller = ThinScroller()
    }
    if scroll.hasHorizontalScroller, !(scroll.horizontalScroller is ThinScroller) {
        scroll.horizontalScroller = ThinScroller()
    }
}

/// Forces the enclosing `NSScrollView` to the thin overlay scroller, regardless
/// of the system setting.
private struct OverlayScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(from: nsView) }
    }

    private func apply(from view: NSView) {
        guard let scroll = view.enclosingScrollView else { return }
        applyThinScroller(to: scroll)
    }
}

extension View {
    /// Thin, auto-hiding overlay scrollbars that thicken on hover. Apply to the
    /// content *inside* a `ScrollView` so it can find the enclosing scroll view.
    func thinScrollers() -> some View {
        background(OverlayScrollerConfigurator().frame(width: 0, height: 0))
    }
}

/// Switches every `NSScrollView` in all windows (including `List`s) to the thin
/// overlay scroller, regardless of the system "Show scroll bars" setting.
@MainActor func applyOverlayScrollersToAllWindows() {
    func walk(_ view: NSView?) {
        guard let view else { return }
        if let scroll = view as? NSScrollView { applyThinScroller(to: scroll) }
        view.subviews.forEach(walk)
    }
    for window in NSApp.windows { walk(window.contentView) }
}

extension Date {
    /// App-wide display format for note dates, e.g. "09.07.26r. - 09:17".
    var noteMDisplay: String { Self.noteMFormatter.string(from: self) }

    private static let noteMFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.dateFormat = "dd.MM.yy'r.' - HH:mm"
        return formatter
    }()
}

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
                    Label {
                        Text(p.title)
                    } icon: {
                        Image(systemName: p.icon)
                            .foregroundStyle(settings.theme.accent)
                    }
                    .tag(p)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 200)
            // No .navigationTitle → keeps the toolbar compact (the big title was
            // inflating the top bar and clipping content).
            .toolbar(removing: .sidebarToggle)   // drop the sidebar-collapse button
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
        .tint(settings.theme.accent)
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

/// What the sidebar can point at: the start page, collected tasks, trash, or a
/// specific note.
enum SidebarSelection: Hashable {
    case home
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

/// Tightened row insets so sidebar icons hug the left edge of the sidebar
/// instead of using the wide default sidebar indentation.
private let sidebarRowInsets = EdgeInsets(top: 4, leading: -10, bottom: 4, trailing: 8)

/// Custom-pill rows (nav / folder / tag). Their highlight spans almost the full
/// sidebar width with ~2pt left-right margin. The negative leading/trailing pull
/// the pill out to the card edges; the row's own inner padding (leading 6) keeps
/// the icons lined up with the note rows.
private let sidebarFilterRowInsets = EdgeInsets(top: 4, leading: -16, bottom: 4, trailing: -16)

struct ContentView: View {
    let settings: AppSettings
    let model: NotesModel

    @Environment(\.openSettings) private var openSettings
    @State private var selection: SidebarSelection? = .home
    /// Active filter on the notes list (tag, folder, or smart folder).
    @State private var noteFilter: NoteListFilter?
    /// Whether the conflict-resolution sheet is showing.
    @State private var showConflicts = false

    /// True when a note is open in the detail pane (its own toolbar then shows
    /// the settings gear, so ContentView omits it to avoid a duplicate).
    private var isNoteOpen: Bool {
        if case .note = selection { return true }
        return false
    }

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
                        .listRowInsets(sidebarRowInsets)
                    }
                }

                Section {
                    SidebarNavRow(label: "Start", icon: "house", isActive: selection == .home) {
                        selection = .home
                    }
                    .listRowInsets(sidebarFilterRowInsets)
                    // Lives inside the list's scroll view, so it re-forces the thin
                    // overlay scroller on every render (e.g. after folder changes).
                    .thinScrollers()

                    SidebarNavRow(label: "Zadania", icon: "checklist", count: model.activeTaskCount, isActive: selection == .tasks) {
                        selection = .tasks
                    }
                    .listRowInsets(sidebarFilterRowInsets)
                }

                // Kosz in its own section → a gap from Zadania.
                Section {
                    SidebarNavRow(label: "Kosz", icon: "trash", count: model.trashedNotes.count, isActive: selection == .trash) {
                        selection = .trash
                    }
                    .padding(.top, 10)   // vertical only — keeps left alignment intact
                    .listRowInsets(sidebarFilterRowInsets)
                }

                if !settings.allSmartFolders.isEmpty {
                    Section {
                        ForEach(settings.allSmartFolders) { sf in
                            let count = model.notes.filter { sf.matches($0) }.count
                            FolderFilterRow(
                                label: sf.name,
                                icon: sf.icon,
                                count: count,
                                isActive: noteFilter == .smartFolder(sf.id)
                            ) {
                                selection = nil
                                noteFilter = (noteFilter == .smartFolder(sf.id)) ? nil : .smartFolder(sf.id)
                            }
                            .listRowInsets(sidebarFilterRowInsets)
                        }
                    } header: {
                        Text("Inteligentne foldery").listRowInsets(sidebarRowInsets)
                    }
                }

                if !model.categories.isEmpty {
                    Section {
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
                                selection = nil
                                noteFilter = (noteFilter == .folder(folder)) ? nil : .folder(folder)
                            }
                            .listRowInsets(sidebarFilterRowInsets)
                        }
                    } header: {
                        Text("Foldery").listRowInsets(sidebarRowInsets)
                    }
                }

                if !model.tagCounts.isEmpty {
                    Section {
                        ForEach(model.tagCounts, id: \.tag) { entry in
                            TagFilterRow(
                                tag: entry.tag,
                                count: entry.count,
                                isActive: noteFilter == .tag(entry.tag)
                            ) {
                                selection = nil
                                noteFilter = (noteFilter == .tag(entry.tag)) ? nil : .tag(entry.tag)
                            }
                            .listRowInsets(sidebarFilterRowInsets)
                        }
                    } header: {
                        Text("Tagi").listRowInsets(sidebarRowInsets)
                    }
                }

                Section {
                    ForEach(filteredNotes) { note in
                        Button {
                            selection = .note(note.id)
                        } label: {
                            NoteRow(note: note,
                                    coverColor: AppTheme.color(id: model.categoryColorID(of: note)),
                                    isSelected: selection == .note(note.id))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(note.pinned ? "Odepnij" : "Przypnij",
                                   systemImage: note.pinned ? "pin.slash" : "pin") {
                                model.togglePin(note)
                            }
                            categoryColorMenu(for: note)
                            Button("Usuń", role: .destructive) {
                                delete(note)
                            }
                        }
                        .listRowInsets(sidebarFilterRowInsets)
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
                    .listRowInsets(sidebarRowInsets)
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
                MarkdownStyler.checkboxColor = NSColor(settings.theme.accent)
                // Thin overlay scrollers across the app. SwiftUI Lists reset their
                // scroller style on content/layout updates, so re-apply on several
                // staggered passes and whenever a window becomes key or resizes.
                for delay in [0.2, 0.6, 1.2, 2.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { applyOverlayScrollersToAllWindows() }
                }
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                        Task { @MainActor in applyOverlayScrollersToAllWindows() }
                    }
                }
            }
            .onChange(of: settings.themeID) {
                MarkdownStyler.checkboxColor = NSColor(settings.theme.accent)
            }
            // Selecting/deselecting a folder rebuilds the notes list, which resets
            // its scroller back to the (thick) system style — re-thin it right after.
            .onChange(of: noteFilter) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { applyOverlayScrollersToAllWindows() }
            }
            .onChange(of: selection) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { applyOverlayScrollersToAllWindows() }
            }
            // Sidebar badge counts (task count, note count) change when a note is
            // flagged/created/deleted, which likewise resets the sidebar List's
            // scroller and briefly insets the trailing numbers — re-thin it too.
            .onChange(of: model.activeTaskCount) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { applyOverlayScrollersToAllWindows() }
            }
            .onChange(of: model.notes.count) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { applyOverlayScrollersToAllWindows() }
            }
            .sheet(isPresented: $showConflicts) {
                ConflictResolverView(model: model) { showConflicts = false }
            }
            .navigationTitle("NoteM")
            // Inset "window-in-window" sidebar.
            .scrollContentBackground(.hidden)
            .padding(10)
            .background(alignment: .center) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                    .padding(6)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar {
                // Compose button sits near the NoteM title, above the sidebar.
                ToolbarItem(placement: .navigation) {
                    Button(action: addNote) {
                        Label("Nowa notatka", systemImage: "square.and.pencil")
                            .foregroundStyle(settings.theme.accent)
                            .padding(.horizontal, 8)   // widens the toolbar button's capsule
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Nowa notatka")
                }
            }
        } detail: {
            Group {
            switch selection {
            case .home:
                StartView(model: model, accent: settings.theme.accent, layout: settings.startLayout) { noteID in
                    selection = .note(noteID)
                }
            case .tasks:
                TasksView(model: model) { noteID in
                    selection = .note(noteID)
                }
            case .trash:
                TrashView(model: model)
            case .note(let id):
                if let note = model.notes.first(where: { $0.id == id }) {
                    NoteDetailView(note: note, model: model, accent: settings.theme.accent) { targetID in
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
            // Settings gear at the far right — only when no note is open, since
            // the note's own toolbar provides it (with the background toggle).
            .toolbar {
                if !isNoteOpen {
                    ToolbarItem(placement: .primaryAction) {
                        Button { openSettings() } label: {
                            Image(systemName: "gear")
                                .foregroundStyle(settings.theme.accent)
                        }
                        .help("Ustawienia")
                    }
                }
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

/// Sidebar row: note title + last-modified date. When selected it shows the same
/// full-width blue highlight pill as the folder/tag/nav rows.
struct NoteRow: View {
    let note: Note
    var coverColor: Color? = nil
    var isSelected: Bool = false

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
                Text(note.modified.noteMDisplay)
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
            }
            if note.pinned {
                Spacer()
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear))
        )
        .contentShape(Rectangle())
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
                                    Text("Usunięto \(deletedAt.noteMDisplay)")
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
                        .font(.system(size: 20))
                        .foregroundStyle(isActive
                                         ? AnyShapeStyle(.white)
                                         : (iconTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tint)))
                }
                Spacer()
                Text("\(count)")
                    .foregroundStyle(isActive ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
            }
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                Label {
                    Text(tag)
                } icon: {
                    Image(systemName: isActive ? "tag.fill" : "tag")
                        .font(.system(size: 20))
                        .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                }
                Spacer()
                Text("\(count)")
                    .foregroundStyle(isActive ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
            }
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Sidebar navigation row (Start / Zadania / Kosz). Uses its own highlight pill
/// — like the folder/tag rows — instead of the native sidebar selection capsule,
/// so it can hug the left edge without the highlight looking off.
struct SidebarNavRow: View {
    let label: String
    let icon: String
    var count: Int? = nil
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                Label {
                    Text(label)
                } icon: {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                }
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .foregroundStyle(isActive ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(.secondary))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Zadania": one row per note flagged as a task list (via the button on its
/// Start card or in the note's toolbar). Each row is a checkbox + the note title;
/// ticking it off marks the whole note done (a green ✅) and enables a trash
/// button to remove it. Tapping the title opens the note.
struct TasksView: View {
    let model: NotesModel
    let openNote: (UUID) -> Void

    var body: some View {
        Group {
            if model.taskNotes.isEmpty {
                ContentUnavailableView(
                    "Brak zadań",
                    systemImage: "checklist",
                    description: Text("Oznacz notatkę jako listę zadań przyciskiem na kafelku (Start) lub w pasku otwartej notatki, a pojawi się tutaj.")
                )
            } else {
                List {
                    ForEach(model.taskNotes) { note in
                        TaskNoteRow(
                            note: note,
                            onToggleDone: { model.toggleTaskDone(note) },
                            onDelete: { model.delete(note) },
                            onOpen: { openNote(note.id) }
                        )
                    }
                }
            }
        }
        .navigationTitle("Zadania")
    }
}

/// A single row in the "Zadania" view: a bigger, bold-outlined checkbox that
/// turns into a green ✅ when done, the note title, and a trash button that's
/// only active once the task is ticked off.
private struct TaskNoteRow: View {
    let note: Note
    let onToggleDone: () -> Void
    let onDelete: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleDone) {
                if note.taskDone {
                    Text("✅").font(.system(size: 18))
                } else {
                    Image(systemName: "square")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(note.taskDone ? "Oznacz jako niezrobione" : "Oznacz jako zrobione")

            Text(note.title.isEmpty ? "Bez tytułu" : note.title)
                .strikethrough(note.taskDone, color: .secondary)
                .foregroundStyle(note.taskDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)

            Spacer()

            // Delete becomes available only once the task is done.
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(note.taskDone ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .disabled(!note.taskDone)
            .help(note.taskDone ? "Usuń notatkę do kosza" : "Najpierw oznacz jako zrobione")
        }
        .padding(.vertical, 4)
    }
}

/// Layout options for the Start page, chosen in Settings → Wygląd.
enum StartLayout: String, CaseIterable, Identifiable {
    case sections, columns, stacks
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sections: return "Sekcje"
        case .columns:  return "Kolumny"
        case .stacks:   return "Stosy"
        }
    }
}

/// Start page: a searchable gallery of every note, shown on launch. Typing in
/// the search field filters by title, tags and content; clicking a card opens
/// the note. The gallery can be laid out as sections, columns or macOS-style
/// stacks (chosen in Settings).
struct StartView: View {
    let model: NotesModel
    var accent: Color = .accentColor
    var layout: StartLayout = .sections
    let openNote: (UUID) -> Void

    @State private var query = ""
    /// Note contents, cached once so search and previews don't re-read files on
    /// every keystroke.
    @State private var contentIndex: [UUID: String] = [:]
    /// In the stacks layout: which stack (bucket title) is opened, if any.
    @State private var openedStack: String?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    private var results: [Note] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.notes }
        return model.notes.filter { note in
            note.title.lowercased().contains(q)
                || note.tags.contains { $0.lowercased().contains(q) }
                || (contentIndex[note.id]?.lowercased().contains(q) ?? false)
        }
    }

    /// Results split into date buckets: today, yesterday, last 7 days, older.
    /// Empty buckets are omitted.
    private var sections: [(title: String, notes: [Note])] {
        let cal = Calendar.current
        let weekAgo = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date()))
        var today: [Note] = [], yesterday: [Note] = [], week: [Note] = [], older: [Note] = []
        for note in results {
            if cal.isDateInToday(note.modified) { today.append(note) }
            else if cal.isDateInYesterday(note.modified) { yesterday.append(note) }
            else if let weekAgo, note.modified >= weekAgo { week.append(note) }
            else { older.append(note) }
        }
        var out: [(String, [Note])] = []
        if !today.isEmpty { out.append(("Dzisiaj", today)) }
        if !yesterday.isEmpty { out.append(("Wczoraj", yesterday)) }
        if !week.isEmpty { out.append(("Ostatnie 7 dni", week)) }
        if !older.isEmpty { out.append(("Starsze", older)) }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            if results.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Brak notatek" : "Brak wyników",
                    systemImage: query.isEmpty ? "note.text" : "magnifyingglass",
                    description: Text(query.isEmpty
                                      ? "Utwórz pierwszą notatkę przyciskiem „Nowa notatka”."
                                      : "Żadna notatka nie pasuje do „\(query)”.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch layout {
                case .sections: sectionsView
                case .columns:  columnsView
                case .stacks:   stacksView
                }
            }
        }
        .navigationTitle("Start")
        .onAppear { buildIndex() }
        .onChange(of: model.notes.count) { buildIndex() }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Szukaj w notatkach…", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Wyczyść")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
        .padding(16)
    }

    // MARK: - Layouts

    private var sectionsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.title) { section in
                    Section {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(section.notes) { note in card(for: note) }
                        }
                    } header: {
                        Text(section.title)
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .background(.bar)
                    }
                }
            }
            .padding([.horizontal, .bottom], 16)
            .thinScrollers()
        }
    }

    private var columnsView: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Text(section.title).font(.title3.bold())
                            Text("\(section.notes.count)")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(section.notes) { note in card(for: note) }
                            }
                            .thinScrollers()
                        }
                    }
                    .frame(width: 196)
                }
            }
            .padding(16)
            .thinScrollers()
        }
    }

    @ViewBuilder
    private var stacksView: some View {
        if let opened = openedStack, let bucket = sections.first(where: { $0.title == opened }) {
            // Drilled into a stack: back arrow + that bucket's notes.
            VStack(alignment: .leading, spacing: 0) {
                Button { openedStack = nil } label: {
                    Label("\(bucket.title) (\(bucket.notes.count))", systemImage: "chevron.left")
                        .font(.headline)
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .help("Wróć do stosów")
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(bucket.notes) { note in card(for: note) }
                    }
                    .padding([.horizontal, .bottom], 16)
                    .thinScrollers()
                }
            }
        } else {
            // Overview: each bucket as a pile you can click to open.
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 20)], spacing: 20) {
                    ForEach(sections, id: \.title) { section in
                        Button { openedStack = section.title } label: {
                            StackTile(title: section.title, count: section.notes.count, accent: accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
                .thinScrollers()
            }
        }
    }

    // MARK: - Reusable pieces

    private func card(for note: Note) -> some View {
        // Open on tap via a gesture (not a wrapping Button) so the task-list
        // toggle button inside the card reliably gets its own clicks on macOS.
        NoteCard(
            note: note,
            accent: accent,
            coverColor: AppTheme.color(id: model.categoryColorID(of: note)),
            snippet: contentIndex[note.id] ?? "",
            query: query,
            isTaskList: note.isTaskList,
            onToggleTaskList: { model.toggleTaskList(note) }
        )
        .contentShape(Rectangle())
        .onTapGesture { openNote(note.id) }
    }

    private func buildIndex() {
        var index: [UUID: String] = [:]
        for note in model.notes {
            index[note.id] = model.content(for: note)
        }
        contentIndex = index
    }
}

/// A macOS-style "stack": a pile of offset cards with the bucket name and count.
struct StackTile: View {
    let title: String
    let count: Int
    var accent: Color = .accentColor

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                // Back cards, offset to suggest a pile.
                RoundedRectangle(cornerRadius: 14)
                    .fill(accent.opacity(0.12))
                    .frame(width: 120, height: 120)
                    .offset(x: 10, y: 10)
                RoundedRectangle(cornerRadius: 14)
                    .fill(accent.opacity(0.18))
                    .frame(width: 120, height: 120)
                    .offset(x: 5, y: 5)
                RoundedRectangle(cornerRadius: 14)
                    .fill(accent.opacity(0.28))
                    .frame(width: 120, height: 120)
                    .overlay(
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(accent)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.4)))
            }
            .frame(width: 140, height: 140, alignment: .topLeading)

            VStack(spacing: 2) {
                Text(title).font(.headline)
                Text("\(count) \(count == 1 ? "notatka" : "notatek")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// A note tile on the start page: title, date, tags and a short preview. When
/// searching, the preview centres on the first match and highlights the term.
struct NoteCard: View {
    let note: Note
    var accent: Color = .accentColor
    var coverColor: Color? = nil
    /// Full note content, used to show a short text preview.
    var snippet: String = ""
    /// Current search query, so matches can be highlighted.
    var query: String = ""
    /// Whether the note is flagged as a planned task list.
    var isTaskList: Bool = false
    /// Toggles the task-list flag (button on the card); no-op by default.
    var onToggleTaskList: () -> Void = {}

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// Preview text: when searching, a window around the first match; otherwise
    /// the note's opening lines.
    private var previewText: String {
        let flat = snippet
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty, let match = flat.lowercased().range(of: q) else {
            return String(flat.prefix(160))
        }
        let startOffset = flat.lowercased().distance(from: flat.startIndex, to: match.lowerBound)
        let from = max(0, startOffset - 40)
        let start = flat.index(flat.startIndex, offsetBy: from)
        let window = String(flat[start...].prefix(200))
        return (from > 0 ? "…" : "") + window
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let coverColor {
                RoundedRectangle(cornerRadius: 3)
                    .fill(coverColor)
                    .frame(width: 6)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(highlighted(note.title))
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if note.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(accent)
                    }
                    // Mark / unmark this note as a planned task list. Its own
                    // button so clicking it doesn't open the note.
                    Button(action: onToggleTaskList) {
                        Image(systemName: isTaskList ? "checklist.checked" : "checklist")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(accent)
                            .opacity(isTaskList ? 1 : 0.6)
                            .padding(4)
                            .background(
                                Circle().fill(isTaskList ? accent.opacity(0.15) : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(isTaskList ? "Usuń oznaczenie listy zadań" : "Oznacz jako listę zadań")
                }
                if !previewText.isEmpty {
                    Text(highlighted(previewText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text(note.modified.noteMDisplay)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if !note.tags.isEmpty {
                    Text(note.tags.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption2)
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Highlights every case-insensitive occurrence of the query in `text`.
    private func highlighted(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        let q = trimmedQuery
        guard !q.isEmpty else { return attr }
        var searchRange = attr.startIndex..<attr.endIndex
        while let range = attr[searchRange].range(of: q, options: .caseInsensitive) {
            attr[range].foregroundColor = accent
            attr[range].inlinePresentationIntent = .stronglyEmphasized
            searchRange = range.upperBound..<attr.endIndex
        }
        return attr
    }
}

#Preview {
    ContentView(settings: AppSettings(), model: NotesModel())
}
