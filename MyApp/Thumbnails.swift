import AppKit
import ImageIO

/// Small, bounded cache of attachment thumbnails.
///
/// The attachments list draws a 32×32 square per row and used to get it from
/// `NSImage(contentsOf:)`, which decodes the **entire** image — a photo off a
/// phone is several megabytes and gets decoded again on every redraw of that
/// row (scrolling, selection, window resize). Nothing was cached, so the cost
/// came back every time.
///
/// Two changes: `CGImageSourceCreateThumbnailAtIndex` reads only enough pixels
/// for the requested size (using the file's embedded thumbnail when there is
/// one), and the result is kept per file so a redraw costs a dictionary lookup.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// A thumbnail is only valid for the bytes it was made from, so the file's
    /// modification date is part of the key: replacing an attachment with a new
    /// file of the same name must not keep showing the old picture.
    private struct Key: Hashable {
        let path: String
        let modified: Date?
        let pixels: Int
    }

    private var images: [Key: NSImage] = [:]
    /// Insertion order, used to drop the oldest entries once the cap is hit.
    /// Bounded on purpose: an unbounded cache of decoded images is a slow leak
    /// in a program people leave open for days.
    private var order: [Key] = []
    private let limit = 200

    /// Thumbnail for `url` no larger than `side` points, or `nil` when the file
    /// isn't an image ImageIO can read.
    func thumbnail(for url: URL, side: CGFloat) -> NSImage? {
        // 3× the point size: enough for the densest screen currently sold, and
        // still two orders of magnitude smaller than a full-size photo.
        let pixels = Int(side * 3)
        // `FileManager.attributesOfItem`, not `URL.resourceValues`: a URL caches
        // the resource values it has already been asked for, so a file replaced
        // in place kept reporting its old date — and the cache kept showing the
        // old picture, which is exactly what keying on the date is meant to stop.
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let key = Key(path: url.path, modified: modified, pixels: pixels)
        if let cached = images[key] { return cached }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF rotation
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage,
                            size: NSSize(width: cgImage.width, height: cgImage.height))
        store(image, for: key)
        return image
    }

    private func store(_ image: NSImage, for key: Key) {
        images[key] = image
        order.append(key)
        guard order.count > limit else { return }
        let excess = order.count - limit
        for stale in order.prefix(excess) { images.removeValue(forKey: stale) }
        order.removeFirst(excess)
    }

    /// Drops everything. Used by the tests, and cheap insurance if a store move
    /// ever invalidates every path at once.
    func clear() {
        images.removeAll()
        order.removeAll()
    }

    /// How many thumbnails are held right now — the tests assert on this to show
    /// the cache is a cache and that the cap actually evicts.
    var count: Int { images.count }
}
