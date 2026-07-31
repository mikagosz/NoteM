import Foundation
@testable import NoteM

/// A `NoteStore` rooted in a throwaway folder, plus whatever it reported through
/// `onDataError`. Every test gets its own root so nothing leaks between them and
/// nothing touches the real `~/Documents/NoteM`.
@MainActor
final class TempStore {
    let root: URL
    let store: NoteStore
    /// Messages the store pushed out as write failures, oldest first.
    private(set) var errors: [String] = []

    init(name: String = UUID().uuidString) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteMTests-" + name, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        store = NoteStore(rootURL: root)
        store.onDataError = { [weak self] message in self?.errors.append(message) }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Absolute URL for a path relative to the store root.
    func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(relativePath).path)
    }

    /// Makes the store's root un-creatable by putting a regular file exactly
    /// where the root folder needs to be — the cheapest way to make every write
    /// fail without root privileges or a mocked FileManager.
    func blockRoot() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(
            at: root.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: root.path, contents: Data("not a folder".utf8))
    }

    /// A file to attach, created inside the temp area (not in the store).
    func makeSourceFile(named name: String, contents: String = "x") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteMTests-src-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? Data(contents.utf8).write(to: url)
        return url
    }
}
