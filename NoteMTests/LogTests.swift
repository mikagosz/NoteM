import Foundation
import Testing
@testable import NoteM

/// The log exists so a failure the user reports can be confronted with something.
/// It must not become the one place where the note leaks off the machine, so what
/// these check is mostly what is *absent* from the line.
struct LogTests {

    /// A write error the way Foundation raises one: the path is in the error,
    /// and the path carries both the note's title and the account name.
    private func fileError() -> NSError {
        NSError(
            domain: NSCocoaErrorDomain,
            code: 513,
            userInfo: [
                NSFilePathErrorKey: "/Users/ktos/Documents/NoteM/Inbox/Tajna notatka/note.md",
                NSLocalizedDescriptionKey:
                    "Nie można zapisać „/Users/ktos/Documents/NoteM/Inbox/Tajna notatka/note.md”"
            ]
        )
    }

    @Test func aFailureNamesTheOperationAndTheErrorCode() {
        #expect(Log.message(.noteTextWrite, fileError()) == "note-text-write failed: NSCocoaErrorDomain 513")
    }

    @Test func aFailureWithoutAnErrorStillNamesTheOperation() {
        #expect(Log.message(.trashFolderMissing, nil) == "trash-folder-missing failed")
    }

    /// The point of the whole type. Control sample first: the error handed in
    /// really does carry the path — otherwise the assertions below would pass on
    /// test data that had nothing to leak in the first place.
    @Test func neitherThePathNorTheNoteTitleReachTheLog() {
        let error = fileError()
        #expect(error.localizedDescription.contains("Tajna notatka"))

        let message = Log.message(.noteTextWrite, error)
        #expect(!message.contains("Tajna"))
        #expect(!message.contains("/Users/"))
        #expect(!message.contains("note.md"))
    }
}
