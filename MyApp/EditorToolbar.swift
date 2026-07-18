import SwiftUI
import AppKit

// MARK: - Floating format panel

/// Non-activating NSPanel that floats above text selections showing formatting
/// buttons. Clicking buttons doesn't steal focus from the NSTextView so the
/// selection stays active while the user formats.
final class FloatingFormatPanel: NSPanel {

    init(
        onBold:      @escaping () -> Void,
        onItalic:    @escaping () -> Void,
        onH1:        @escaping () -> Void,
        onH2:        @escaping () -> Void,
        onBullet:    @escaping () -> Void,
        onNumbered:  @escaping () -> Void,
        onChecklist: @escaping () -> Void,
        onTable:     @escaping () -> Void,
        onCode:      @escaping () -> Void
    ) {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isMovableByWindowBackground = false
        level = .floating
        backgroundColor = .clear
        hasShadow = true
        isOpaque = false
        acceptsMouseMovedEvents = true

        let content = FloatingToolbarContent(
            onBold: onBold, onItalic: onItalic,
            onH1: onH1, onH2: onH2,
            onBullet: onBullet, onNumbered: onNumbered,
            onChecklist: onChecklist, onTable: onTable, onCode: onCode
        )

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: content)
        blur.addSubview(hosting)
        contentView = blur

        let size = hosting.fittingSize
        setContentSize(size)
        blur.frame = NSRect(origin: .zero, size: size)
        hosting.frame = blur.frame

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hideOnDeactivate),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    /// Positions and shows the panel just above `selectionScreenRect`.
    func show(above selectionScreenRect: NSRect) {
        guard let size = contentView?.frame.size else { return }
        var x = selectionScreenRect.midX - size.width / 2
        var y = selectionScreenRect.maxY + 6

        if let screen = NSScreen.main {
            let vis = screen.visibleFrame
            x = min(max(x, vis.minX + 4), vis.maxX - size.width - 4)
            y = min(y, vis.maxY - size.height - 4)
        }
        setFrameOrigin(NSPoint(x: x, y: y))
        if !isVisible { orderFront(nil) }
    }

    func hide() { if isVisible { orderOut(nil) } }

    @objc private func hideOnDeactivate() { hide() }
}

// MARK: - Persistent bottom format bar

/// Always-visible formatting toolbar pinned to the bottom of the note editor.
struct FormatBar: View {
    let controller: RichTextController
    /// App theme accent colour, used for the active-button highlight.
    var accent: Color = .accentColor
    /// Opens the drawing editor (wired from the note view).
    var onOpenDrawing: () -> Void = {}
    /// Live dictation state (Priorytet 4); `nil` hides the mic button.
    var dictation: VoiceDictation?
    /// Starts/stops dictation (wired from the note view).
    var onToggleDictation: () -> Void = {}

    /// Toggle formats active at the caret, so the matching buttons light up.
    @State private var active: ActiveFormats = []
    /// Paragraph style at the caret, to highlight the "Aa" style panel.
    @State private var paragraphStyle: ParagraphStyleKind = .body
    /// Font family at the caret, shown in the font menu.
    @State private var fontFamily: String = ""
    /// Whether the "Aa" style panel is shown one row above the main capsule.
    @State private var showStyle = false
    /// Whether the table-size grid picker popover is shown.
    @State private var showTable = false

    var body: some View {
        VStack(spacing: 8) {
            if showStyle {
                StyleCapsule(controller: controller, accent: accent,
                             active: active, style: paragraphStyle)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            mainCapsule
        }
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)   // centre the capsules horizontally
        .onAppear {
            refreshState()
            controller.onActiveFormatsChange = { _ in refreshState() }
        }
    }

    private func refreshState() {
        active = controller.currentActiveFormats()
        paragraphStyle = controller.currentParagraphStyle()
        fontFamily = controller.currentFontFamily()
    }

    /// Common font families offered in the note's font menu.
    private static let fontFamilies = [
        "System", "Helvetica", "Arial", "Times New Roman", "Georgia", "Courier New",
        "Menlo", "Verdana", "Palatino", "Trebuchet MS", "Snell Roundhand"
    ]

