import Foundation
import Testing
@testable import NoteM

/// A redirected store moves the notes, iCloud and the Obsidian vault all at once,
/// and the preferences variant survives every restart — so the window has to say
/// so. These check the part that decides *what* it says.
///
/// Written against `classify` rather than against the live accessor on purpose:
/// exercising the real one means writing `NoteMStoreRoot` into the preferences of
/// the app hosting the test, and a run that died before cleaning up would leave
/// the user's own NoteM pointing at a scratch folder.
struct StorageRedirectionTests {

    private func classify(
        defaults: String? = nil,
        fromLaunchArgument: Bool = false,
        environment: String? = nil,
        isRunningTests: Bool = false
    ) -> StorageLocation.Redirection? {
        StorageLocation.classify(
            defaultsPath: defaults,
            defaultsCameFromLaunchArgument: fromLaunchArgument,
            environmentPath: environment,
            testHostPath: "/tmp/host",
            isRunningTests: isRunningTests
        )
    }

    @Test func realNotesMeanNoIndicator() {
        #expect(classify() == nil)
        // An empty string is what a cleared `defaults write` leaves behind — it is
        // not a redirect to an empty path.
        #expect(classify(defaults: "", environment: "") == nil)
    }

    /// The distinction the whole indicator exists for: a value in the preferences
    /// is still there tomorrow, a launch argument is not — and both arrive through
    /// the same `UserDefaults` lookup.
    @Test func aStoredRedirectIsToldApartFromALaunchArgument() {
        #expect(classify(defaults: "/tmp/x") == .preferences("/tmp/x"))
        #expect(classify(defaults: "/tmp/x", fromLaunchArgument: true) == .launchArgument("/tmp/x"))
    }

    @Test func theEnvironmentRedirectsForOneLaunch() {
        #expect(classify(environment: "/tmp/y") == .launchArgument("/tmp/y"))
    }

    /// Preferences win over the environment, matching the order the roots are
    /// resolved in — the indicator must name the path actually in use.
    @Test func preferencesWinOverTheEnvironment() {
        #expect(classify(defaults: "/tmp/x", environment: "/tmp/y") == .preferences("/tmp/x"))
    }

    /// An `xcodebuild test` run launches the real app as its host; without its own
    /// root that host reads and rewrites the user's actual notes.
    @Test func aTestHostSaysSo() {
        #expect(classify(isRunningTests: true) == .testHost("/tmp/host"))
        // An explicit redirect still wins: the caller asked for a specific folder.
        #expect(classify(defaults: "/tmp/x", isRunningTests: true) == .preferences("/tmp/x"))
    }
}
