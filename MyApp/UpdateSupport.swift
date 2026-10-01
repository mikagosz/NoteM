import Foundation

/// Which address from the update file may be opened or downloaded. `NSWorkspace.open` on a
/// `file://` address would launch whatever it points at and `smb://` would mount a stranger's
/// share; ErrorUpdate 1.0.1 already drops everything but https when decoding, and here the host
/// is narrowed to our own download server. Foundation only, so the headless check covers it.
enum DownloadAddress {
    static let hosts: Set<String> = ["downloads.fractal8.eu"]

    static func allowed(_ url: URL) -> Bool {
        #if DEBUG
        // The whole update path tested against a server on this Mac (see `Updates.server`).
        if url.scheme?.lowercased() == "http", url.host == "127.0.0.1" { return true }
        #endif
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), hosts.contains(host),
              url.user == nil, url.password == nil
        else { return false }
        return true
    }
}

/// The restart after an update installed from inside the app. Not ErrorUpdate's own relaunch:
/// that one runs `open -n` before the old copy has quit, so for a moment two copies run, both
/// writing the same notes store. A small `/bin/sh` helper waits until this process is
/// really gone and only then opens the new version (the same helper as in Master info,
/// VoiceAI and ColorMyFolder, where it was measured on a real process).
enum RestartAfterUpdate {
    /// How long the helper waits for the old copy to end. After that it gives up and does NOT
    /// open the new one — quitting may have been cancelled, and a second copy next to a live
    /// first one is exactly what the helper is here to prevent.
    static let limitSeconds = 60

    /// Arguments for `/bin/sh`. The pid and the path go in as positional parameters, not pasted
    /// into the script, so no character in the path can change what the helper runs.
    static func helperArguments(pid: Int32, app: URL, opener: String = "/usr/bin/open") -> [String] {
        let steps = limitSeconds * 5   // every 0.2 s
        let script = """
            i=0
            while /bin/kill -0 "$1" 2>/dev/null; do
              i=$((i + 1))
              [ "$i" -gt \(steps) ] && exit 1
              /bin/sleep 0.2
            done
            exec "$3" "$2"
            """
        return ["-c", script, "sh", String(pid), app.path, opener]
    }

    /// Starts the helper and returns at once; launchd adopts it when the app quits.
    static func launchAfterExit(pid: Int32, app: URL, opener: String = "/usr/bin/open") throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = helperArguments(pid: pid, app: app, opener: opener)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Whether the app sits where it can be replaced: not a temporary copy macOS made of an app
    /// opened straight from Downloads (App Translocation), not a read-only disk image, and in a
    /// folder this user may write to.
    static func writablePlace(_ bundle: URL) -> Bool {
        guard bundle.pathExtension == "app" else { return false }
        let path = bundle.standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return false }
        if path.hasPrefix("/Volumes/"),
           (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return false }
        return FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    /// The version read from disk, not from `Bundle.main`, which keeps the Info.plist from
    /// launch and would still show the old version after the swap.
    static func versionOnDisk(_ bundle: URL) -> String? {
        guard let data = try? Data(contentsOf: bundle.appending(path: "Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }
}
