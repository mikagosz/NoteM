import SwiftUI
import AppKit
import ApplicationServices

/// Which screen corner reveals the quick-capture trigger.
enum QuickCaptureCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: return Loc.t("Lewy górny", "Top left")
        case .topRight: return Loc.t("Prawy górny", "Top right")
        case .bottomLeft: return Loc.t("Lewy dolny", "Bottom left")
        case .bottomRight: return Loc.t("Prawy dolny", "Bottom right")
        }
    }
}

/// Thin wrapper over the Accessibility trust APIs.
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds the app to the Accessibility list.
    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Watches the cursor for any enabled hot corner. Reaching a corner slides out a
/// small icon (like a macOS hot corner); clicking that icon opens the floating
/// capture panel. A corner never opens a note on its own. New notes are created
/// through the normal `NotesModel`, so they flow through the categorization rules
/// just like any other note.
@MainActor
final class QuickCaptureManager {
    static let shared = QuickCaptureManager()

    private weak var model: NotesModel?
    private weak var settings: AppSettings?

    private var keyGlobalMonitor: Any?
    private var keyLocalMonitor: Any?
    private var mouseGlobalMonitor: Any?
    private var mouseLocalMonitor: Any?

    /// All capture panels currently on screen. Multiple can coexist so opening
    /// a second note never dismisses the first.
    private var panels: [QuickCapturePanel] = []

    /// The little corner icon, present only while the cursor is in a corner.
    private var triggerPanel: QuickCaptureTriggerPanel?
    /// Which corner the icon is currently shown for (also where a click opens).
    private var triggerCorner: QuickCaptureCorner?
    /// After a click opens a note, keep the icon hidden for that corner until the
    /// cursor leaves its zone, so it doesn't pop back up over the fresh note.
    private var suppressedCorner: QuickCaptureCorner?

    /// The cursor must get this close to the exact corner to reveal the icon —
    /// small, so it only appears once you've really hit the corner.
    private let cornerTrigger: CGFloat = 4
    /// Once shown, the icon stays visible within this larger radius, so you can
    /// move off the corner onto the icon to click it without it vanishing.
    private let cornerKeep: CGFloat = 80

    /// Global shortcut that opens the capture panel directly: ⌥⌘N.
    private let hotKeyCode: UInt16 = 45 // "n"
    private let hotKeyModifiers: NSEvent.ModifierFlags = [.command, .option]

    func start(model: NotesModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        // No system prompt on launch. The grant is tied to the app's code
        // signature, so an ad-hoc ("Sign to Run Locally") build looks like a new
        // app to macOS after every rebuild and the prompt would come back every
        // single time, however many times it was already granted. The Quick
        // Capture settings pane shows the live status and a button to System
        // Settings, which is where an actual fix belongs.
        refresh(promptIfNeeded: false)
    }

    /// Re-reads settings: installs or removes the monitors accordingly.
    ///
    /// - Parameter promptIfNeeded: ask macOS for Accessibility when it hasn't
    ///   been granted. Only true when the user just switched the feature on —
    ///   that's an explicit action, so a prompt is expected rather than a
    ///   surprise.
    func refresh(promptIfNeeded: Bool = true) {
        stopMonitors()
        hideTrigger()
        guard let settings, settings.quickCaptureEnabled else { return }
        if promptIfNeeded, !Accessibility.isTrusted { Accessibility.prompt() }
        installMonitors()
    }

    // MARK: - Monitors

