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

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    // Text style
                    group {
                        fmtBtn("bold",   label: Loc.t("Pogrubienie", "Bold"),  action: controller.toggleBold)
                        fmtBtn("italic", label: Loc.t("Kursywa", "Italic"),      action: controller.toggleItalic)
                        fmtBtn("underline", label: Loc.t("Podkreślenie", "Underline"), action: { controller.toggleUnderline() })
                    }
                    divider()
                    // Headers
                    group {
                        headerBtn("H1", action: { controller.toggleHeader(1) })
                        headerBtn("H2", action: { controller.toggleHeader(2) })
                        headerBtn("H3", action: { controller.toggleHeader(3) })
                    }
                    divider()
                    // Lists
                    group {
                        fmtBtn("list.bullet",  label: Loc.t("Lista punktowana", "Bulleted list"), action: { controller.toggleList("bullet") })
                        fmtBtn("list.number",  label: Loc.t("Lista numerowana", "Numbered list"), action: { controller.toggleList("ordered") })
                        fmtBtn("checklist",    label: Loc.t("Lista zadań", "Checklist"),        action: controller.toggleChecklist)
                    }
                    divider()
                    // Insert
                    group {
                        fmtBtn("tablecells",                             label: Loc.t("Tabela", "Table"),    action: controller.insertTable)
                        fmtBtn("chevron.left.forwardslash.chevron.right", label: Loc.t("Kod", "Code"),      action: controller.insertInlineCode)
                        fmtBtn("link",                                   label: Loc.t("Link", "Link"),      action: { controller.insertLink() })
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 40)
            .background(.bar)
        }
    }

    private func group<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        HStack(spacing: 0) { content() }
    }

    private func divider() -> some View {
        Divider().frame(height: 20).padding(.horizontal, 4)
    }

    private func fmtBtn(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func headerBtn(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
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
