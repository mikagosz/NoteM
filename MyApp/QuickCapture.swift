import SwiftUI
import AppKit
import ApplicationServices

/// Which screen corner triggers quick capture.
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

/// Watches the cursor for the configured hot corner and shows a floating
/// capture panel. New notes are created through the normal `NotesModel`, so
/// they flow through the categorization rules just like any other note.
@MainActor
final class QuickCaptureManager {
    static let shared = QuickCaptureManager()

    private weak var model: NotesModel?
    private weak var settings: AppSettings?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var panel: QuickCapturePanel?

    /// Global shortcut that opens the capture panel: ⌥⌘N.
    private let hotKeyCode: UInt16 = 45 // "n"
    private let hotKeyModifiers: NSEvent.ModifierFlags = [.command, .option]

    func start(model: NotesModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        refresh()
    }

    /// Re-reads settings: installs or removes the shortcut monitors accordingly.
    func refresh() {
        stopMonitors()
        guard let settings, settings.quickCaptureEnabled else { return }
        if !Accessibility.isTrusted { Accessibility.prompt() }
        installMonitors()
    }

    // MARK: - Monitors

    private func installMonitors() {
        // The global monitor fires while another app is frontmost; the local
        // one covers the case where NoteM itself is active (and swallows the
        // event so it doesn't beep).
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.matchesHotKey(event) else { return }
            self.togglePanel()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.matchesHotKey(event) else { return event }
            self.togglePanel()
            return nil
        }
    }

    private func stopMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func matchesHotKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == hotKeyCode && mods == hotKeyModifiers
    }

    /// Opens the panel, or closes it if it's already on screen, so the same
    /// shortcut toggles the field and reopening after a close always works.
    private func togglePanel() {
        guard let settings, settings.quickCaptureEnabled else { return }
        if panel == nil {
            showPanel()
        } else {
            closePanel()
        }
    }

    // MARK: - Panel

    private func showPanel() {
        let view = QuickCaptureView(
            onSave: { [weak self] text in self?.saveNote(text) },
            onClose: { [weak self] in self?.closePanel() }
        )
        let panel = QuickCapturePanel(rootView: view)
        self.panel = panel
        positionPanel(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func saveNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model?.createNote(content: text)
    }

    /// Positions the panel just inside the active corner.
    private func positionPanel(_ panel: QuickCapturePanel) {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let margin: CGFloat = 16
        var origin = CGPoint.zero

        switch settings?.quickCaptureCorner ?? .topRight {
        case .topLeft:
            origin = CGPoint(x: frame.minX + margin, y: frame.maxY - size.height - margin)
        case .topRight:
            origin = CGPoint(x: frame.maxX - size.width - margin, y: frame.maxY - size.height - margin)
        case .bottomLeft:
            origin = CGPoint(x: frame.minX + margin, y: frame.minY + margin)
        case .bottomRight:
            origin = CGPoint(x: frame.maxX - size.width - margin, y: frame.minY + margin)
        }
        panel.setFrameOrigin(origin)
    }
}

/// A non-activating floating panel so the user can type without switching away
/// from whatever app they're in. Visible across Spaces.
final class QuickCapturePanel: NSPanel {
    init(rootView: QuickCaptureView) {
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
        contentView = NSHostingView(rootView: rootView)
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

/// Preferences pane: quick-capture on/off, corner, and Accessibility status.
struct QuickCaptureSettingsView: View {
    @Bindable var settings: AppSettings
    /// Called when the toggle/corner changes so the manager can reconfigure.
    let onChange: () -> Void

    @State private var trusted = Accessibility.isTrusted

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick capture")
                .font(.headline)
            Text("Naciśnij ⌥⌘N w dowolnej aplikacji, a pojawi się pływające pole do szybkiej notatki. "
                 + "Tym samym skrótem je zamykasz. Notatka trafia normalnie na listę i przechodzi przez reguły katalogowania.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Włącz szybką notatkę (⌥⌘N)", isOn: $settings.quickCaptureEnabled)
                .onChange(of: settings.quickCaptureEnabled) { onChange() }

            Picker("Pokaż pole w rogu", selection: $settings.quickCaptureCorner) {
                ForEach(QuickCaptureCorner.allCases) { corner in
                    Text(corner.label).tag(corner)
                }
            }
            .pickerStyle(.menu)
            .disabled(!settings.quickCaptureEnabled)
            .onChange(of: settings.quickCaptureCorner) { onChange() }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(trusted ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trusted ? "Uprawnienia Dostępności przyznane" : "Brak uprawnień Dostępności")
                        .font(.callout)
                    if !trusted {
                        Text("Jeśli hot corner nie reaguje, dodaj NoteM w Ustawieniach systemowych.")
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
        .frame(width: 560, height: 380)
        .onAppear { trusted = Accessibility.isTrusted }
    }
}