    private func installMonitors() {
        // Keyboard shortcut ⌥⌘N. The global monitor fires while another app is
        // frontmost; the local one covers NoteM itself (and swallows the event
        // so it doesn't beep).
        keyGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.matchesHotKey(event) else { return }
            self.openPanel(at: nil)
        }
        keyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.matchesHotKey(event) else { return event }
            self.openPanel(at: nil)
            return nil
        }

        // Hot corner: watch the cursor everywhere it moves. Global covers other
        // apps; local covers NoteM while it's frontmost.
        mouseGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.handleMouseMoved()
        }
        mouseLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handleMouseMoved()
            return event
        }
    }

    private func stopMonitors() {
        for monitor in [keyGlobalMonitor, keyLocalMonitor, mouseGlobalMonitor, mouseLocalMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        keyGlobalMonitor = nil
        keyLocalMonitor = nil
        mouseGlobalMonitor = nil
        mouseLocalMonitor = nil
    }

    private func matchesHotKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == hotKeyCode && mods == hotKeyModifiers
    }

    // MARK: - Corner trigger

    /// The exact physical corner point in screen coordinates.
    private func cornerPoint(for corner: QuickCaptureCorner, in frame: NSRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: frame.minX, y: frame.maxY)
        case .topRight: return CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottomLeft: return CGPoint(x: frame.minX, y: frame.minY)
        case .bottomRight: return CGPoint(x: frame.maxX, y: frame.minY)
        }
    }

    /// Chebyshev distance from a point to a corner (max of x/y gaps).
    private func cornerDistance(_ loc: CGPoint, _ corner: QuickCaptureCorner, in frame: NSRect) -> CGFloat {
        let point = cornerPoint(for: corner, in: frame)
        return max(abs(loc.x - point.x), abs(loc.y - point.y))
    }

    /// Fires on every cursor move. Reveals the icon only once the cursor reaches
    /// the very corner (`cornerTrigger`); once shown it lingers within the larger
    /// `cornerKeep` radius so you can move onto it and click. Never opens a note.
    private func handleMouseMoved() {
        guard let settings, settings.quickCaptureEnabled else { return }
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) else {
            hideTrigger()
            suppressedCorner = nil
            return
        }
        let frame = screen.frame

        // If the icon is already showing, keep it until the cursor drifts beyond
        // the larger keep radius of its corner.
        if let shown = triggerCorner {
            if cornerDistance(loc, shown, in: frame) > cornerKeep {
                hideTrigger()
            }
            return
        }

        // Not showing: reveal only when the cursor is essentially at the corner.
        let active = settings.quickCaptureCorners.first {
            cornerDistance(loc, $0, in: frame) <= cornerTrigger
        }

        guard let active else {
            // Clear the post-open suppression once we've moved well away.
            if let sup = suppressedCorner, cornerDistance(loc, sup, in: frame) > cornerKeep {
                suppressedCorner = nil
            }
            return
        }

        // Just opened a note from this corner and haven't left it yet: stay hidden.
        if active == suppressedCorner { return }
        suppressedCorner = nil
        showTrigger(at: active, on: screen)
    }

    private func showTrigger(at corner: QuickCaptureCorner, on screen: NSScreen) {
        // Already showing for this corner: nothing to do.
        if triggerPanel != nil, triggerCorner == corner { return }
        hideTrigger()

        let accent = settings?.theme.accent ?? .accentColor
        let panel = QuickCaptureTriggerPanel()
        panel.setContent(QuickCaptureTriggerView(color: accent, action: { [weak self] in
            guard let self else { return }
            self.hideTrigger()
            self.suppressedCorner = corner
            self.openPanel(at: corner)
        }))
        positionTrigger(panel, corner: corner, on: screen)
        triggerPanel = panel
        triggerCorner = corner
        // orderFront, not makeKey: don't steal focus from the frontmost app.
        panel.orderFront(nil)
    }

    private func hideTrigger() {
        triggerPanel?.orderOut(nil)
        triggerPanel = nil
        triggerCorner = nil
    }

    /// Places the icon flush in the very corner of the screen.
    private func positionTrigger(_ panel: QuickCaptureTriggerPanel, corner: QuickCaptureCorner, on screen: NSScreen) {
        let frame = screen.frame          // full frame → the physical corner, no Dock/menu-bar inset
        let size = panel.frame.size
        var origin = CGPoint.zero
        switch corner {
        case .topLeft:
            origin = CGPoint(x: frame.minX, y: frame.maxY - size.height)
        case .topRight:
            origin = CGPoint(x: frame.maxX - size.width, y: frame.maxY - size.height)
        case .bottomLeft:
            origin = CGPoint(x: frame.minX, y: frame.minY)
        case .bottomRight:
            origin = CGPoint(x: frame.maxX - size.width, y: frame.minY)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Capture panels

    /// Always opens a fresh panel. Existing panels stay put, so triggering again
    /// never closes a note in progress. `corner` picks where it appears; `nil`
    /// (keyboard shortcut) falls back to the first enabled corner.
    private func openPanel(at corner: QuickCaptureCorner?) {
        guard let settings, settings.quickCaptureEnabled else { return }
        let target = corner ?? settings.quickCaptureCorners.first ?? .topRight
        let panel = QuickCapturePanel()
        panel.setContent(QuickCaptureView(
            onSave: { [weak self] markdown, richData, isTaskList in
                self?.saveNote(markdown, richData: richData, isTaskList: isTaskList)
            },
            onClose: { [weak self, weak panel] in self?.closePanel(panel) },
            obsidianConnected: settings.obsidianConnected,
            onSaveToObsidian: { [weak self] markdown, richData, isTaskList in
                self?.saveNote(markdown, richData: richData, isTaskList: isTaskList, toObsidian: true)
            }
        ))
        positionPanel(panel, corner: target, index: panels.count)
        panels.append(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closePanel(_ panel: QuickCapturePanel?) {
        guard let panel else { return }
        panel.orderOut(nil)
        panels.removeAll { $0 === panel }
    }

    /// Saves the quick note; with `toObsidian` it also mirrors it into the vault
    /// right away, without waiting for the debounced auto-export.
    private func saveNote(_ markdown: String, richData: Data?, isTaskList: Bool, toObsidian: Bool = false) {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let note = model?.createNote(content: markdown, richData: richData, isTaskList: isTaskList)
        if toObsidian, let note { model?.exportToObsidian(note) }
    }

    /// Positions the panel just inside the given corner. `index` staggers stacked
    /// panels so several open notes stay individually visible.
    private func positionPanel(_ panel: QuickCapturePanel, corner: QuickCaptureCorner, index: Int) {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let margin: CGFloat = 16
        let stagger = CGFloat(index) * 28
        var origin = CGPoint.zero

        switch corner {
        case .topLeft:
            origin = CGPoint(x: frame.minX + margin + stagger, y: frame.maxY - size.height - margin - stagger)
        case .topRight:
            origin = CGPoint(x: frame.maxX - size.width - margin - stagger, y: frame.maxY - size.height - margin - stagger)
        case .bottomLeft:
            origin = CGPoint(x: frame.minX + margin + stagger, y: frame.minY + margin + stagger)
        case .bottomRight:
            origin = CGPoint(x: frame.maxX - size.width - margin - stagger, y: frame.minY + margin + stagger)
        }
        panel.setFrameOrigin(origin)
    }
}

/// The little icon that slides out in the corner. A borderless, non-activating,
/// transparent panel so only the rounded button shows and clicking it doesn't
/// switch away from the current app. Its level is above the menu bar so it stays
/// visible even in a top corner.
final class QuickCaptureTriggerPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 44, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func setContent(_ view: QuickCaptureTriggerView) {
        let hosting = NSHostingView(rootView: view)
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = hosting
    }

    override var canBecomeKey: Bool { false }
}

/// The clickable corner icon. Fills the panel edge-to-edge so it sits flush in
/// the very corner of the screen.
struct QuickCaptureTriggerView: View {
    /// Accent colour from the app theme, so the icon matches Settings → Wygląd.
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    // Translucent so the wallpaper/window behind shows through;
                    // firms up a little on hover.
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(color.opacity(hovering ? 0.35 : 0.2))
                )
                .scaleEffect(hovering ? 1.06 : 1.0)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .help(Loc.t("Szybka notatka", "Quick note"))
        .onHover { hovering = $0 }
    }
}

