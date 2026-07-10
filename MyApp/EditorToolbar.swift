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

    /// Toggle formats active at the caret, so the matching buttons light up.
    @State private var active: ActiveFormats = []
    /// Paragraph style at the caret, to highlight the "Aa" style panel.
    @State private var paragraphStyle: ParagraphStyleKind = .body
    /// Whether the "Aa" style panel is shown one row above the main capsule.
    @State private var showStyle = false

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
            divider()
            // Checklist
            fmtBtn("checklist", label: Loc.t("Lista zadań", "Checklist"), active: active.contains(.checklist), action: controller.toggleChecklist)
            divider()
            // Insert
            group {
                fmtBtn("tablecells",                             label: Loc.t("Tabela", "Table"),    action: controller.insertTable)
                fmtBtn("chevron.left.forwardslash.chevron.right", label: Loc.t("Kod", "Code"),      action: controller.insertInlineCode)
                fmtBtn("link",                                   label: Loc.t("Link", "Link"),      action: { controller.insertLink() })
            }
            divider()
            // Attachments & pen
            group {
                fmtBtn("paperclip", label: Loc.t("Dodaj załącznik", "Add attachment"), action: { controller.addAttachmentFromPanel() })
                fmtBtn("pencil.tip.crop.circle", label: Loc.t("Rysowanie", "Drawing"), action: onOpenDrawing)
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
