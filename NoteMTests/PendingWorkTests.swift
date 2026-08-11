import Foundation
import Testing
@testable import NoteM

/// `PendingWork` is what stands between a debounced write and a quitting process.
/// Two ways it can fail, and both are silent:
///
/// - a handler that is never called loses the text the user just typed,
/// - a handler that outlives its editor saves that text twice, which for quick
///   capture means a duplicated note.
///
/// Neither shows up in a build; both need this registry to behave exactly.
@MainActor
struct PendingWorkTests {

    /// A registry of its own, so tests never touch the shared instance the running
    /// app uses.
    private func makeRegistry() -> PendingWork { PendingWork() }

    @Test("A registered handler runs when everything is flushed")
    func flushCallsHandler() {
        let work = makeRegistry()
        var calls = 0
        work.register(UUID()) { calls += 1 }

        work.flushAll()

        #expect(calls == 1, "The editor's text has to reach the disk when the app quits")
    }

    @Test("Every open editor is flushed, not just the last one registered")
    func flushCallsEveryHandler() {
        let work = makeRegistry()
        var flushed: Set<String> = []
        work.register(UUID()) { flushed.insert("editor") }
        work.register(UUID()) { flushed.insert("quick capture") }

        work.flushAll()

        #expect(flushed == ["editor", "quick capture"])
    }

    @Test("An unregistered handler is not called again")
    func unregisterStopsTheHandler() {
        let work = makeRegistry()
        let owner = UUID()
        var calls = 0
        work.register(owner) { calls += 1 }

        work.unregister(owner)
        work.flushAll()

        #expect(calls == 0, "A closed quick-capture panel must not save its note a second time")
        #expect(work.pendingCount == 0)
    }

    @Test("Registering the same owner twice leaves one handler, not two")
    func registeringTwiceReplaces() {
        let work = makeRegistry()
        let owner = UUID()
        var calls = 0
        work.register(owner) { calls += 1 }
        work.register(owner) { calls += 1 }

        work.flushAll()

        #expect(calls == 1, "Reopening the same note must not double its save")
        #expect(work.pendingCount == 1)
    }

    @Test("The follow-up step runs after the handlers, never before")
    func afterFlushRunsLast() {
        let work = makeRegistry()
        var order: [String] = []
        work.register(UUID()) { order.append("editor") }
        work.afterFlush = { order.append("obsidian") }

        work.flushAll()

        #expect(order == ["editor", "obsidian"],
                "The vault copy is read off the disk, so it has to see the text the editor just wrote")
    }

    @Test("Flushing twice is harmless")
    func flushIsRepeatable() {
        let work = makeRegistry()
        var calls = 0
        work.register(UUID()) { calls += 1 }

        work.flushAll()
        work.flushAll()

        #expect(calls == 2, "Both runs happen; the handler itself is the one that skips an unchanged note")
        #expect(work.pendingCount == 1, "Flushing does not unregister — the editor is still open")
    }
}
