import SwiftUI
import PencilKit
import AppKit

// MARK: - Brushes

/// The drawing brushes offered in the tool popover — each maps to a native
/// PencilKit ink so the stroke look (blending, texture) comes for free.
enum DrawBrush: String, CaseIterable, Identifiable {
    case pen, monoline, marker, pencil, crayon, fountainPen, reed, watercolor
    var id: String { rawValue }

    var inkType: PKInkingTool.InkType {
        switch self {
        case .pen:         return .pen
        case .monoline:    return .monoline
        case .marker:      return .marker
        case .pencil:      return .pencil
        case .crayon:      return .crayon
        case .fountainPen: return .fountainPen
        case .reed:        return .reed
        case .watercolor:  return .watercolor
        }
    }

    var name: String {
        switch self {
        case .pen:         return Loc.t("Długopis", "Pen")
        case .monoline:    return Loc.t("Cienkopis", "Monoline")
        case .marker:      return Loc.t("Marker", "Marker")
        case .pencil:      return Loc.t("Ołówek", "Pencil")
        case .crayon:      return Loc.t("Kredka", "Crayon")
        case .fountainPen: return Loc.t("Pióro wieczne", "Fountain Pen")
        case .reed:        return Loc.t("Pióro trzcinowe", "Reed")
        case .watercolor:  return Loc.t("Akwarela", "Watercolor")
        }
    }

    var symbol: String {
        switch self {
        case .pen:         return "pencil"
        case .monoline:    return "pencil.line"
        case .marker:      return "highlighter"
        case .pencil:      return "pencil.tip"
        case .crayon:      return "pencil.tip"
        case .fountainPen: return "pencil.and.outline"
        case .reed:        return "paintbrush.pointed"
        case .watercolor:  return "paintbrush"
        }
    }
}

// MARK: - Editable shapes

enum ShapeKind: String, CaseIterable, Identifiable {
    case line, arrow, rectangle, roundedRect, ellipse, bubble, star, hexagon
    var id: String { rawValue }

    /// Closed shapes can be filled; open ones (line/arrow) only stroke.
    var isClosed: Bool { self != .line && self != .arrow }

    var name: String {
        switch self {
        case .line:        return Loc.t("Linia", "Line")
        case .arrow:       return Loc.t("Strzałka", "Arrow")
        case .rectangle:   return Loc.t("Kwadrat", "Square")
        case .roundedRect: return Loc.t("Zaokrąglony", "Rounded")
        case .ellipse:     return Loc.t("Koło", "Circle")
        case .bubble:      return Loc.t("Dymek", "Speech bubble")
        case .star:        return Loc.t("Gwiazda", "Star")
        case .hexagon:     return Loc.t("Sześciokąt", "Hexagon")
        }
    }

    var symbol: String {
        switch self {
        case .line:        return "line.diagonal"
        case .arrow:       return "arrow.up.right"
        case .rectangle:   return "square"
        case .roundedRect: return "square"          // rounded look via corner radius in path
        case .ellipse:     return "circle"
        case .bubble:      return "bubble.left"
        case .star:        return "star"
        case .hexagon:     return "hexagon"
        }
    }
}

/// A vector shape the user can move, resize, fill and outline.
struct EditableShape: Identifiable {
    let id = UUID()
    var kind: ShapeKind
    var frame: CGRect
    var fill: NSColor?          // nil = no fill
    var stroke: NSColor?        // nil = no border
    var lineWidth: CGFloat

    /// The bezier path for the shape within its current frame.
    func path() -> NSBezierPath {
        let r = frame
        switch kind {
        case .rectangle:
            return NSBezierPath(rect: r)
        case .roundedRect:
            let radius = min(r.width, r.height) * 0.2
            return NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        case .ellipse:
            return NSBezierPath(ovalIn: r)
        case .line:
            let p = NSBezierPath()
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.line(to: CGPoint(x: r.maxX, y: r.minY))
            return p
        case .arrow:
            let a = CGPoint(x: r.minX, y: r.maxY)
            let b = CGPoint(x: r.maxX, y: r.minY)
            let p = NSBezierPath()
            p.move(to: a); p.line(to: b)
            let ang = atan2(b.y - a.y, b.x - a.x)
            let len = min(r.width, r.height) * 0.3
            p.move(to: b)
            p.line(to: CGPoint(x: b.x - len * cos(ang - .pi / 7), y: b.y - len * sin(ang - .pi / 7)))
            p.move(to: b)
            p.line(to: CGPoint(x: b.x - len * cos(ang + .pi / 7), y: b.y - len * sin(ang + .pi / 7)))
            return p
        case .star:
            return polygon(points: 5, star: true)
        case .hexagon:
            return polygon(points: 6, star: false)
        case .bubble:
            let bodyH = r.height * 0.8
            let body = CGRect(x: r.minX, y: r.minY, width: r.width, height: bodyH)
            let p = NSBezierPath(roundedRect: body, xRadius: 12, yRadius: 12)
            let tail = NSBezierPath()
            tail.move(to: CGPoint(x: r.minX + r.width * 0.28, y: r.minY + bodyH - 1))
            tail.line(to: CGPoint(x: r.minX + r.width * 0.20, y: r.maxY))
            tail.line(to: CGPoint(x: r.minX + r.width * 0.44, y: r.minY + bodyH - 1))
            tail.close()
            p.append(tail)
            return p
        }
    }

