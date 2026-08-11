import Foundation
import Testing
@testable import NoteM

/// The meaning-search cache follows the store root. Pointing it at a root with no
/// cache file used to leave the previous store's vectors in memory, so "search by
/// meaning" answered with notes the user had just switched away from.
struct SemanticIndexTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteMSemantic-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent(NoteStore.semanticIndexFile)
    }

    /// Vectors are only ever computed by the embedding model, which is not
    /// available in every environment — so the state is set up by writing the
    /// cache file the index reads, which is the same door a real store uses.
    private func writeCache(_ entries: [UUID: [Double]], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // `[UUID: Entry]` encodes as a JSON array of alternating keys and values —
        // that is how `JSONEncoder` writes a dictionary whose key isn't a String,
        // and the file on disk looks exactly like this.
        var flat: [Any] = []
        for (id, vector) in entries {
            flat.append(id.uuidString)
            flat.append(["hash": 1, "vector": vector] as [String: Any])
        }
        try JSONSerialization.data(withJSONObject: flat).write(to: url)
    }

    @Test func switchingToARootWithoutACacheClearsTheOldVectors() async throws {
        let first = tempURL()
        let id = UUID()
        try writeCache([id: [0.1, 0.2]], to: first)

        let index = SemanticIndex()
        await index.configure(indexURL: first)
        #expect(await index.entryCount == 1)

        // The new root has no cache yet — the ordinary case right after a switch.
        await index.configure(indexURL: tempURL())
        #expect(await index.entryCount == 0)
    }

    @Test func aRootWithItsOwnCacheLoadsIt() async throws {
        let first = tempURL()
        try writeCache([UUID(): [0.1, 0.2]], to: first)
        let second = tempURL()
        try writeCache([UUID(): [0.3], UUID(): [0.4]], to: second)

        let index = SemanticIndex()
        await index.configure(indexURL: first)
        await index.configure(indexURL: second)
        #expect(await index.entryCount == 2)
    }
}
