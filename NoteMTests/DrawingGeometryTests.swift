import AppKit
import PencilKit
import Testing
@testable import NoteM

/// The drawing canvas had 1079 lines and no tests, and three of its bugs were in
/// arithmetic that needs no window at all. These cover that arithmetic: which
/// rectangle the exported image has to be, when a click counts as grabbing a
/// handle, what a resize does to a frame, and when a gesture earns an undo step.
@MainActor
struct DrawingGeometryTests {

    private func shape(_ kind: ShapeKind, _ frame: CGRect,
                       stroke: NSColor? = .black, lineWidth: CGFloat = 3) -> EditableShape {
        EditableShape(kind: kind, frame: frame, fill: nil, stroke: stroke, lineWidth: lineWidth)
    }

    // MARK: - Rectangle of the exported image

    /// A border is stroked centred on the path, so half of it lives outside the
    /// frame. Measuring only the frame cropped thick outlines out of the saved PNG.
    @Test func theExportCoversTheBorderNotJustTheFrame() {
        let thin = NoteDrawingView.contentRect(
            shapes: [shape(.rectangle, CGRect(x: 100, y: 100, width: 50, height: 50), lineWidth: 2)],
            texts: [], drawingBounds: .null
        )
        let thick = NoteDrawingView.contentRect(
            shapes: [shape(.rectangle, CGRect(x: 100, y: 100, width: 50, height: 50), lineWidth: 30)],
            texts: [], drawingBounds: .null
        )

        // 30-point outline reaches 15 points beyond the frame on every side.
        #expect(thick.width == thin.width + 28)
        #expect(thick.minX == thin.minX - 14)
    }

    /// No border, nothing to make room for — otherwise every shape would grow the
    /// image for an outline it does not draw.
    @Test func aShapeWithoutABorderGetsNoExtraRoom() {
        let frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        let borderless = NoteDrawingView.contentRect(
            shapes: [shape(.ellipse, frame, stroke: nil, lineWidth: 30)], texts: [], drawingBounds: .null
        )
        // Just the fixed 8-point margin on each side, nothing for the outline.
        #expect(borderless == CGRect(x: -8, y: -8, width: 56, height: 56))
    }

    /// The text box is fixed at creation while the font size is typed in freely,
    /// so big text overflows its own frame — and used to be cropped in the export.
    @Test func theExportCoversTextThatOverflowsItsBox() {
        var text = EditableText(frame: CGRect(x: 0, y: 0, width: 240, height: 56),
                                string: "Bardzo długi napis, który nie mieści się w ramce")
        text.fontSize = 96

        let rect = NoteDrawingView.contentRect(shapes: [], texts: [text], drawingBounds: .null)
        let drawn = text.attributedString().size()

        #expect(drawn.width > text.frame.width)      // kontrola: napis naprawdę wystaje
        #expect(rect.width >= drawn.width)
    }

    @Test func anEmptyCanvasHasNothingToExport() {
        #expect(NoteDrawingView.contentRect(shapes: [], texts: [], drawingBounds: .null) == .zero)
    }

    // MARK: - Handles

    /// The bug: at a fixed 11-point hit radius, a shape at the 12×12 minimum was
    /// covered by its own handles end to end, so it could only ever be resized.
    @Test func aTinyShapeCanStillBeGrabbedInTheMiddle() {
        let tiny = CGRect(x: 0, y: 0, width: NoteDrawingView.minimumObjectSide,
                          height: NoteDrawingView.minimumObjectSide)
        #expect(NoteDrawingView.handleIndex(at: CGPoint(x: tiny.midX, y: tiny.midY), frame: tiny) == nil)
    }

    /// …and the handles themselves still work, on shapes of every size.
    @Test func cornersAreStillHandles() {
        for side in [12.0, 40.0, 300.0] {
            let frame = CGRect(x: 10, y: 10, width: side, height: side)
            #expect(NoteDrawingView.handleIndex(at: CGPoint(x: frame.minX, y: frame.minY), frame: frame) == 0)
            #expect(NoteDrawingView.handleIndex(at: CGPoint(x: frame.maxX, y: frame.maxY), frame: frame) == 4)
        }
    }