    private func polygon(points count: Int, star: Bool) -> NSBezierPath {
        let cx = frame.midX, cy = frame.midY
        let rx = frame.width / 2, ry = frame.height / 2
        let p = NSBezierPath()
        let steps = star ? count * 2 : count
        for i in 0..<steps {
            let ang = -CGFloat.pi / 2 + CGFloat(i) * (2 * .pi / CGFloat(steps))
            let f: CGFloat = star ? (i % 2 == 0 ? 1.0 : 0.42) : 1.0
            let pt = CGPoint(x: cx + cos(ang) * rx * f, y: cy + sin(ang) * ry * f)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.close()
        return p
    }
}

/// An editable text object, placed and sized like a shape.
struct EditableText: Identifiable {
    let id = UUID()
    var frame: CGRect
    var string: String
    var fontSize: CGFloat = 24
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var alignment: NSTextAlignment = .left
    var color: NSColor = .labelColor
    var fontName: String = "Helvetica"

    /// The font honouring name, size and bold/italic traits.
    func nsFont() -> NSFont {
        var font = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let fm = NSFontManager.shared
        if bold { font = fm.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = fm.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    /// The attributed string used for rendering into the flattened image.
    func attributedString() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        var attrs: [NSAttributedString.Key: Any] = [
            .font: nsFont(),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: string, attributes: attrs)
    }
}

/// Fonts offered in the text object's font menu.
let drawingFontNames = ["Helvetica", "Menlo", "Times New Roman", "Georgia", "Courier New", "Snell Roundhand"]

// MARK: - Custom canvas (macOS lacks PKCanvasView)

/// Transparent `NSView` that captures freehand input (stored as a `PKDrawing`)
/// and manages editable vector shapes above it.
final class NoteDrawingView: NSView {
    // Ink settings pushed in from SwiftUI.
    var inkType: PKInkingTool.InkType = .pen
    var inkColor: NSColor = .black
    var inkWidth: CGFloat = 4
    var isEraser = false
    var preciseEraser = false

    /// Called when the selected shape changes (or its geometry updates).
    var onSelectionChange: ((EditableShape?) -> Void)?
    /// Called when the selected text object changes.
    var onTextChange: ((EditableText?) -> Void)?
    /// Called when a text object should enter edit mode (added or double-clicked).
    var onEditText: (() -> Void)?
    /// Id of the text currently being edited via the SwiftUI overlay; the canvas
    /// skips drawing it so the two don't overlap. Driven from SwiftUI.
    var editingTextID: UUID? { didSet { if oldValue != editingTextID { needsDisplay = true } } }

    private(set) var drawing = PKDrawing()
    private(set) var shapes: [EditableShape] = []
    private(set) var texts: [EditableText] = []
    private var selectedID: UUID?

    private var livePoints: [CGPoint] = []
    private var dragMode: DragMode = .none
    private var lastPoint: CGPoint = .zero

    private typealias Snapshot = (PKDrawing, [EditableShape], [EditableText])
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    private let handleSize: CGFloat = 11

    private enum DragMode { case none, draw, erase, move, resize(Int) }

    override var isFlipped: Bool { true }              // top-left origin, matches PKDrawing
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: (selectedID != nil) ? .arrow : .crosshair)
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)

        // Double-click on a text → edit it.
        if event.clickCount == 2, let t = texts.last(where: { $0.frame.contains(p) }) {
            selectedID = t.id; notifySelection(); onEditText?(); needsDisplay = true; return
        }