/// A non-activating floating panel so the user can type without switching away
/// from whatever app they're in. Visible across Spaces.
final class QuickCapturePanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
            // Borderless: no titlebar, no chrome — the note fills the whole window.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear      // let the SwiftUI rounded corners show through
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func setContent(_ view: QuickCaptureView) {
        contentView = NSHostingView(rootView: view)
    }

    override var canBecomeKey: Bool { true }
}

/// Content of the quick-capture panel. Uses the same `RichTextEditor` as the
/// main editor, so pasting keeps the source formatting 1:1 (colours, fonts,
/// sizes, images) — identical to the main window.
struct QuickCaptureView: View {
    /// Called with the note's markdown, its full-fidelity rich archive, and
    /// whether it should be saved as a task-list note.
    let onSave: (String, Data?, Bool) -> Void
    let onClose: () -> Void
    /// Whether the Obsidian bridge is connected — hides the crystal when it isn't.
    var obsidianConnected: Bool = false
    /// Saves the note and immediately mirrors it into the Obsidian vault.
    var onSaveToObsidian: ((String, Data?, Bool) -> Void)? = nil

    /// Its own controller per panel, so several open notes don't share state.
    @State private var controller = RichTextController()
    /// Black vs white note background — remembered across quick notes and launches,
    /// mirroring the toggle in the main editor.
    @AppStorage("quickCaptureDarkBackground") private var darkBackground = false
    /// When on, the saved note is flagged as a planned task list.
    @State private var isTaskList = false
    /// Confirmation before the quick note is saved and sent to the vault.
    @State private var showObsidianConfirm = false