    @Test func aClickFarFromEveryHandleIsNotAHandle() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        #expect(NoteDrawingView.handleIndex(at: CGPoint(x: 100, y: 100), frame: frame) == nil)
    }

    // MARK: - Resize

    @Test func draggingACornerMovesThatCornerOnly() {
        let frame = CGRect(x: 100, y: 100, width: 100, height: 100)
        // Handle 4 is the far corner (maxX, maxY).
        let resized = NoteDrawingView.resizedFrame(frame, handle: 4, to: CGPoint(x: 260, y: 300))
        #expect(resized == CGRect(x: 100, y: 100, width: 160, height: 200))
    }

    @Test func draggingAnEdgeLeavesTheOtherAxisAlone() {
        let frame = CGRect(x: 100, y: 100, width: 100, height: 100)
        // Handle 3 is the right edge.
        let resized = NoteDrawingView.resizedFrame(frame, handle: 3, to: CGPoint(x: 250, y: 999))
        #expect(resized.height == 100)
        #expect(resized.width == 150)
    }

    /// Dragging a corner past the opposite one flips the rectangle rather than
    /// producing a negative width.
    @Test func draggingPastTheOppositeCornerFlipsInsteadOfBreaking() {
        let frame = CGRect(x: 100, y: 100, width: 100, height: 100)
        let resized = NoteDrawingView.resizedFrame(frame, handle: 4, to: CGPoint(x: 20, y: 30))
        #expect(resized.width > 0 && resized.height > 0)
        #expect(resized.minX == 20)
    }

    @Test func anObjectCannotBeShrunkBelowTheMinimum() {
        let frame = CGRect(x: 100, y: 100, width: 100, height: 100)
        let resized = NoteDrawingView.resizedFrame(frame, handle: 4, to: CGPoint(x: 101, y: 101))
        #expect(resized.width == NoteDrawingView.minimumObjectSide)
        #expect(resized.height == NoteDrawingView.minimumObjectSide)
    }

    // MARK: - Shapes

    /// Every shape has to draw inside the frame it was given — otherwise the
    /// export rectangle computed from those frames would be wrong for that kind.
    @Test func everyShapeStaysInsideItsFrame() {
        let frame = CGRect(x: 50, y: 60, width: 120, height: 90)
        for kind in ShapeKind.allCases {
            let bounds = shape(kind, frame).path().bounds
            #expect(frame.insetBy(dx: -1, dy: -1).contains(bounds),
                    "\(kind.rawValue) rysuje się poza własną ramką: \(bounds)")
        }
    }

    // MARK: - Handing the drawing over

    /// The write used to be `try?` with the URL returned regardless, so a failure
    /// handed back a path to a file that was never created — and the editor closed
    /// on it, taking the drawing with it.
    @Test func anImageThatCannotBeEncodedThrowsInsteadOfReturningAPath() {
        #expect(throws: DrawingEditorView.SaveFailure.self) {
            _ = try DrawingEditorView.writePNG(NSImage())    // zero-sized: nothing to encode
        }
    }

    @Test func aRealImageIsWrittenAndIsAPNG() throws {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.red.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 10, height: 10)).fill()
        image.unlockFocus()

        let url = try DrawingEditorView.writePNG(image)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FileManager.default.fileExists(atPath: url.path))
        // First bytes of a PNG file — proves it is the format, not just a file.
        let head = try Data(contentsOf: url).prefix(4)
        #expect(Array(head) == [0x89, 0x50, 0x4E, 0x47])
    }

    // MARK: - Undo

    /// A click that changes nothing is not an undo step. It used to be one, so
    /// "Undo" had to be pressed twice to undo the last real change.
    @Test func aGestureThatChangedNothingLeavesNoUndoStep() {
        let canvas = NoteDrawingView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(canvas.undoStepCount == 0)

        canvas.addShape(.rectangle)                 // a real change — one step
        #expect(canvas.undoStepCount == 1)

        // A click on empty space: select nothing, draw nothing, release.
        canvas.mouseDown(with: click(at: CGPoint(x: 380, y: 380), in: canvas))
        canvas.mouseUp(with: click(at: CGPoint(x: 380, y: 380), in: canvas))
        #expect(canvas.undoStepCount == 1)
    }

    private func click(at point: CGPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }
}
