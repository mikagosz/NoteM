import Darwin
import Foundation

/// Where every file a test writes goes: one folder per test process, removed when the
/// process exits.
///
/// The helpers used to create their own folders straight in the temporary directory and
/// remove them — at best — in a `deinit`. That was not enough: one full run left about 230
/// folders behind (1 145 after five runs, 9 MB; dynamic audit 2026-11-12). The thumbnail
/// tests never removed their PNGs, attachment sources had no cleanup at all, and a
/// `TempStore` dropped with `_` was deinitialised at once, so its store simply recreated the
/// folder afterwards. Now nothing depends on when a single object goes away.
///
/// A run that dies halfway cannot clean up after itself; the next run removes the folders
/// of processes that no longer exist.
nonisolated enum TestScratch {

    private static let runPrefix = "NoteMTests-run-"
    /// The test host's own store (`StorageLocation.testRoot` in the app).
    private static let hostPrefix = "NoteM-testy-"

    static let root: URL = {
        let temp = FileManager.default.temporaryDirectory
        removeFoldersOfFinishedRuns(in: temp)
        let url = temp.appendingPathComponent(runPrefix + String(getpid()), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        atexit { TestScratch.removeOwnFolders() }
        return url
    }()

    /// A new, empty folder of its own for one test.
    static func folder(_ label: String) -> URL {
        let url = root.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func removeOwnFolders() {
        let temp = FileManager.default.temporaryDirectory
        for prefix in [runPrefix, hostPrefix] {
            try? FileManager.default.removeItem(at: temp.appendingPathComponent(prefix + String(getpid())))
        }
    }

    /// Folders named after a process that has ended — only these two exact prefixes.
    private static func removeFoldersOfFinishedRuns(in temp: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        for name in names {
            for prefix in [runPrefix, hostPrefix] where name.hasPrefix(prefix) {
                guard let pid = Int32(name.dropFirst(prefix.count)), pid != getpid(),
                      kill(pid, 0) != 0, errno == ESRCH else { continue }
                try? FileManager.default.removeItem(at: temp.appendingPathComponent(name))
            }
        }
    }
}
