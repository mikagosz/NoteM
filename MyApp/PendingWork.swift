import AppKit
import Foundation

/// Work that is scheduled but not yet on disk, and the one moment it has to be
/// finished whether it is ready or not: the application quitting.
///
/// The editor autosaves a second after the last keystroke and the Obsidian mirror
/// waits three. Both are debounces, and a debounce that never fires is a debounce
/// that loses data. `.onDisappear` does not help here — SwiftUI does not tear down
/// its view tree on `⌘Q`, on logout or on a restart, so the editor's own flush
/// never ran and the last second of typing died with the process. Quick capture was
/// worse: it has no autosave at all, so an open capture panel lost everything typed
/// into it.
///
/// Anything holding unwritten text registers here while it is on screen and
/// unregisters when it goes away. `NSApplication.willTerminateNotification` is
/// delivered on the main thread before the process is torn down, and every write
/// in this app is synchronous, so a flush started from there finishes.
@MainActor
final class PendingWork {
    static let shared = PendingWork()

    /// Flush handlers keyed by whatever the owner uses to identify itself — a note
    /// id for the editor, a per-panel id for quick capture.
    private var handlers: [UUID: () -> Void] = [:]

    /// Runs after every handler above, for work that needs the final text already
    /// written: the debounced Obsidian mirror reads the note back off the disk.
    var afterFlush: (() -> Void)?

    private var terminationObserver: (any NSObjectProtocol)?

    /// Starts listening for termination. Idempotent, because `ContentView.onAppear`
    /// runs once per window (⌘N opens another) and a second registration would mean
    /// flushing everything twice.
    func start() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { PendingWork.shared.flushAll() }
        }
    }

    /// Registers (or replaces) the handler for `owner`.
    func register(_ owner: UUID, flush: @escaping () -> Void) {
        handlers[owner] = flush
    }

    func unregister(_ owner: UUID) {
        handlers.removeValue(forKey: owner)
    }

    /// Whether anything is waiting to be written — used by the tests, and a cheap
    /// way to see that unregistering actually happens.
    var pendingCount: Int { handlers.count }

    /// Puts everything on disk now. Safe to call more than once: a handler whose
    /// content already matches the disk does nothing.
    func flushAll() {
        for handler in handlers.values { handler() }
        afterFlush?()
    }
}
