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

/// Ultra-thin (1 pt) scroller used *only* by the Start-page columns. Unlike the
/// invisible `ThinScroller`, it stays visible and legacy-styled so each column
/// still shows its scroll position, while the 1 pt width keeps every column the
/// same visible content width.
final class StartColumnScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 1 }

    override func draw(_ dirtyRect: NSRect) { drawKnob() }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}   // no track
    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.width > 0, knob.height > 0 else { return }
        NSColor.secondaryLabelColor.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.width / 2, yRadius: knob.width / 2).fill()
    }
}

/// Installs the 1 pt always-visible scroller on a Start-page column's scroll view.
@MainActor private func applyStartColumnScroller(to scroll: NSScrollView) {
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .legacy       // always visible (don't auto-hide)
    scroll.autohidesScrollers = false
    if !(scroll.verticalScroller is StartColumnScroller) {
        scroll.verticalScroller = StartColumnScroller()
    }
}

/// Finds the enclosing scroll view of a Start-page column and gives it the 1 pt
/// scroller, retrying on a few passes since the scroll view may not exist yet.
private struct StartColumnScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        for delay in [0.0, 0.15, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let scroll = view.enclosingScrollView { applyStartColumnScroller(to: scroll) }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let scroll = nsView.enclosingScrollView { applyStartColumnScroller(to: scroll) }
        }
    }
}

extension View {
    /// Apply to the content *inside* a Start-page column's `ScrollView`.
    func startColumnScroller() -> some View {
        background(StartColumnScrollerConfigurator().frame(width: 0, height: 0))
    }
}