        // 1. A handle of the selected object → resize.
        if let id = selectedID, let f = objectFrame(id), let h = handleIndex(at: p, frame: f) {
            pushUndo(); dragMode = .resize(h); lastPoint = p; return
        }
        // 2. Click on a text or shape (texts sit on top) → select + move.
        if let id = topObject(at: p) {
            pushUndo()
            selectedID = id
            dragMode = .move; lastPoint = p
            notifySelection(); needsDisplay = true
            window?.invalidateCursorRects(for: self)
            return
        }
        // 3. Empty space → deselect; then erase or draw.
        if selectedID != nil { selectedID = nil; notifySelection(); needsDisplay = true }
        if isEraser { pushUndo(); dragMode = .erase; erase(at: p); needsDisplay = true; return }
        pushUndo(); dragMode = .draw; livePoints = [p]; needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .resize(let h): resizeSelected(handle: h, to: p); notifySelection()
        case .move:
            moveSelected(by: CGPoint(x: p.x - lastPoint.x, y: p.y - lastPoint.y))
            lastPoint = p; notifySelection()
        case .erase: erase(at: p)
        case .draw:  livePoints.append(p)
        case .none:  break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .draw = dragMode, livePoints.count > 1 {
            drawing = PKDrawing(strokes: drawing.strokes + [stroke(from: livePoints)])
        }
        livePoints = []; dragMode = .none; needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        // Delete / Backspace removes the selected shape.
        if selectedID != nil, event.keyCode == 51 || event.keyCode == 117 {
            deleteSelected(); return
        }
        super.keyDown(with: event)
    }

    // MARK: Rendering

    override func draw(_ dirtyRect: NSRect) {
        // Shapes first, so pen strokes can be drawn on top of them.
        for shape in shapes { drawShape(shape) }
        // Text objects (the one being edited is shown via a SwiftUI overlay, so skip it).
        for text in texts where text.id != editingTextID { drawText(text) }

        // PencilKit strokes (committed + live), with the real ink effect.
        var strokes = drawing.strokes
        if livePoints.count > 1 { strokes.append(stroke(from: livePoints)) }
        if !strokes.isEmpty {
            PKDrawing(strokes: strokes)
                .image(from: bounds, scale: window?.backingScaleFactor ?? 2)
                .draw(in: bounds)
        }

        // Selection chrome on top.
        if let id = selectedID, let f = objectFrame(id) { drawSelection(f) }
    }

    private func drawText(_ text: EditableText) {
        text.attributedString().draw(in: text.frame)
    }

    private func drawShape(_ shape: EditableShape) {
        let path = shape.path()
        path.lineWidth = shape.lineWidth
        path.lineJoinStyle = .round
        if shape.kind.isClosed, let fill = shape.fill { fill.setFill(); path.fill() }
        if let stroke = shape.stroke { stroke.setStroke(); path.stroke() }
    }

    private func drawSelection(_ frame: CGRect) {
        let box = NSBezierPath(rect: frame)
        box.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        box.stroke()
        for point in handlePoints(frame) {
            let r = NSRect(x: point.x - handleSize / 2, y: point.y - handleSize / 2,
                           width: handleSize, height: handleSize)
            let dot = NSBezierPath(ovalIn: r)
            NSColor.white.setFill(); dot.fill()
            NSColor.controlAccentColor.setStroke(); dot.lineWidth = 1.5; dot.stroke()
        }
    }

    // MARK: Strokes

    private func stroke(from points: [CGPoint]) -> PKStroke {
        let ink = PKInkingTool(inkType, color: inkColor, width: inkWidth).ink
        let strokePoints = points.enumerated().map { index, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(index) * 0.01,
                          size: CGSize(width: inkWidth, height: inkWidth),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: strokePoints, creationDate: Date()))
    }

    // MARK: Eraser

    private func erase(at point: CGPoint) {
        preciseEraser ? erasePrecise(at: point) : eraseObject(at: point)
    }

    private func eraseObject(at point: CGPoint) {
        let radius: CGFloat = 14
        let kept = drawing.strokes.filter { stroke in
            for sp in stroke.path {
                let p = sp.location.applying(stroke.transform)
                if hypot(p.x - point.x, p.y - point.y) < radius { return false }
            }
            return true
        }
        if kept.count != drawing.strokes.count { drawing = PKDrawing(strokes: kept) }
    }

    private func erasePrecise(at point: CGPoint) {
        let radius: CGFloat = 9
        var result: [PKStroke] = []
        var changed = false
        for stroke in drawing.strokes {
            let points = Array(stroke.path)
            var runs: [[PKStrokePoint]] = []
            var run: [PKStrokePoint] = []
            for sp in points {
                let p = sp.location.applying(stroke.transform)
                if hypot(p.x - point.x, p.y - point.y) < radius {
                    changed = true
                    if run.count > 1 { runs.append(run) }
                    run = []
                } else { run.append(sp) }
            }
            if run.count > 1 { runs.append(run) }
            if runs.count == 1 && runs[0].count == points.count {
                result.append(stroke)
            } else {
                for segment in runs {
                    result.append(PKStroke(ink: stroke.ink,
                                           path: PKStrokePath(controlPoints: segment, creationDate: Date()),
                                           transform: stroke.transform))
                }
            }
        }
        if changed { drawing = PKDrawing(strokes: result) }
    }

    // MARK: Shape geometry / editing

    private func handlePoints(_ f: CGRect) -> [CGPoint] {
        [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.midX, y: f.minY), CGPoint(x: f.maxX, y: f.minY),
         CGPoint(x: f.maxX, y: f.midY),
         CGPoint(x: f.maxX, y: f.maxY), CGPoint(x: f.midX, y: f.maxY), CGPoint(x: f.minX, y: f.maxY),
         CGPoint(x: f.minX, y: f.midY)]
    }

    private func handleIndex(at point: CGPoint, frame: CGRect) -> Int? {
        for (i, h) in handlePoints(frame).enumerated() {
            if abs(point.x - h.x) <= handleSize && abs(point.y - h.y) <= handleSize { return i }
        }
        return nil
    }

    /// The frame of any selectable object (shape or text) by id.
    private func objectFrame(_ id: UUID) -> CGRect? {
        shapes.first(where: { $0.id == id })?.frame ?? texts.first(where: { $0.id == id })?.frame
    }

    private func setObjectFrame(_ id: UUID, _ f: CGRect) {
        if let i = shapes.firstIndex(where: { $0.id == id }) { shapes[i].frame = f }
        else if let i = texts.firstIndex(where: { $0.id == id }) { texts[i].frame = f }
    }

    /// Topmost object hit at `point` (texts sit above shapes).
    private func topObject(at point: CGPoint) -> UUID? {
        if let t = texts.last(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(point) }) { return t.id }
        if let s = shapes.last(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(point) }) { return s.id }
        return nil
    }

    private func resizeSelected(handle: Int, to p: CGPoint) {
        guard let id = selectedID, var f = objectFrame(id) else { return }
        var minX = f.minX, minY = f.minY, maxX = f.maxX, maxY = f.maxY
        switch handle {
        case 0: minX = p.x; minY = p.y
        case 1: minY = p.y
        case 2: maxX = p.x; minY = p.y
        case 3: maxX = p.x
        case 4: maxX = p.x; maxY = p.y
        case 5: maxY = p.y
        case 6: minX = p.x; maxY = p.y
        case 7: minX = p.x
        default: break
        }
        f = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                   width: max(12, abs(maxX - minX)), height: max(12, abs(maxY - minY)))
        setObjectFrame(id, f)
    }

    private func moveSelected(by d: CGPoint) {
        guard let id = selectedID, let f = objectFrame(id) else { return }
        setObjectFrame(id, f.offsetBy(dx: d.x, dy: d.y))
    }

    private func notifySelection() {
        onSelectionChange?(shapes.first(where: { $0.id == selectedID }))
        onTextChange?(texts.first(where: { $0.id == selectedID }))
    }

    // MARK: SwiftUI-facing API

    func addShape(_ kind: ShapeKind) {
        pushUndo()
        let center = CGPoint(x: bounds.midX == 0 ? 200 : bounds.midX,
                             y: bounds.midY == 0 ? 200 : bounds.midY)
        let size: CGFloat = 130
        let frame = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        let shape = EditableShape(kind: kind, frame: frame,
                                  fill: kind.isClosed ? NSColor.systemGray.withAlphaComponent(0.3) : nil,
                                  stroke: NSColor.systemGray, lineWidth: 3)
        shapes.append(shape)
        selectedID = shape.id
        notifySelection(); needsDisplay = true
        window?.makeFirstResponder(self)
    }

    func setSelectedFill(_ color: NSColor?) { mutateSelected { $0.fill = color } }
    func setSelectedStroke(_ color: NSColor?) { mutateSelected { $0.stroke = color } }
    func setSelectedLineWidth(_ width: CGFloat) { mutateSelected { $0.lineWidth = width } }

    /// Adds a new (empty) text object, centred and selected for editing.
    func addText() {
        pushUndo()
        let center = CGPoint(x: bounds.midX == 0 ? 200 : bounds.midX,
                             y: bounds.midY == 0 ? 120 : bounds.midY)
        let size = CGSize(width: 240, height: 56)
        let text = EditableText(frame: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                              width: size.width, height: size.height),
                                string: "")
        texts.append(text)
        selectedID = text.id
        notifySelection(); onEditText?(); needsDisplay = true
        window?.makeFirstResponder(self)
    }

    func selectedTextString() -> String { texts.first(where: { $0.id == selectedID })?.string ?? "" }

    /// Updates the selected text's content (no undo entry — called while typing).
    func setSelectedTextString(_ s: String) {
        guard let i = texts.firstIndex(where: { $0.id == selectedID }) else { return }
        texts[i].string = s
        needsDisplay = true
    }

    /// Applies a formatting change to the selected text (with an undo entry).
    func mutateSelectedText(_ change: (inout EditableText) -> Void) {
        guard let i = texts.firstIndex(where: { $0.id == selectedID }) else { return }
        pushUndo()
        change(&texts[i])
        notifySelection(); needsDisplay = true
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        pushUndo()
        shapes.removeAll { $0.id == id }
        texts.removeAll { $0.id == id }
        selectedID = nil
        notifySelection(); needsDisplay = true
    }

    private func mutateSelected(_ change: (inout EditableShape) -> Void) {
        guard let idx = shapes.firstIndex(where: { $0.id == selectedID }) else { return }
        pushUndo()
        change(&shapes[idx])
        notifySelection(); needsDisplay = true
    }

    // MARK: Undo / redo

    private func pushUndo() { undoStack.append((drawing, shapes, texts)); redoStack.removeAll() }

    func undoDraw() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append((drawing, shapes, texts))
        drawing = last.0; shapes = last.1; texts = last.2; selectedID = nil
        notifySelection(); needsDisplay = true
    }

    func redoDraw() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((drawing, shapes, texts))
        drawing = next.0; shapes = next.1; texts = next.2; selectedID = nil
        notifySelection(); needsDisplay = true
    }

    // MARK: Flatten to image

    /// Renders shapes + strokes into a single image covering all content.
    func flattenedImage() -> NSImage? {
        var content = drawing.bounds
        for shape in shapes { content = content.isEmpty ? shape.frame : content.union(shape.frame) }
        for text in texts { content = content.isEmpty ? text.frame : content.union(text.frame) }
        content = content.insetBy(dx: -8, dy: -8)
        guard content.width > 1, content.height > 1 else { return nil }

        let image = NSImage(size: content.size)
        image.lockFocusFlipped(true)
        NSGraphicsContext.current?.cgContext.translateBy(x: -content.minX, y: -content.minY)
        for shape in shapes { drawShape(shape) }
        for text in texts { drawText(text) }
        if !drawing.bounds.isEmpty {
            drawing.image(from: content, scale: 2).draw(in: content)
        }
        image.unlockFocus()
        return image
    }
}