    private var fontMenu: some View {
        Menu {
            ForEach(Self.fontFamilies, id: \.self) { name in
                Button(name) { controller.setFontFamily(name); fontFamily = name }
            }
        } label: {
            Text(fontFamily.isEmpty ? Loc.t("Czcionka", "Font") : fontFamily)
                .lineLimit(1)
                .frame(maxWidth: 96)
        }
        .menuStyle(.borderlessButton)
        .tint(.primary)
        .foregroundStyle(.primary)
        .fixedSize()
        .help(Loc.t("Czcionka", "Font"))
    }

    /// The always-visible bottom capsule of quick tools.
    private var mainCapsule: some View {
        HStack(spacing: 0) {
            // "Aa" – opens the style panel above.
            aaButton
            divider()
            // Font size (type a value or pick one from the list)
            FontSizeField(controller: controller)
                .help(Loc.t("Rozmiar tekstu", "Text size"))
                .padding(.horizontal, 4)
            // Font family
            fontMenu
                .padding(.horizontal, 2)
            divider()
            // Checklist
            fmtBtn("checklist", label: Loc.t("Lista zadań", "Checklist"), active: active.contains(.checklist), action: controller.toggleChecklist)
            divider()
            // Insert
            group {
                tableButton
                fmtBtn("chevron.left.forwardslash.chevron.right", label: Loc.t("Kod", "Code"),      action: controller.insertInlineCode)
                fmtBtn("link",                                   label: Loc.t("Link", "Link"),      action: { controller.insertLink() })
            }
            divider()
            // Attachments & pen
            group {
                fmtBtn("paperclip", label: Loc.t("Dodaj załącznik", "Add attachment"), action: { controller.addAttachmentFromPanel() })
                fmtBtn("pencil.tip.crop.circle", label: Loc.t("Rysowanie", "Drawing"), action: onOpenDrawing)
            }
            if dictation != nil {
                divider()
                dictationButton
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .fixedSize()
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }

    private var aaButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { showStyle.toggle() }
        } label: {
            Text("Aa")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(showStyle ? accent : Color.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(showStyle ? accent.opacity(0.20) : Color.clear))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Loc.t("Style tekstu", "Text styles"))
    }

    private var tableButton: some View {
        Button { showTable = true } label: {
            Image(systemName: "tablecells")
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Loc.t("Tabela", "Table"))
        .popover(isPresented: $showTable, arrowEdge: .top) {
            TableGridPicker { rows, cols in
                controller.insertTable(rows: rows, columns: cols)
                showTable = false
            }
        }
    }

    /// Mic button: idle mic / spinner while the speech model loads / red stop
    /// with the elapsed time while listening (Priorytet 4).
    @ViewBuilder
    private var dictationButton: some View {
        if let dictation {
            Button(action: onToggleDictation) {
                switch dictation.phase {
                case .listening:
                    HStack(spacing: 4) {
                        Image(systemName: "stop.circle.fill")
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(elapsedTime(context.date, since: dictation.startedAt))
                                .font(.system(size: 12))
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(.red)
                    .frame(height: 34)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                case .preparing:
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 34, height: 34)
                case .idle:
                    Image(systemName: "mic")
                        .frame(width: 30, height: 30)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .disabled(dictation.phase == .preparing)
            .help(dictation.phase == .listening
                  ? Loc.t("Zatrzymaj dyktowanie", "Stop dictation")
                  : Loc.t("Dyktuj notatkę — mów, a tekst pojawi się w notatce na żywo",
                          "Dictate — speak and the text appears in the note live"))
        }
    }

    /// Elapsed dictation time, mm:ss.
    private func elapsedTime(_ now: Date, since start: Date?) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start ?? now)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func group<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        HStack(spacing: 0) { content() }
    }

    private func divider() -> some View {
        Divider().frame(height: 20).padding(.horizontal, 4)
    }

    private func fmtBtn(_ icon: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(active ? accent : Color.primary)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(active ? accent.opacity(0.20) : Color.clear)
                )
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

// MARK: - Style panel ("Aa")

/// The second capsule that appears above the main bar when "Aa" is tapped.
/// Three rows: paragraph styles, character formatting, lists & paragraph layout.
private struct StyleCapsule: View {
    let controller: RichTextController
    var accent: Color
    let active: ActiveFormats
    let style: ParagraphStyleKind

    @State private var textColor: Color = .primary

