import AppKit
import Foundation
import Testing
@testable import NoteM

/// The attachments list draws 32×32 squares. It used to decode the whole image
/// for each one, on every redraw of the row, and cache nothing (E3-P2-02).
@MainActor
struct ThumbnailCacheTests {

    /// Writes a PNG of the given pixel size into a throwaway folder.
    private func makePNG(side: Int, name: String = UUID().uuidString) -> URL {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.unlockFocus()
        let data = image.tiffRepresentation!
        let png = NSBitmapImageRep(data: data)!.representation(using: .png, properties: [:])!
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteMTests-thumbs-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".png")
        try? png.write(to: url)
        return url
    }

    @Test func thumbnailIsSmallerThanTheFileItCameFrom() {
        ThumbnailCache.shared.clear()
        let url = makePNG(side: 1200)
        let thumb = ThumbnailCache.shared.thumbnail(for: url, side: 32)
        let unwrapped = try! #require(thumb)
        // 32 pt × 3 = 96 px ceiling, versus 1200 px on disk.
        #expect(unwrapped.size.width <= 96)
        #expect(unwrapped.size.height <= 96)
    }

    @Test func secondReadOfTheSameFileComesFromTheCache() {
        ThumbnailCache.shared.clear()
        let url = makePNG(side: 400)
        _ = ThumbnailCache.shared.thumbnail(for: url, side: 32)
        #expect(ThumbnailCache.shared.count == 1)
        _ = ThumbnailCache.shared.thumbnail(for: url, side: 32)
        #expect(ThumbnailCache.shared.count == 1)
    }

    /// A cache keyed on the path alone would keep showing the old picture after
    /// an attachment is replaced with a different file of the same name.
    @Test func replacingTheFileProducesANewThumbnail() throws {
        ThumbnailCache.shared.clear()
        let url = makePNG(side: 300, name: "stale")
        _ = ThumbnailCache.shared.thumbnail(for: url, side: 32)
        #expect(ThumbnailCache.shared.count == 1)

        // Overwrite with different bytes and a later modification date.
        let replacement = makePNG(side: 600, name: "fresh")
        try Data(contentsOf: replacement).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: url.path)

        _ = ThumbnailCache.shared.thumbnail(for: url, side: 32)
        #expect(ThumbnailCache.shared.count == 2)
    }

    @Test func aFileThatIsNotAnImageGivesNothingBack() {
        ThumbnailCache.shared.clear()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteMTests-thumbs-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("notatka.txt")
        try? Data("zwykły tekst".utf8).write(to: url)
        #expect(ThumbnailCache.shared.thumbnail(for: url, side: 32) == nil)
        #expect(ThumbnailCache.shared.count == 0)
    }

    /// The cache is bounded: an unbounded pile of decoded images is a slow leak
    /// in a program left open for days. Same lesson as the drawing undo stack.
    @Test func theCacheStopsGrowingAtItsLimit() {
        ThumbnailCache.shared.clear()
        for index in 0..<210 {
            let url = makePNG(side: 8, name: "n\(index)")
            _ = ThumbnailCache.shared.thumbnail(for: url, side: 32)
        }
        #expect(ThumbnailCache.shared.count <= 200)
    }
}