    /// Weekday + full date at the moment the note opened, in the app language,
    /// e.g. "czwartek, 16 lipca 2026" / "Thursday, July 16, 2026".
    private var dateHeader: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Loc.language == .pl ? "pl_PL" : "en_US")
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: Date())
    }

    var body: some View {
        RichTextEditor(controller: controller, darkBackground: darkBackground)
            .frame(width: 360, height: 400)
            // Day + date header — top-center, purely informational, so it never
            // steals clicks from the text underneath.
            .overlay(alignment: .top) {
                Text(dateHeader)
                    .font(.caption)
                    .foregroundStyle(darkBackground ? Color.white.opacity(0.7) : Color.black.opacity(0.5))
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            }
            // Close (discard) button — bottom-left.
            .overlay(alignment: .bottomLeading) {
                Button(Loc.t("Zamknij", "Close")) { onClose() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .padding(.leading, 10)
                    .padding(.bottom, 10)
            }
            // Background toggle above the Save button, and Save pinned to the
            // bottom-right corner of the note.
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 8) {
                    // Mostek do Obsidiana — nad ikonką zadań, tylko gdy sejf
                    // jest połączony w ustawieniach.
                    if obsidianConnected {
                        Button {
                            showObsidianConfirm = true
                        } label: {
                            ObsidianMark(sent: false, size: 14)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(Loc.t("Zapisz notatkę i wyślij do Obsidiana",
                                    "Save the note and send it to Obsidian"))
                    }

                    Button {
                        isTaskList.toggle()
                    } label: {
                        Image(systemName: isTaskList ? "checklist.checked" : "checklist")
                            .foregroundStyle(isTaskList
                                             ? Color.accentColor
                                             : (darkBackground ? Color.white : Color.black))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(isTaskList ? Loc.t("Notatka zostanie zapisana jako zadanie", "Note will be saved as a task")
                                     : Loc.t("Zapisz jako zadanie", "Save as task"))

                    Button {
                        darkBackground.toggle()
                    } label: {
                        Image(systemName: darkBackground ? "sun.max" : "moon")
                            // Black on the light note background so it stays visible.
                            .foregroundStyle(darkBackground ? Color.white : Color.black)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(darkBackground ? Loc.t("Przełącz na białe tło", "Switch to white background")
                                         : Loc.t("Przełącz na czarne tło", "Switch to black background"))

                    Button(Loc.t("Zapisz", "Save")) { saveAndClose() }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .padding(.trailing, 10)
                .padding(.bottom, 10)
            }
            // Drag handle — bottom-center ellipsis. The text editor swallows mouse
            // drags everywhere else, so this is the one spot to grab the note
            // and move it around the desktop.
            .overlay(alignment: .bottom) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(darkBackground ? Color.white.opacity(0.7) : Color.black.opacity(0.5))
                    .frame(width: 44, height: 20)
                    .contentShape(Rectangle())
                    .overlay(WindowDragHandle())
                    .help(Loc.t("Przeciągnij, aby przesunąć notatkę", "Drag to move the note"))
                    .padding(.bottom, 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .confirmationDialog(
                Loc.t("Wyeksportować notatkę do Obsidiana?", "Export the note to Obsidian?"),
                isPresented: $showObsidianConfirm,
                titleVisibility: .visible
            ) {
                Button(Loc.t("Zapisz i wyślij", "Save and send")) { saveToObsidianAndClose() }
                Button(Loc.t("Anuluj", "Cancel"), role: .cancel) {}
            } message: {
                Text(Loc.t("Notatka zostanie zapisana w NoteM i skopiowana do sejfu Obsidiana jako plik .md.",
                           "The note will be saved in NoteM and copied into the Obsidian vault as an .md file."))
            }
            .onAppear {
                controller.setContent(
                    NSAttributedString(string: "", attributes: MarkdownStyler.defaultTypingAttributes)
                )
                // Put the caret in the editor so the user can type right away.
                DispatchQueue.main.async {
                    if let textView = controller.textView {
                        textView.window?.makeFirstResponder(textView)
                    }
                }
            }
            .onDisappear { controller.hideFloatingPanel() }
            .onExitCommand { saveAndClose() }
    }

    /// Crystal button: saves the note and mirrors it into the vault, then closes.
    private func saveToObsidianAndClose() {
        if let attributed = controller.textView?.attributedString() {
            let markdown = MarkdownStyler.markdown(from: attributed)
            let richData = NoteRichArchive.data(from: attributed)
            onSaveToObsidian?(markdown, richData, isTaskList)
        }
        onClose()
    }

    /// Esc / save button: saves only if something was typed, then closes.
    private func saveAndClose() {
        if let attributed = controller.textView?.attributedString() {
            let markdown = MarkdownStyler.markdown(from: attributed)
            let richData = NoteRichArchive.data(from: attributed)
            onSave(markdown, richData, isTaskList)
        }
        onClose()
    }
}

/// Invisible AppKit layer under the ellipsis handle: on mouse-down it starts a
/// native window drag (`performDrag`), so the borderless quick-note panel moves
/// exactly like a titled window — smoothly, with screen-edge snapping.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        // Open-hand cursor so the handle reads as "grabbable".
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

/// Preferences pane: quick-capture on/off, active corners, and Accessibility status.
struct QuickCaptureSettingsView: View {
    @Bindable var settings: AppSettings
    /// Called when the toggle/corners change so the manager can reconfigure.
    let onChange: () -> Void

    @State private var trusted = Accessibility.isTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick Capture")
                .font(.headline)
            Text(settings.t(
                    "Najedź kursorem w aktywny róg ekranu — wysunie się mała ikonka. Kliknij ją, a pojawi się pływające pole do szybkiej notatki. "
                    + "Sam róg nic nie otwiera, dopóki nie klikniesz ikonki. Możesz też nacisnąć ⌥⌘N w dowolnej aplikacji. "
                    + "Możesz otworzyć kilka pól naraz — nowe nie zamyka poprzednich. Notatka trafia normalnie na listę i przechodzi przez reguły katalogowania.",
                    "Move the cursor into an active screen corner — a small icon slides out. Click it to open a floating quick-note field. "
                    + "The corner opens nothing until you click the icon. You can also press ⌥⌘N in any app. "
                    + "You can open several fields at once — new ones don't close the previous. The note lands on the list normally and goes through the filing rules."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle(settings.t("Włącz szybką notatkę (róg ekranu / ⌥⌘N)", "Enable quick capture (screen corner / ⌥⌘N)"),
                   isOn: $settings.quickCaptureEnabled)
                .onChange(of: settings.quickCaptureEnabled) { onChange() }

            VStack(alignment: .leading, spacing: 6) {
                Text(settings.t("Aktywne rogi ekranu", "Active screen corners"))
                    .font(.callout)
                ForEach(QuickCaptureCorner.allCases) { corner in
                    Toggle(corner.label, isOn: cornerBinding(corner))
                        .disabled(!settings.quickCaptureEnabled)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(trusted ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trusted ? settings.t("Uprawnienia Dostępności przyznane", "Accessibility permission granted")
                                 : settings.t("Brak uprawnień Dostępności", "No Accessibility permission"))
                        .font(.callout)
                    if !trusted {
                        Text(settings.t("Jeśli ikonka w rogu nie wysuwa się, dodaj NoteM w Ustawieniach systemowych.",
                                        "If the corner icon doesn't slide out, add NoteM in System Settings."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !trusted {
                    Button(settings.t("Otwórz ustawienia", "Open Settings")) { Accessibility.openSettings() }
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { trusted = Accessibility.isTrusted }
    }

    /// A checkbox binding that adds/removes a corner from the active set.
    private func cornerBinding(_ corner: QuickCaptureCorner) -> Binding<Bool> {
        Binding(
            get: { settings.quickCaptureCorners.contains(corner) },
            set: { isOn in
                if isOn { settings.quickCaptureCorners.insert(corner) }
                else { settings.quickCaptureCorners.remove(corner) }
                onChange()
            }
        )
    }
}
