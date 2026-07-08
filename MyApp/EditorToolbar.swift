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

// MARK: - SwiftUI content (private)

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