    var body: some View {
        VStack(spacing: 2) {
            // Row 1 — paragraph styles.
            HStack(spacing: 6) {
                styleBtn(Loc.t("Tytuł", "Title"), .title)
                styleBtn(Loc.t("Nagłówek", "Heading"), .heading)
                styleBtn(Loc.t("Podnagłówek", "Subheading"), .subheading)
                styleBtn(Loc.t("Treść", "Body"), .body)
                styleBtn(Loc.t("Mono", "Mono"), .monospaced)
            }
            Divider()
            // Row 2 — character formatting + lists & paragraph layout (merged).
            HStack(spacing: 2) {
                iconBtn("bold",          active: active.contains(.bold),          help: Loc.t("Pogrubienie", "Bold")) { controller.toggleBold() }
                iconBtn("italic",        active: active.contains(.italic),        help: Loc.t("Kursywa", "Italic")) { controller.toggleItalic() }
                iconBtn("underline",     active: active.contains(.underline),     help: Loc.t("Podkreślenie", "Underline")) { controller.toggleUnderline() }
                iconBtn("strikethrough", active: active.contains(.strikethrough), help: Loc.t("Przekreślenie", "Strikethrough")) { controller.toggleStrikethrough() }
                rowDivider()
                iconBtn("highlighter", active: false, help: Loc.t("Zakreślacz", "Highlighter")) {
                    controller.toggleHighlight(NSColor.systemYellow.withAlphaComponent(0.4))
                }
                ColorPicker("", selection: $textColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 34, height: 30)
                    .help(Loc.t("Kolor tekstu", "Text colour"))
                    .onChange(of: textColor) { _, newValue in
                        controller.setTextColor(NSColor(newValue))
                    }
                rowDivider()
                iconBtn("list.bullet", active: active.contains(.bulletList),   help: Loc.t("Lista punktowana", "Bulleted list")) { controller.toggleList("bullet") }
                iconBtn("list.dash",   active: active.contains(.dashList),     help: Loc.t("Lista z myślnikami", "Dashed list")) { controller.toggleList("dash") }
                iconBtn("list.number", active: active.contains(.numberedList), help: Loc.t("Lista numerowana", "Numbered list")) { controller.toggleList("ordered") }
                rowDivider()
                iconBtn("decrease.indent", active: false, help: Loc.t("Zmniejsz wcięcie", "Decrease indent")) { controller.changeIndent(by: -18) }
                iconBtn("increase.indent", active: false, help: Loc.t("Zwiększ wcięcie", "Increase indent")) { controller.changeIndent(by: 18) }
                rowDivider()
                iconBtn("text.quote", active: active.contains(.blockquote), help: Loc.t("Cytat blokowy", "Block quote")) { controller.toggleBlockquote() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }

    private func rowDivider() -> some View {
        Divider().frame(height: 20).padding(.horizontal, 6)
    }

    private func styleBtn(_ text: String, _ kind: ParagraphStyleKind) -> some View {
        let selected = style == kind
        return Button { controller.setParagraphStyle(kind) } label: {
            Text(text)
                .font(styleFont(kind))
                .foregroundStyle(selected ? accent : Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? accent.opacity(0.18) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private func styleFont(_ kind: ParagraphStyleKind) -> Font {
        switch kind {
        case .title:      return .system(size: 16, weight: .bold)
        case .heading:    return .system(size: 14, weight: .bold)
        case .subheading: return .system(size: 13, weight: .semibold)
        case .body:       return .system(size: 13)
        case .monospaced: return .system(size: 13, design: .monospaced)
        }
    }

    private func iconBtn(_ icon: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(active ? accent : Color.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(active ? accent.opacity(0.20) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Table size grid picker

/// A Word-style grid: hover to pick columns×rows, click to insert the table.
private struct TableGridPicker: View {
    let onPick: (_ rows: Int, _ cols: Int) -> Void

    @State private var rows = 0
    @State private var cols = 0
    @State private var manualCols = 3
    @State private var manualRows = 3
    private let maxRows = 8
    private let maxCols = 8
    private let cell: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rows > 0 ? "\(cols)×\(rows) — \(Loc.t("tabela", "table"))"
                          : Loc.t("Tabela", "Table"))
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 2) {
                ForEach(1...maxRows, id: \.self) { r in
                    HStack(spacing: 2) {
                        ForEach(1...maxCols, id: \.self) { c in
                            RoundedRectangle(cornerRadius: 2)
                                .fill((r <= rows && c <= cols) ? Color.accentColor.opacity(0.35)
                                                               : Color.gray.opacity(0.15))
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(.quaternary, lineWidth: 0.5))
                                .frame(width: cell, height: cell)
                                .onHover { if $0 { rows = r; cols = c } }
                                .onTapGesture { onPick(r, c) }
                        }
                    }
                }
            }
            Divider()
            // Manual entry: columns × rows, with the insert button underneath.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    TextField("", value: $manualCols, format: .number)
                        .frame(width: 40).textFieldStyle(.roundedBorder)
                    Text("×").foregroundStyle(.secondary)
                    TextField("", value: $manualRows, format: .number)
                        .frame(width: 40).textFieldStyle(.roundedBorder)
                }
                Button(Loc.t("Wstaw tabelę…", "Insert table…")) {
                    onPick(max(1, manualRows), max(1, manualCols))
                }
            }
            .font(.caption)
        }
        .padding(12)
    }
}

// MARK: - Font size field

/// A compact editable combo box for the text size: the user can pick a preset
/// from the drop-down or type any value and press Return. Backed by NSComboBox
/// so it behaves exactly like the native size fields in other macOS apps.
private struct FontSizeField: NSViewRepresentable {
    let controller: RichTextController

    static let presets: [Int] = [9, 10, 11, 12, 13, 14, 16, 18, 24, 36, 48, 72]

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox()
        combo.addItems(withObjectValues: Self.presets.map { "\($0)" })
        combo.isEditable = true
        combo.completes = true
        combo.controlSize = .small
        combo.font = .systemFont(ofSize: 12)
        combo.delegate = context.coordinator
        combo.stringValue = "\(Int(controller.currentFontSize().rounded()))"
        combo.setContentHuggingPriority(.required, for: .horizontal)
        combo.widthAnchor.constraint(equalToConstant: 56).isActive = true
        // 30 pt tall inside the 38 pt capsule → 4 pt gap top & bottom.
        combo.heightAnchor.constraint(equalToConstant: 30).isActive = true
        context.coordinator.combo = combo

        // Keep the field in sync as the caret / selection moves in the editor.
        controller.onFontSizeChange = { [weak combo] size in
            let text = "\(Int(size.rounded()))"
            if combo?.stringValue != text { combo?.stringValue = text }
        }
        return combo
    }

    func updateNSView(_ nsView: NSComboBox, context: Context) {}

    final class Coordinator: NSObject, NSComboBoxDelegate {
        let controller: RichTextController
        weak var combo: NSComboBox?

        init(controller: RichTextController) { self.controller = controller }

        // Picked from the drop-down list.
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo, combo.indexOfSelectedItem >= 0 else { return }
            let value = combo.itemObjectValue(at: combo.indexOfSelectedItem) as? String ?? ""
            apply(value)
        }

        // Typed a custom value and committed with Return / focus loss.
        func controlTextDidEndEditing(_ obj: Notification) {
            apply(combo?.stringValue ?? "")
        }

        private func apply(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard let value = Double(trimmed), value > 0 else { return }
            controller.setFontSize(CGFloat(value))
        }
    }
}

// MARK: - Floating format panel (appears above text selection)

private struct FloatingToolbarContent: View {
    let onBold:      () -> Void
    let onItalic:    () -> Void
    let onH1:        () -> Void
    let onH2:        () -> Void
    let onBullet:    () -> Void
    let onNumbered:  () -> Void
    let onChecklist: () -> Void
    let onTable:     () -> Void
    let onCode:      () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Group {
                iconBtn("bold",        action: onBold)
                iconBtn("italic",      action: onItalic)
            }
            Divider().frame(height: 16)
            Group {
                Button("H1", action: onH1).font(.caption.bold())
                Button("H2", action: onH2).font(.caption.bold())
            }
            Divider().frame(height: 16)
            Group {
                iconBtn("list.bullet",  action: onBullet)
                iconBtn("list.number",  action: onNumbered)
                iconBtn("checklist",    action: onChecklist)
            }
            Divider().frame(height: 16)
            Group {
                iconBtn("tablecells",   action: onTable)
                iconBtn("chevron.left.forwardslash.chevron.right", action: onCode)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .fixedSize()
    }

    private func iconBtn(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 22, height: 22)
        }
    }
}
