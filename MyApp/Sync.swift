import SwiftUI
import AppKit

// MARK: - Storage location

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

// MARK: - Notification name

extension Notification.Name {
    /// Posted by NoteStore after each successful manifest write.
    static let noteMStoreDidWriteManifest = Notification.Name("noteMStoreDidWriteManifest")
}

// MARK: - Conflict model

/// A note id that exists in more than one folder — i.e. an unresolved sync
/// conflict between two machines editing offline.
struct NoteConflict: Identifiable {
    let id: UUID
    /// The conflicting versions, newest-modified first.
    let versions: [Note]
}

// MARK: - SyncManager (polling-based, no FSEvents / no entitlements)

/// Polls `manifest.json` every 7 seconds to detect changes made on another Mac
/// and reloads notes accordingly. Also monitors iCloud Drive availability.
@MainActor
@Observable
final class SyncManager {
    static let shared = SyncManager()

    /// Last time an external change was detected (shown in the UI).
    private(set) var lastActivity: Date?

    /// Set when iCloud Drive becomes unavailable or a write fails.
    /// `nil` means everything is working normally.
    private(set) var syncError: String?

    private weak var model: NotesModel?
    private weak var settings: AppSettings?

    private var pollTimer: Timer?
    /// The manifest timestamp we saw most recently (ours or another Mac's).
    private var lastManifestDate: Date?
    /// Observer token for the "we just wrote manifest locally" notification.
    private var manifestObserver: Any?

    // MARK: - Lifecycle

    func start(model: NotesModel, settings: AppSettings) {
        self.model = model
        self.settings = settings

        // Propagate write errors from NoteStore to the UI.
        model.onStoreWriteError = { [weak self] msg in
            Task { @MainActor [weak self] in
                self?.syncError = msg
            }
        }

        // When we ourselves write the manifest, update lastManifestDate so
        // the next poll won't treat our own change as an external one.
        manifestObserver = NotificationCenter.default.addObserver(
            forName: .noteMStoreDidWriteManifest,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.lastManifestDate = self?.model?.readManifestDate()
            }
        }

        refresh()
    }

    /// (Re)starts or stops the polling timer based on the current sync setting.
    func refresh() {
        pollTimer?.invalidate()
        pollTimer = nil
        syncError = nil

        guard let model, let settings, settings.syncEnabled else { return }

        // Seed initial timestamp so the first poll doesn't immediately reload.
        lastManifestDate = model.readManifestDate()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 7, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
    }

    /// Clears the current error and restarts the polling cycle.
    func retrySync() {
        syncError = nil
        refresh()
    }

    // MARK: - Polling

    private func poll() {
        guard let model, let settings, settings.syncEnabled else { return }

        // Detect iCloud Drive going away (disabled in System Preferences, etc.).
        guard StorageLocation.iCloudRoot != nil else {
            syncError = "iCloud Drive niedostępny — działam lokalnie"
            return
        }

        // Clear a previous error if iCloud came back.
        if syncError != nil { syncError = nil }

        guard let current = model.readManifestDate() else { return }
        guard current != lastManifestDate else { return }

        lastManifestDate = current
        model.reloadFromExternalChange()
        lastActivity = Date()
    }
}

// MARK: - SyncSettingsView

/// Preferences pane: iCloud sync toggle, status, path, and reveal-in-Finder.
struct SyncSettingsView: View {
    @Bindable var settings: AppSettings
    let model: NotesModel
    /// Called after storage changes so the poller can be reconfigured.
    let onChange: () -> Void

    @State private var showEnableDialog = false
    @State private var showDisableDialog = false

    private var iCloudAvailable: Bool { StorageLocation.iCloudRoot != nil }
    private var syncError: String? { SyncManager.shared.syncError }
    private var lastActivity: Date? { SyncManager.shared.lastActivity }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Synchronizacja")
                .font(.headline)
            Text("Przechowuj notatki w iCloud Drive, aby były dostępne i aktualne na innych Macach. "
                 + "Zmiany z innego komputera wykrywane są co ~7 sekund.")
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

            // Error banner with retry
            if let error = syncError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.icloud.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Spróbuj ponownie") {
                        SyncManager.shared.retrySync()
                    }
                    .font(.caption)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: settings.syncEnabled ? "checkmark.icloud.fill" : "internaldrive")
                    .foregroundStyle(settings.syncEnabled ? .blue : .secondary)
                Text(settings.syncEnabled ? "Notatki w iCloud Drive" : "Notatki lokalne (Dokumenty)")
                    .font(.callout)
                Spacer()
                if let date = lastActivity {
                    Text("Ostatnia zmiana: \(date, format: .dateTime.hour().minute().second())")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
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
        .frame(width: 560, height: 400)
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

// MARK: - ConflictResolverView

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
