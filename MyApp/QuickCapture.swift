import SwiftUI
import AppKit
import ApplicationServices

/// Which screen corner reveals the quick-capture trigger.
enum QuickCaptureCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topLeft: return "Lewy górny"
        case .topRight: return "Prawy górny"
        case .bottomLeft: return "Lewy dolny"
        case .bottomRight: return "Prawy dolny"
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
        refresh()
    }

    /// Re-reads settings: installs or removes the monitors accordingly.
    func refresh() {
        stopMonitors()
        hideTrigger()
        guard let settings, settings.quickCaptureEnabled else { return }
        if !Accessibility.isTrusted { Accessibility.prompt() }
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
            onSave: { [weak self] text in self?.saveNote(text) },
            onClose: { [weak self, weak panel] in self?.closePanel(panel) }
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

    private func saveNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model?.createNote(content: text)
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
        .help("Szybka notatka")
        .onHover { hovering = $0 }
    }
}

/// A non-activating floating panel so the user can type without switching away
/// from whatever app they're in. Visible across Spaces.
final class QuickCapturePanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func setContent(_ view: QuickCaptureView) {
        contentView = NSHostingView(rootView: view)
    }

    override var canBecomeKey: Bool { true }
}

/// Content of the quick-capture panel.
struct QuickCaptureView: View {
    let onSave: (String) -> Void
    let onClose: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Szybka notatka")
                .font(.headline)

            TextEditor(text: $text)
                .font(.body)
                .frame(width: 328, height: 130)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                Text("⌘↩ zapisz · Esc zamyka")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Zapisz") { saveAndClose() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .onAppear { focused = true }
        .onExitCommand { saveAndClose() }
    }

    /// Esc / save button: saves only if something was typed, then closes.
    private func saveAndClose() {
        onSave(text)
        onClose()
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
            Text("Quick capture")
                .font(.headline)
            Text("Najedź kursorem w aktywny róg ekranu — wysunie się mała ikonka. Kliknij ją, a pojawi się pływające pole do szybkiej notatki. "
                 + "Sam róg nic nie otwiera, dopóki nie klikniesz ikonki. Możesz też nacisnąć ⌥⌘N w dowolnej aplikacji. "
                 + "Możesz otworzyć kilka pól naraz — nowe nie zamyka poprzednich. Notatka trafia normalnie na listę i przechodzi przez reguły katalogowania.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Włącz szybką notatkę (róg ekranu / ⌥⌘N)", isOn: $settings.quickCaptureEnabled)
                .onChange(of: settings.quickCaptureEnabled) { onChange() }

            VStack(alignment: .leading, spacing: 6) {
                Text("Aktywne rogi ekranu")
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
                    Text(trusted ? "Uprawnienia Dostępności przyznane" : "Brak uprawnień Dostępności")
                        .font(.callout)
                    if !trusted {
                        Text("Jeśli ikonka w rogu nie wysuwa się, dodaj NoteM w Ustawieniach systemowych.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !trusted {
                    Button("Otwórz ustawienia") { Accessibility.openSettings() }
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