/// Applies the thin overlay scroller to a single scroll view.
@MainActor private func applyThinScroller(to scroll: NSScrollView) {
    // Leave the Start-page columns' dedicated 1 pt scroller untouched.
    if scroll.verticalScroller is StartColumnScroller { return }
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
    /// App-wide display format for note dates, e.g. "09.07.26r. - 09:17" (PL) or
    /// "09.07.26 - 09:17" (EN). Follows the app language.
    var noteMDisplay: String {
        (Loc.language == .pl ? Self.plFormatter : Self.enFormatter).string(from: self)
    }

    private static let plFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.dateFormat = "dd.MM.yy'r.' - HH:mm"
        return formatter
    }()

    private static let enFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "dd.MM.yy - HH:mm"
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
                        Text(p.title(settings))
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
                case .general:        GeneralSettingsView(settings: settings)
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

    func title(_ s: AppSettings) -> String {
        switch self {
        case .general:        return s.t("Ogólne", "General")
        case .appearance:     return s.t("Wygląd", "Appearance")
        case .categorization: return s.t("Katalogowanie", "Filing")
        case .smartFolders:   return s.t("Inteligentne foldery", "Smart folders")
        case .quickCapture:   return "Quick Capture"
        case .sync:           return s.t("Synchronizacja", "Sync")
        case .trash:          return s.t("Kosz", "Trash")
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
    @Bindable var settings: AppSettings

    /// One keyboard shortcut row.
    private struct Shortcut: Identifiable {
        let keys: String
        let title: String
        var id: String { keys + title }
    }

    private struct Group: Identifiable {
        let name: String
        let shortcuts: [Shortcut]
        var id: String { name }
    }

    private var groups: [Group] {
        [
            Group(name: settings.t("Formatowanie", "Formatting"), shortcuts: [
                Shortcut(keys: "⌘B", title: settings.t("Pogrubienie", "Bold")),
                Shortcut(keys: "⌘I", title: settings.t("Kursywa", "Italic")),
                Shortcut(keys: "⌘1", title: settings.t("Nagłówek 1", "Heading 1")),
                Shortcut(keys: "⌘2", title: settings.t("Nagłówek 2", "Heading 2")),
                Shortcut(keys: "⌘3", title: settings.t("Nagłówek 3", "Heading 3")),
                Shortcut(keys: "⌘⇧L", title: settings.t("Lista zadań (checklista)", "Checklist"))
            ]),
            Group(name: settings.t("Notatka", "Note"), shortcuts: [
                Shortcut(keys: "⌘K", title: settings.t("Paleta poleceń", "Command palette")),
                Shortcut(keys: "⌘F", title: settings.t("Szukaj w notatce", "Find in note")),
                Shortcut(keys: "⌘Z", title: settings.t("Cofnij", "Undo")),
                Shortcut(keys: "⌘⇧Z", title: settings.t("Ponów", "Redo")),
                Shortcut(keys: "⌘C", title: settings.t("Kopiuj (także zaznaczoną grafikę)", "Copy (incl. selected image)")),
                Shortcut(keys: "⌘X", title: settings.t("Wytnij (także zaznaczoną grafikę)", "Cut (incl. selected image)")),
                Shortcut(keys: "⌘V", title: settings.t("Wklej", "Paste"))
            ]),
            Group(name: settings.t("Grafika", "Image"), shortcuts: [
                Shortcut(keys: "⌘O", title: settings.t("Dopasuj zaznaczoną grafikę do szerokości okna",
                                                       "Fit selected image to window width"))
            ])
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(settings.t("Język", "Language"))
                .font(.headline)
            Picker(settings.t("Język interfejsu", "Interface language"), selection: $settings.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320, alignment: .leading)

            Divider().padding(.vertical, 4)

            Text(settings.t("Pisownia", "Spelling"))
                .font(.headline)
            Toggle(settings.t("Sprawdzanie pisowni (podkreśla błędy)", "Check spelling (underline mistakes)"),
                   isOn: $settings.spellCheckEnabled)
            Toggle(settings.t("Automatyczna korekta (poprawia błędy podczas pisania)",
                              "Auto-correct (fix mistakes while typing)"),
                   isOn: $settings.autocorrectEnabled)
                .disabled(!settings.spellCheckEnabled)
            Text(settings.t("Słownik zależy od wybranego języka. Działa w notatniku i w szybkiej notatce.",
                           "The dictionary follows the selected language. Works in the note editor and quick capture."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Text(settings.t("Skróty klawiszowe", "Keyboard shortcuts"))
                .font(.headline)
            Text(settings.t("Skróty działają w edytorze notatki oraz w szybkiej notatce.",
                           "Shortcuts work in the note editor and quick capture."))
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(groups) { group in
                    Section(group.name) {
                        ForEach(group.shortcuts) { shortcut in
                            HStack(spacing: 12) {
                                Text(shortcut.keys)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                                    .frame(minWidth: 56, alignment: .center)
                                Text(shortcut.title)
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            Text(settings.t("Inteligentne foldery", "Smart folders"))
                .font(.headline)
            Text(settings.t("Inteligentne foldery to zapisane wyszukiwania, które automatycznie zbierają pasujące notatki. "
                            + "Dwa wbudowane foldery (Dzisiejsze, Przypięte) są zawsze dostępne.",
                            "Smart folders are saved searches that automatically collect matching notes. "
                            + "Two built-in folders (Today, Pinned) are always available."))
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                Section(settings.t("Wbudowane", "Built-in")) {
                    ForEach(SmartFolder.predefined) { sf in
                        Label(sf.displayName(settings), systemImage: sf.icon)
                            .foregroundStyle(.secondary)
                    }
                }
                if !settings.smartFolders.isEmpty {
                    Section(settings.t("Własne", "Custom")) {
                        ForEach(settings.smartFolders) { sf in
                            Label(sf.displayName(settings), systemImage: sf.icon)
                        }
                        .onDelete { settings.smartFolders.remove(atOffsets: $0) }
                    }
                }
            }
            .frame(minHeight: 160)

            if showAdd {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField(settings.t("Nazwa folderu", "Folder name"), text: $newName)
                            .textFieldStyle(.roundedBorder)
                        TextField(settings.t("Tag (np. projekt)", "Tag (e.g. project)"), text: $newTag)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button(settings.t("Anuluj", "Cancel")) { showAdd = false; newName = ""; newTag = "" }
                            Spacer()
                            Button(settings.t("Dodaj", "Add")) { commitAdd() }
                                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                          || newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            } else {
                Button { showAdd = true } label: {
                    Label(settings.t("Dodaj folder (tag contains)", "Add folder (tag contains)"), systemImage: "plus")
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
    case attachments
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
    /// Whether the command palette (⌘K) is showing.
    @State private var showPalette = false

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
        case .smartFolder(let id): return settings.allSmartFolders.first(where: { $0.id == id })?.displayName(settings)
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
                            Label(settings.t("Konflikty synchronizacji: \(model.conflicts.count)",
                                             "Sync conflicts: \(model.conflicts.count)"),
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help(settings.t("Rozwiąż konflikty z innego Maca", "Resolve conflicts from another Mac"))
                        .listRowInsets(sidebarRowInsets)
                    }
                }

                Section {
                    SidebarNavRow(label: settings.t("Start", "Start"), icon: "house", isActive: selection == .home) {
                        selection = .home
                    }
                    .listRowInsets(sidebarFilterRowInsets)
                    // Lives inside the list's scroll view, so it re-forces the thin
                    // overlay scroller on every render (e.g. after folder changes).
                    .thinScrollers()

                    SidebarNavRow(label: settings.t("Zadania", "Tasks"), icon: "checklist", count: model.activeTaskCount, isActive: selection == .tasks) {
                        selection = .tasks
                    }
                    .listRowInsets(sidebarFilterRowInsets)

                    SidebarNavRow(label: settings.t("Załączniki", "Attachments"), icon: "paperclip", count: model.attachments.count, isActive: selection == .attachments) {
                        selection = .attachments
                    }
                    .listRowInsets(sidebarFilterRowInsets)
                }

                // Trash in its own section → a gap from Tasks.
                Section {
                    SidebarNavRow(label: settings.t("Kosz", "Trash"), icon: "trash", count: model.trashedNotes.count, isActive: selection == .trash) {
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
                                label: sf.displayName(settings),
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
                        Text(settings.t("Inteligentne foldery", "Smart folders")).listRowInsets(sidebarRowInsets)
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
                        Text(settings.t("Foldery", "Folders")).listRowInsets(sidebarRowInsets)
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
                        Text(settings.t("Tagi", "Tags")).listRowInsets(sidebarRowInsets)
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
                        // Native right-click menu instead of SwiftUI's `.contextMenu`,
                        // which draws an unremovable blue highlight ring on the List row.
                        .overlay {
                            NoteRightClickMenu(
                                pinned: note.pinned,
                                category: model.category(of: note),
                                onTogglePin: { model.togglePin(note) },
                                onSetCategoryColor: { model.setCategoryColor($0, for: note) },
                                onDelete: { delete(note) }
                            )
                        }
                        .listRowInsets(sidebarFilterRowInsets)
                    }
                } header: {
                    HStack {
                        Text(settings.t("Notatki", "Notes"))
                        if let label = activeFilterLabel {
                            Spacer()
                            Button {
                                noteFilter = nil
                            } label: {
                                Label(label, systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .help(settings.t("Wyczyść filtr", "Clear filter"))
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
                        Label(settings.t("Nowa notatka", "New note"), systemImage: "square.and.pencil")
                            .foregroundStyle(settings.theme.accent)
                            .padding(.horizontal, 8)   // widens the toolbar button's capsule
                    }
                    .labelStyle(.titleAndIcon)
                    .help(settings.t("Nowa notatka", "New note"))
                }
            }
        } detail: {
            Group {
            switch selection {
            case .home:
                StartView(model: model, settings: settings, accent: settings.theme.accent, layout: settings.startLayout) { noteID in
                    selection = .note(noteID)
                }
            case .tasks:
                TasksView(model: model, settings: settings) { noteID in
                    selection = .note(noteID)
                }
            case .attachments:
                AttachmentsView(model: model, settings: settings) { noteID in
                    selection = .note(noteID)
                }
            case .trash:
                TrashView(model: model, settings: settings)
            case .note(let id):
                if let note = model.notes.first(where: { $0.id == id }) {
                    NoteDetailView(note: note, model: model, settings: settings, accent: settings.theme.accent) { targetID in
                        selection = .note(targetID)
                    }
                    .id(note.id)
                } else {
                    ContentUnavailableView(settings.t("Wybierz notatkę", "Select a note"), systemImage: "note.text")
                }
            case .none:
                if noteFilter != nil {
                    FilteredNotesView(
                        title: activeFilterLabel ?? settings.t("Notatki", "Notes"),
                        notes: filteredNotes,
                        model: model,
                        settings: settings,
                        accent: settings.theme.accent
                    ) { id in
                        selection = .note(id)
                    }
                } else {
                    ContentUnavailableView(settings.t("Wybierz notatkę", "Select a note"), systemImage: "note.text")
                }
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
                        .help(settings.t("Ustawienia", "Settings"))
                    }
                }
            }
        }
        .tint(settings.theme.accent)
        // Hidden button so ⌘K works anywhere in the window (Priorytet 5).
        .background(
            Button("") { showPalette.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
        .overlay {
            if showPalette {
                CommandPaletteOverlay(
                    settings: settings,
                    accent: settings.theme.accent,
                    items: paletteItems,
                    onClose: { showPalette = false }
                )
            }
        }
    }

    /// Actions offered by the ⌘K palette: global commands, contextual commands
    /// for the open note, then every note as a jump target (fuzzy-filtered).
    private var paletteItems: [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        items.append(CommandPaletteItem(
            id: "new-note",
            title: settings.t("Nowa notatka", "New note"),
            icon: "square.and.pencil"
        ) { addNote() })
        items.append(CommandPaletteItem(
            id: "go-home",
            title: settings.t("Przejdź: Start", "Go to: Start"),
            icon: "house"
        ) { noteFilter = nil; selection = .home })
        items.append(CommandPaletteItem(
            id: "go-tasks",
            title: settings.t("Przejdź: Zadania", "Go to: Tasks"),
            icon: "checklist"
        ) { noteFilter = nil; selection = .tasks })
        items.append(CommandPaletteItem(
            id: "go-attachments",
            title: settings.t("Przejdź: Załączniki", "Go to: Attachments"),
            icon: "paperclip"
        ) { noteFilter = nil; selection = .attachments })
        items.append(CommandPaletteItem(
            id: "go-trash",
            title: settings.t("Przejdź: Kosz", "Go to: Trash"),
            icon: "trash"
        ) { noteFilter = nil; selection = .trash })

        // Contextual commands for the currently open note.
        if case .note(let id) = selection, let note = model.notes.first(where: { $0.id == id }) {
            items.append(CommandPaletteItem(
                id: "note-pin",
                title: note.pinned ? settings.t("Odepnij notatkę", "Unpin note")
                                   : settings.t("Przypnij notatkę", "Pin note"),
                subtitle: note.title,
                icon: note.pinned ? "pin.slash" : "pin"
            ) { model.togglePin(note) })
            items.append(CommandPaletteItem(
                id: "note-tasklist",
                title: note.isTaskList ? settings.t("Usuń z zadań", "Remove from tasks")
                                       : settings.t("Oznacz jako listę zadań", "Mark as task list"),
                subtitle: note.title,
                icon: note.isTaskList ? "checklist.checked" : "checklist"
            ) { model.toggleTaskList(note) })
        }

        items.append(CommandPaletteItem(
            id: "open-settings",
            title: settings.t("Otwórz ustawienia", "Open settings"),
            icon: "gear"
        ) { openSettings() })

        // Jump to any note by (fuzzy) title.
        for note in model.notes where !note.title.isEmpty {
            let category = model.category(of: note)
            items.append(CommandPaletteItem(
                id: "note-\(note.id.uuidString)",
                title: note.title,
                subtitle: category.isEmpty ? settings.t("Notatka", "Note") : category,
                icon: "note.text",
                isNote: true
            ) { noteFilter = nil; selection = .note(note.id) })
        }
        return items
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

/// Main-window gallery of the notes matching the active sidebar filter (a smart
/// folder like "Dzisiejsze", a physical folder, or a tag). Clicking a card opens
/// the note. Shown when a filter is active but no single note is selected.
struct FilteredNotesView: View {
    let title: String
    let notes: [Note]
    let model: NotesModel
    let settings: AppSettings
    var accent: Color = .accentColor
    let openNote: (UUID) -> Void

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    var body: some View {
        Group {
            if notes.isEmpty {
                ContentUnavailableView(
                    settings.t("Brak notatek", "No notes"),
                    systemImage: "folder",
                    description: Text(settings.t("Nie ma tu jeszcze żadnych notatek.", "There are no notes here yet."))
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(notes) { note in
                            NoteCard(
                                note: note,
                                settings: settings,
                                accent: accent,
                                coverColor: AppTheme.color(id: model.categoryColorID(of: note))
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { openNote(note.id) }
                        }
                    }
                    .padding(16)
                    .thinScrollers()
                }
            }
        }
        .navigationTitle(title)
    }
}

/// Trash view: deleted notes with restore / permanent-delete actions.
struct TrashView: View {
    let model: NotesModel
    let settings: AppSettings

    var body: some View {
        Group {
            if model.trashedNotes.isEmpty {
                ContentUnavailableView(
                    settings.t("Kosz jest pusty", "Trash is empty"),
                    systemImage: "trash",
                    description: Text(settings.t("Usunięte notatki trafiają tutaj i można je przywrócić.",
                                                "Deleted notes land here and can be restored."))
                )
            } else {
                List {
                    ForEach(model.trashedNotes) { note in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title)
                                    .lineLimit(1)
                                if let deletedAt = note.deletedAt {
                                    Text(settings.t("Usunięto \(deletedAt.noteMDisplay)", "Deleted \(deletedAt.noteMDisplay)"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(settings.t("Przywróć", "Restore")) { model.restore(note) }
                            Button(settings.t("Usuń trwale", "Delete permanently"), role: .destructive) { model.deletePermanently(note) }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(settings.t("Kosz", "Trash"))
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
        .overlay {
            // Native right-click colour menu instead of SwiftUI's `.contextMenu`,
            // which on macOS draws a blue highlight ring that can't be removed.
            if let onSetColor { FolderColorMenu(onSetColor: onSetColor) }
        }
    }
}

/// Transparent overlay that shows the folder-icon colour menu on right-click via
/// a native `NSMenu` — no SwiftUI context-menu highlight ring. It stays invisible
/// to left-clicks and hover, so the row's button keeps working normally.
private struct FolderColorMenu: NSViewRepresentable {
    let onSetColor: (String?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = RightClickView()
        view.onSetColor = onSetColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? RightClickView)?.onSetColor = onSetColor
    }

    final class RightClickView: NSView {
        var onSetColor: ((String?) -> Void)?

        // Claim only right-mouse events; pass everything else (left-click, hover)
        // through to the SwiftUI button underneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            let menu = NSMenu()
            let parent = NSMenuItem(title: Loc.t("Kolor ikony folderu", "Folder icon color"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for theme in AppTheme.all {
                let item = NSMenuItem(title: theme.name, action: #selector(pick(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = theme.id
                item.image = Self.swatch(NSColor(theme.accent))
                submenu.addItem(item)
            }
            submenu.addItem(.separator())
            let byDefault = NSMenuItem(title: Loc.t("Domyślny", "Default"), action: #selector(pickDefault), keyEquivalent: "")
            byDefault.target = self
            submenu.addItem(byDefault)
            parent.submenu = submenu
            menu.addItem(parent)
            // Pop up detached from this view (screen coords, `in: nil`): anchoring
            // the menu to `self` makes the enclosing List's NSTableView draw a blue
            // highlight ring around the row. Detaching avoids that ring entirely.
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }

        @objc private func pick(_ sender: NSMenuItem) { onSetColor?(sender.representedObject as? String) }
        @objc private func pickDefault() { onSetColor?(nil) }

        /// A small filled-circle colour swatch for a menu item.
        private static func swatch(_ color: NSColor) -> NSImage {
            let size = NSSize(width: 12, height: 12)
            let image = NSImage(size: size)
            image.lockFocus()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
            image.unlockFocus()
            return image
        }
    }
}

/// Transparent overlay giving a note row its right-click menu via a native
/// `NSMenu` (pin, folder colour, delete) — avoids SwiftUI `.contextMenu`'s
/// unremovable blue highlight ring on the List row.
private struct NoteRightClickMenu: NSViewRepresentable {
    let pinned: Bool
    let category: String
    let onTogglePin: () -> Void
    let onSetCategoryColor: (String?) -> Void
    let onDelete: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = RightClickView()
        view.configure(pinned: pinned, category: category,
                       onTogglePin: onTogglePin,
                       onSetCategoryColor: onSetCategoryColor,
                       onDelete: onDelete)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? RightClickView)?.configure(pinned: pinned, category: category,
                                               onTogglePin: onTogglePin,
                                               onSetCategoryColor: onSetCategoryColor,
                                               onDelete: onDelete)
    }

    final class RightClickView: NSView {
        private var pinned = false
        private var category = ""
        private var onTogglePin: (() -> Void)?
        private var onSetCategoryColor: ((String?) -> Void)?
        private var onDelete: (() -> Void)?

        func configure(pinned: Bool, category: String,
                       onTogglePin: @escaping () -> Void,
                       onSetCategoryColor: @escaping (String?) -> Void,
                       onDelete: @escaping () -> Void) {
            self.pinned = pinned
            self.category = category
            self.onTogglePin = onTogglePin
            self.onSetCategoryColor = onSetCategoryColor
            self.onDelete = onDelete
        }

        // Claim only right-mouse events; pass everything else (left-click, hover)
        // through to the SwiftUI button underneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            let menu = NSMenu()

            let pin = NSMenuItem(title: pinned ? Loc.t("Odepnij", "Unpin") : Loc.t("Przypnij", "Pin"),
                                 action: #selector(togglePin), keyEquivalent: "")
            pin.target = self
            pin.image = NSImage(systemSymbolName: pinned ? "pin.slash" : "pin",
                                accessibilityDescription: nil)
            menu.addItem(pin)

            // Folder-colour submenu — only for notes that live in a category folder.
            if !category.isEmpty {
                let parent = NSMenuItem(title: Loc.t("Kolor folderu „\(category)”", "Color of folder “\(category)”"),
                                        action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for theme in AppTheme.all {
                    let item = NSMenuItem(title: theme.name, action: #selector(pickColor(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = theme.id
                    item.image = Self.swatch(NSColor(theme.accent))
                    submenu.addItem(item)
                }
                submenu.addItem(.separator())
                let none = NSMenuItem(title: Loc.t("Brak koloru", "No color"), action: #selector(pickNoColor), keyEquivalent: "")
                none.target = self
                submenu.addItem(none)
                parent.submenu = submenu
                menu.addItem(parent)
            }

            menu.addItem(.separator())
            let del = NSMenuItem(title: Loc.t("Usuń", "Delete"), action: #selector(deleteNote), keyEquivalent: "")
            del.target = self
            del.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            menu.addItem(del)

            // Detached pop-up (screen coords, `in: nil`) so the List's NSTableView
            // doesn't draw a highlight ring around the row.
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }

        @objc private func togglePin() { onTogglePin?() }
        @objc private func pickColor(_ sender: NSMenuItem) { onSetCategoryColor?(sender.representedObject as? String) }
        @objc private func pickNoColor() { onSetCategoryColor?(nil) }
        @objc private func deleteNote() { onDelete?() }

        /// A small filled-circle colour swatch for a menu item.
        private static func swatch(_ color: NSColor) -> NSImage {
            let size = NSSize(width: 12, height: 12)
            let image = NSImage(size: size)
            image.lockFocus()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
            image.unlockFocus()
            return image
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
    let settings: AppSettings
    let openNote: (UUID) -> Void

    var body: some View {
        Group {
            if model.taskNotes.isEmpty {
                ContentUnavailableView(
                    settings.t("Brak zadań", "No tasks"),
                    systemImage: "checklist",
                    description: Text(settings.t(
                        "Oznacz notatkę jako listę zadań przyciskiem na kafelku (Start) lub w pasku otwartej notatki, a pojawi się tutaj.",
                        "Mark a note as a task list using the button on its card (Start) or in the open note's toolbar, and it will show up here."))
                )
            } else {
                List {
                    ForEach(model.taskNotes) { note in
                        TaskNoteRow(
                            note: note,
                            settings: settings,
                            onToggleDone: { model.toggleTaskDone(note) },
                            onDelete: { model.delete(note) },
                            onOpen: { openNote(note.id) }
                        )
                    }
                }
            }
        }
        .navigationTitle(settings.t("Zadania", "Tasks"))
    }
}

/// A single row in the "Zadania" view: a bigger, bold-outlined checkbox that
/// turns into a green ✅ when done, the note title, and a trash button that's
/// only active once the task is ticked off.
private struct TaskNoteRow: View {
    let note: Note
    let settings: AppSettings
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
            .help(note.taskDone ? settings.t("Oznacz jako niezrobione", "Mark as not done")
                                : settings.t("Oznacz jako zrobione", "Mark as done"))

            Text(note.title.isEmpty ? settings.t("Bez tytułu", "Untitled") : note.title)
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
            .help(note.taskDone ? settings.t("Usuń notatkę do kosza", "Move note to trash")
                                : settings.t("Najpierw oznacz jako zrobione", "Mark as done first"))
        }
        .padding(.vertical, 4)
    }
}

/// "Załączniki": every image, file and link found across all notes, grouped by
/// kind. Each row shows the item and the note it lives in; tapping opens that
/// note, and the arrow button opens the file/link itself.
struct AttachmentsView: View {
    let model: NotesModel
    let settings: AppSettings
    let openNote: (UUID) -> Void

    /// Fixed section order: images, then files, then links.
    private let order: [AttachmentRef.Kind] = [.image, .file, .link]

    private func items(_ kind: AttachmentRef.Kind) -> [AttachmentRef] {
        model.attachments.filter { $0.kind == kind }
    }

    var body: some View {
        Group {
            if model.attachments.isEmpty {
                ContentUnavailableView(
                    settings.t("Brak załączników", "No attachments"),
                    systemImage: "paperclip",
                    description: Text(settings.t(
                        "Dodaj zdjęcie lub plik do notatki (przeciągnij i upuść), albo wpisz link — pojawią się tutaj z odnośnikiem do notatki.",
                        "Add an image or file to a note (drag & drop), or type a link — they'll appear here with a link back to the note."))
                )
            } else {
                List {
                    ForEach(order, id: \.self) { kind in
                        let refs = items(kind)
                        if !refs.isEmpty {
                            Section(kind.sectionTitle(settings)) {
                                ForEach(refs) { ref in
                                    AttachmentRow(
                                        ref: ref,
                                        settings: settings,
                                        fileURL: fileURL(for: ref),
                                        onOpen: { openNote(ref.noteID) }
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(settings.t("Załączniki", "Attachments"))
    }

    /// Absolute URL of a local attachment file (`nil` for links).
    private func fileURL(for ref: AttachmentRef) -> URL? {
        guard ref.kind != .link,
              let note = model.notes.first(where: { $0.id == ref.noteID }) else { return nil }
        return model.noteFolder(for: note).appendingPathComponent(ref.target)
    }
}

/// A single row in the "Załączniki" view: a thumbnail (images) or icon, the
/// item's label, the note it belongs to, and a button to open the file/link.
private struct AttachmentRow: View {
    let ref: AttachmentRef
    let settings: AppSettings
    let fileURL: URL?
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                thumbnail
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(ref.label)
                        .lineLimit(1)
                        .truncationMode(ref.kind == .link ? .middle : .tail)
                    Text(settings.t("w: ", "in: ") + (ref.noteTitle.isEmpty ? settings.t("Bez tytułu", "Untitled") : ref.noteTitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: openExternally)
            .help(ref.kind == .link ? settings.t("Otwórz link w przeglądarce", "Open link in browser")
                                    : settings.t("Otwórz podgląd", "Open preview"))

            Button(action: onOpen) {
                Image(systemName: "note.text")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .help(settings.t("Przejdź do notatki, w której się znajduje", "Go to the note it belongs to"))
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if ref.kind == .image, let fileURL, let nsImage = NSImage(contentsOf: fileURL) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: ref.kind.systemImage)
                .font(.system(size: 18))
                .foregroundStyle(.tint)
        }
    }

    /// Opens the link in the browser or the file in its default app / Finder.
    private func openExternally() {
        switch ref.kind {
        case .link:
            if let url = URL(string: ref.target) { NSWorkspace.shared.open(url) }
        case .image, .file:
            if let fileURL { NSWorkspace.shared.open(fileURL) }
        }
    }
}

/// Layout options for the Start page, chosen in Settings → Wygląd.
enum StartLayout: String, CaseIterable, Identifiable {
    case sections, columns, stacks
    var id: String { rawValue }
    func label(_ s: AppSettings) -> String {
        switch self {
        case .sections: return s.t("Sekcje", "Sections")
        case .columns:  return s.t("Kolumny", "Columns")
        case .stacks:   return s.t("Stosy", "Stacks")
        }
    }
}

/// Start page: a searchable gallery of every note, shown on launch. Typing in
/// the search field filters by title, tags and content; clicking a card opens
/// the note. The gallery can be laid out as sections, columns or macOS-style
/// stacks (chosen in Settings).
struct StartView: View {
    let model: NotesModel
    let settings: AppSettings
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
        if !today.isEmpty { out.append((settings.t("Dzisiaj", "Today"), today)) }
        if !yesterday.isEmpty { out.append((settings.t("Wczoraj", "Yesterday"), yesterday)) }
        if !week.isEmpty { out.append((settings.t("Ostatnie 7 dni", "Last 7 days"), week)) }
        if !older.isEmpty { out.append((settings.t("Starsze", "Older"), older)) }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            if results.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? settings.t("Brak notatek", "No notes") : settings.t("Brak wyników", "No results"),
                    systemImage: query.isEmpty ? "note.text" : "magnifyingglass",
                    description: Text(query.isEmpty
                                      ? settings.t("Utwórz pierwszą notatkę przyciskiem „Nowa notatka”.",
                                                   "Create your first note with the “New note” button.")
                                      : settings.t("Żadna notatka nie pasuje do „\(query)”.",
                                                   "No note matches “\(query)”."))
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
        .navigationTitle(settings.t("Start", "Start"))
        .onAppear { buildIndex() }
        .onChange(of: model.notes.count) { buildIndex() }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(settings.t("Szukaj w notatkach…", "Search notes…"), text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(settings.t("Wyczyść", "Clear"))
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
            HStack(alignment: .top, spacing: 3) {
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Text(section.title).font(.title3.bold())
                            Text("\(section.notes.count)")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        ScrollView {
                            LazyVStack(spacing: 7) {
                                ForEach(section.notes) { note in card(for: note) }
                            }
                            // Dedicated 1 pt always-visible scroller — only here.
                            .startColumnScroller()
                        }
                    }
                    .frame(width: 210)
                }
            }
            .padding(7)
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
                .help(settings.t("Wróć do stosów", "Back to stacks"))
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
                            StackTile(title: section.title, count: section.notes.count, settings: settings, accent: accent)
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
            settings: settings,
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
    let settings: AppSettings
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
                Text("\(count) " + (count == 1 ? settings.t("notatka", "note") : settings.t("notatek", "notes")))
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
    let settings: AppSettings
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
                    .help(isTaskList ? settings.t("Usuń oznaczenie listy zadań", "Remove task-list mark")
                                     : settings.t("Oznacz jako listę zadań", "Mark as task list"))
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