/// SwiftUI wrapper feeding the current ink settings into the canvas.
private struct DrawingSurface: NSViewRepresentable {
    let view: NoteDrawingView
    let inkType: PKInkingTool.InkType
    let color: NSColor
    let width: CGFloat
    let isEraser: Bool
    let preciseEraser: Bool
    let editingTextID: UUID?

    func makeNSView(context: Context) -> NoteDrawingView {
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .onSetNeedsDisplay
        return view
    }

    func updateNSView(_ nsView: NoteDrawingView, context: Context) {
        nsView.inkType = inkType
        nsView.inkColor = color
        nsView.inkWidth = width
        nsView.isEraser = isEraser
        nsView.preciseEraser = preciseEraser
        nsView.editingTextID = editingTextID
    }
}

// MARK: - Text size combo

/// Editable combo box for a text object's size (type a value or pick a preset).
private struct TextSizeCombo: NSViewRepresentable {
    let size: CGFloat
    let onChange: (CGFloat) -> Void

    static let presets = [10, 12, 14, 18, 24, 30, 36, 48, 64, 96]

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox()
        combo.addItems(withObjectValues: Self.presets.map { "\($0)" })
        combo.isEditable = true
        combo.completes = true
        combo.controlSize = .small
        combo.font = .systemFont(ofSize: 12)
        combo.delegate = context.coordinator
        combo.stringValue = "\(Int(size))"
        combo.widthAnchor.constraint(equalToConstant: 58).isActive = true
        context.coordinator.combo = combo
        return combo
    }

    func updateNSView(_ nsView: NSComboBox, context: Context) {
        context.coordinator.onChange = onChange
        if nsView.currentEditor() == nil {          // don't clobber while typing
            let text = "\(Int(size))"
            if nsView.stringValue != text { nsView.stringValue = text }
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var onChange: (CGFloat) -> Void
        weak var combo: NSComboBox?
        init(onChange: @escaping (CGFloat) -> Void) { self.onChange = onChange }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo, combo.indexOfSelectedItem >= 0 else { return }
            apply(combo.itemObjectValue(at: combo.indexOfSelectedItem) as? String)
        }
        func controlTextDidEndEditing(_ obj: Notification) { apply(combo?.stringValue) }

        private func apply(_ text: String?) {
            guard let text, let value = Double(text.trimmingCharacters(in: .whitespaces)), value > 0 else { return }
            onChange(CGFloat(value))
        }
    }
}

