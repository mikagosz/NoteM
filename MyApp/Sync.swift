import SwiftUI
import AppKit
import CoreServices

/// Resolves the store root for local vs. iCloud storage.
enum StorageLocation {
    /// `~/Documents/NoteM/`.
    static var localRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoteM", isDirectory: true)
    }

    /// iCloud Drive's user-visible folder (`~/Library/Mobile Documents/…/NoteM`),
    /// or `nil` if iCloud Drive isn't set up on this Mac.
    static var iCloudRoot: URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else { return nil }
        return base.appendingPathComponent("NoteM", isDirectory: true)
    }

    /// The root to use for the given sync preference; falls back to local when
    /// iCloud isn't available.
    static func root(syncEnabled: Bool) -> URL {
        if syncEnabled, let iCloud = iCloudRoot { return iCloud }
        return localRoot
    }
}

/// A note id that exists in more than one folder — i.e. an unresolved sync
/// conflict between two machines editing offline.
struct NoteConflict: Identifiable {
    let id: UUID
    /// The conflicting versions, newest-modified first.
    let versions: [Note]
}

/// Watches a directory tree via FSEvents and calls `onChange` on the main queue
/// whenever anything inside changes — used to pick up edits synced in from
/// another Mac.
final class FileSystemWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start(path: String) {
        stop()
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.8, // latency (s): coalesce bursts of sync activity
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

/// Owns the filesystem watcher and refreshes the notes list when the store
/// changes underneath the app.
@MainActor
@Observable
final class SyncManager {
    static let shared = SyncManager()

    /// Last time an external change was observed (for the status indicator).
    private(set) var lastActivity: Date?

    private weak var model: NotesModel?
    private weak var settings: AppSettings?
    private var watcher: FileSystemWatcher?

    func start(model: NotesModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        refresh()
    }

    /// (Re)starts the watcher on the current store root when sync is enabled.
    func refresh() {
        watcher?.stop()
        watcher = nil
        guard let model, let settings, settings.syncEnabled else { return }

        let watcher = FileSystemWatcher { [weak self] in
            self?.lastActivity = Date()
            self?.model?.reloadFromExternalChange()
        }
        watcher.start(path: model.rootURL.path)
        self.watcher = watcher
    }
}

/// Preferences pane: iCloud sync toggle, status, path, and reveal-in-Finder.
struct SyncSettingsView: View {
    @Bindable var settings: AppSettings
    let model: NotesModel
    /// Called after storage changes so the watcher can be reconfigured.
    let onChange: () -> Void

    @State private var showEnableDialog = false
    @State private var showDisableDialog = false

    private var iCloudAvailable: Bool { StorageLocation.iCloudRoot != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Synchronizacja")
                .font(.headline)
            Text("Przechowuj notatki w iCloud Drive, aby były dostępne i aktualne na innych Macach. "
                 + "Zmiany z innego komputera pojawią się tu automatycznie.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Synchronizuj przez iCloud Drive", isOn: Binding(
                get: { settings.syncEnabled },
                set: { $0 ? (showEnableDialog = true) : (showDisableDialog = true) }
            ))
            .disabled(!iCloudAvailable)

            if !iCloudAvailable {
                Label("iCloud Drive nie jest skonfigurowany na tym Macu.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: settings.syncEnabled ? "checkmark.icloud.fill" : "internaldrive")
                    .foregroundStyle(settings.syncEnabled ? .blue : .secondary)
                Text(settings.syncEnabled ? "Notatki w iCloud Drive" : "Notatki lokalne (Dokumenty)")
                    .font(.callout)
            }

            HStack(spacing: 8) {
                Text(model.rootURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Pokaż w Finderze") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.rootURL])
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 560, height: 380)
        .confirmationDialog("Włączyć synchronizację iCloud?", isPresented: $showEnableDialog, titleVisibility: .visible) {
            Button("Przenieś istniejące notatki do iCloud") { apply(enabled: true, move: true) }
            Button("Zacznij od nowa w iCloud") { apply(enabled: true, move: false) }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Notatki będą przechowywane w iCloud Drive.")
        }
        .confirmationDialog("Wyłączyć synchronizację iCloud?", isPresented: $showDisableDialog, titleVisibility: .visible) {
            Button("Przenieś notatki z powrotem na ten Mac") { apply(enabled: false, move: true) }
            Button("Zostaw w iCloud, używaj lokalnych") { apply(enabled: false, move: false) }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Notatki wrócą do folderu Dokumenty na tym Macu.")
        }
    }

    private func apply(enabled: Bool, move: Bool) {
        settings.syncEnabled = enabled
        model.switchStorage(syncEnabled: enabled, moveExisting: move)
        onChange()
    }
}

/// Side-by-side conflict resolver: for each conflicted id, shows both versions
/// and lets the user keep one (deleting the other).
struct ConflictResolverView: View {
    let model: NotesModel
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Konflikty synchronizacji")
                    .font(.headline)
                Spacer()
                Button("Gotowe", action: onDone)
            }
            .padding()
            Divider()

            if model.conflicts.isEmpty {
                ContentUnavailableView("Brak konfliktów", systemImage: "checkmark.circle")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(model.conflicts) { conflict in
                            ConflictRow(model: model, conflict: conflict)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 720, height: 500)
    }
}

/// One conflicted note id: its versions laid out side by side.
private struct ConflictRow: View {
    let model: NotesModel
    let conflict: NoteConflict

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(conflict.versions.first?.title ?? "Notatka")
                .font(.headline)
            HStack(alignment: .top, spacing: 12) {
                ForEach(conflict.versions) { version in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(version.modified, format: .dateTime.day().month().year().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(version.folderPath)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        ScrollView {
                            Text(model.rawContent(for: version))
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(height: 140)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))
                        Button("Zachowaj tę wersję") {
                            model.resolveConflict(conflict, keeping: version)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).stroke(.orange.opacity(0.5)))
    }
}