// MARK: - Colour palette popover

private struct ColorPalettePopover: View {
    let allowNoneLabel: String
    let onPick: (NSColor?) -> Void
    @State private var custom: Color = .black

    private let palette: [NSColor] = [
        .black, .darkGray, .white, .systemTeal, .systemPink, .systemPurple,
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemIndigo
    ]

    var body: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 10), count: 6), spacing: 10) {
                ForEach(palette.indices, id: \.self) { i in
                    Button { onPick(palette[i]) } label: {
                        Circle().fill(Color(nsColor: palette[i]))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(.quaternary, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button(allowNoneLabel) { onPick(nil) }
                    .buttonStyle(.bordered)
                Spacer()
                ColorPicker("", selection: $custom, supportsOpacity: true)
                    .labelsHidden()
                    .onChange(of: custom) { _, new in onPick(NSColor(new)) }
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}

// MARK: - Editor

/// Full drawing editor shown as an overlay inside the note.
struct DrawingEditorView: View {
    /// Rendered PNG's temporary URL, or `nil` when cancelled / empty. The parent
    /// both inserts the drawing and closes the editor from this callback.
    var onFinish: (URL?) -> Void

    @State private var canvas = NoteDrawingView()
    @State private var brush: DrawBrush = .pen
    @State private var isEraser = false
    @State private var preciseEraser = false
    @State private var color: Color = .black
    @State private var widthIndex = 1
    @State private var showBrushes = false
    @State private var showShapes = false
    @State private var selectedShape: EditableShape?
    @State private var showFill = false
    @State private var showStroke = false
    @State private var showWidth = false
    @State private var selectedText: EditableText?
    @State private var editingText = false
    @State private var showTextColor = false
    @State private var showFontMenu = false
    @FocusState private var textFocused: Bool

    private let widths: [CGFloat] = [2, 4, 8, 14, 22]

    var body: some View {
        ZStack {
            DrawingSurface(view: canvas,
                           inkType: brush.inkType, color: NSColor(color),
                           width: widths[widthIndex], isEraser: isEraser, preciseEraser: preciseEraser,
                           editingTextID: editingText ? selectedText?.id : nil)

            // Floating shape toolbar, positioned beneath the selected shape.
            if let shape = selectedShape {
                shapeToolbar(for: shape)
                    .position(x: min(max(shape.frame.midX, 140), 600),
                              y: shape.frame.maxY + 42)
            }

            // Text object: an editing field (when editing) + a formatting toolbar.
            if let text = selectedText {
                if editingText {
                    TextEditor(text: Binding(get: { canvas.selectedTextString() },
                                             set: { canvas.setSelectedTextString($0) }))
                        .font(.system(size: text.fontSize,
                                      weight: text.bold ? .bold : .regular)
                            .italic(text.italic ? true : false))
                        .foregroundColor(Color(nsColor: text.color))
                        .multilineTextAlignment(textAlign(text.alignment))
                        .scrollContentBackground(.hidden)
                        .padding(2)
                        .frame(width: text.frame.width, height: text.frame.height)
                        .background(Color.black.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1))
                        .position(x: text.frame.midX, y: text.frame.midY)
                        .focused($textFocused)
                }
                textToolbar(for: text)
                    .position(x: min(max(text.frame.midX, 200), 600), y: text.frame.maxY + 70)
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            canvas.onSelectionChange = { selectedShape = $0 }
            canvas.onTextChange = { newText in
                selectedText = newText
                if newText == nil { editingText = false }
            }
            canvas.onEditText = { editingText = true; textFocused = true }
        }
        .onChange(of: editingText) { _, editing in if editing { textFocused = true } }
    }

    private func textAlign(_ a: NSTextAlignment) -> TextAlignment {
        switch a {
        case .center: return .center
        case .right:  return .trailing
        default:      return .leading
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            Button(Loc.t("Anuluj", "Cancel")) { onFinish(nil) }
            Spacer()
            Button { canvas.undoDraw() } label: { Image(systemName: "arrow.uturn.backward") }
                .help(Loc.t("Cofnij", "Undo"))
            Button { canvas.redoDraw() } label: { Image(systemName: "arrow.uturn.forward") }
                .help(Loc.t("Ponów", "Redo"))
            Spacer()
            Button(Loc.t("Gotowe", "Done")) { finish() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 4) {
            Button { showBrushes = true } label: {
                HStack(spacing: 2) {
                    Image(systemName: isEraser ? "eraser" : brush.symbol)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .frame(height: 30).padding(.horizontal, 8)
                .background(Capsule().fill(Color.accentColor.opacity(0.20)))
            }
            .buttonStyle(.plain)
            .help(Loc.t("Narzędzie / pędzle", "Tool / brushes"))
            .popover(isPresented: $showBrushes, arrowEdge: .top) { brushPopover }

            ColorPicker("", selection: $color, supportsOpacity: true)
                .labelsHidden().frame(width: 34, height: 30)
                .help(Loc.t("Kolor", "Colour"))

            divider()

            Button { showShapes = true } label: {
                Image(systemName: "square.on.square").frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help(Loc.t("Kształty", "Shapes"))
            .popover(isPresented: $showShapes, arrowEdge: .top) { shapesPopover }

            toolButton("character.textbox", help: Loc.t("Pole tekstowe", "Text box")) { canvas.addText() }
            toolButton("signature", help: Loc.t("Podpis (wkrótce)", "Signature (soon)")) {}
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .frame(maxWidth: .infinity)
    }

    // MARK: Shape toolbar (under the selected shape)

    private func shapeToolbar(for shape: EditableShape) -> some View {
        HStack(spacing: 10) {
            // Fill
            Button { showFill = true } label: { swatch(shape.fill) }
                .buttonStyle(.plain)
                .help(Loc.t("Wypełnienie", "Fill"))
                .popover(isPresented: $showFill, arrowEdge: .bottom) {
                    ColorPalettePopover(allowNoneLabel: Loc.t("Bez wypełnienia", "No fill")) {
                        canvas.setSelectedFill($0); showFill = false
                    }
                }
            // Stroke
            Button { showStroke = true } label: {
                Image(systemName: shape.stroke == nil ? "xmark" : "circle")
                    .foregroundStyle(shape.stroke == nil ? .red : Color(nsColor: shape.stroke!))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(Loc.t("Obrys", "Border"))
            .popover(isPresented: $showStroke, arrowEdge: .bottom) {
                ColorPalettePopover(allowNoneLabel: Loc.t("Bez obrysu", "No border")) {
                    canvas.setSelectedStroke($0); showStroke = false
                }
            }
            // Width
            Button { showWidth = true } label: {
                Image(systemName: "circle.dashed").frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(Loc.t("Grubość", "Thickness"))
            .popover(isPresented: $showWidth, arrowEdge: .bottom) {
                VStack {
                    Slider(value: Binding(
                        get: { shape.lineWidth },
                        set: { canvas.setSelectedLineWidth($0) }
                    ), in: 1...30)
                }
                .padding(12).frame(width: 240)
            }
            // Delete
            Button { canvas.deleteSelected() } label: {
                Image(systemName: "trash").frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(Loc.t("Usuń figurę", "Delete shape"))
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }

    // MARK: Text toolbar (under the selected text)

    private func textToolbar(for text: EditableText) -> some View {
        VStack(spacing: 6) {
            // Row 1 — character styles + colour.
            HStack(spacing: 4) {
                textToggle("bold", on: text.bold) { canvas.mutateSelectedText { $0.bold.toggle() } }
                textToggle("italic", on: text.italic) { canvas.mutateSelectedText { $0.italic.toggle() } }
                textToggle("underline", on: text.underline) { canvas.mutateSelectedText { $0.underline.toggle() } }
                textToggle("strikethrough", on: text.strike) { canvas.mutateSelectedText { $0.strike.toggle() } }
                Divider().frame(height: 18)
                Button { showTextColor = true } label: {
                    Circle().fill(Color(nsColor: text.color)).frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.quaternary, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showTextColor, arrowEdge: .bottom) {
                    ColorPalettePopover(allowNoneLabel: Loc.t("Domyślny", "Default")) { picked in
                        canvas.mutateSelectedText { $0.color = picked ?? .labelColor }
                        showTextColor = false
                    }
                }
            }
            // Row 2 — size (type or pick) and font.
            HStack(spacing: 4) {
                TextSizeCombo(size: text.fontSize) { newSize in
                    canvas.mutateSelectedText { $0.fontSize = newSize }
                }
                Divider().frame(height: 18)
                Menu(text.fontName) {
                    ForEach(drawingFontNames, id: \.self) { name in
                        Button(name) { canvas.mutateSelectedText { $0.fontName = name } }
                    }
                }
                .fixedSize()
            }
            // Row 3 — alignment.
            HStack(spacing: 4) {
                alignBtn("text.alignleft", .left, current: text.alignment)
                alignBtn("text.aligncenter", .center, current: text.alignment)
                alignBtn("text.alignright", .right, current: text.alignment)
                Divider().frame(height: 18)
                Button { canvas.deleteSelected() } label: { Image(systemName: "trash").frame(width: 24, height: 24) }
                    .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }

    private func textToggle(_ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.2) : .clear))
        }
        .buttonStyle(.plain)
    }

    private func alignBtn(_ icon: String, _ a: NSTextAlignment, current: NSTextAlignment) -> some View {
        Button { canvas.mutateSelectedText { $0.alignment = a } } label: {
            Image(systemName: icon)
                .foregroundStyle(current == a ? Color.accentColor : Color.primary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(current == a ? Color.accentColor.opacity(0.2) : .clear))
        }
        .buttonStyle(.plain)
    }

    private func swatch(_ color: NSColor?) -> some View {
        ZStack {
            Circle().fill(color.map { Color(nsColor: $0) } ?? Color.clear)
            if color == nil {
                Image(systemName: "circle.slash").foregroundStyle(.secondary)
            }
        }
        .frame(width: 26, height: 26)
        .overlay(Circle().stroke(.quaternary, lineWidth: 0.5))
    }

    // MARK: Popovers

    private var shapesPopover: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 8), count: 2), spacing: 8) {
            ForEach(ShapeKind.allCases) { kind in
                Button { canvas.addShape(kind); showShapes = false } label: {
                    Image(systemName: kind.symbol).frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(kind.name)
            }
        }
        .padding(12)
    }

    private var brushPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(widths.indices, id: \.self) { i in
                    Button { widthIndex = i } label: {
                        Circle().fill(Color.primary)
                            .frame(width: 6 + CGFloat(i) * 5, height: 6 + CGFloat(i) * 5)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(widthIndex == i ? Color.accentColor.opacity(0.22) : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            ForEach(DrawBrush.allCases) { b in
                Button { brush = b; isEraser = false } label: {
                    HStack {
                        Image(systemName: (brush == b && !isEraser) ? "checkmark" : b.symbol).frame(width: 20)
                        Text(b.name); Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            Button { isEraser = true; preciseEraser = false } label: {
                HStack {
                    Image(systemName: (isEraser && !preciseEraser) ? "checkmark" : "eraser").frame(width: 20)
                    Text(Loc.t("Gumka (linia)", "Eraser (object)")); Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { isEraser = true; preciseEraser = true } label: {
                HStack {
                    Image(systemName: (isEraser && preciseEraser) ? "checkmark" : "eraser.line.dashed").frame(width: 20)
                    Text(Loc.t("Gumka (precyzyjna)", "Eraser (precise)")); Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(12).frame(width: 230)
    }

    private func divider() -> some View {
        Divider().frame(height: 20).padding(.horizontal, 4)
    }

    private func toolButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    // MARK: Done

    private func finish() {
        guard let image = canvas.flattenedImage() else { onFinish(nil); return }
        onFinish(writePNG(image))
    }

    private func writePNG(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let name = "Rysunek-\(UUID().uuidString.prefix(6)).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? png.write(to: url)
        return url
    }
}
