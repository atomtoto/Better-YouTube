import Foundation
import SwiftUI

/// Trying the app without an account or a key.
///
/// A demo shows real videos — they play for real — and fills every screen from `DemoCatalog`,
/// served by `DemoServer` in place of the Data API. It has an account to show, read-only: the
/// subscriptions, playlists and liked videos are there, and anything that would change YouTube
/// says it needs a sign-in.
///
/// It stays out of the way of whatever is really on the device. The library, playback positions,
/// notifications inbox and recent searches move to files of the demo's own while it runs, iCloud
/// sync and the watch are paused so nothing of it travels, and the quota count is left alone.
/// Ending it deletes all of that — the videos downloaded meanwhile too — and puts the real library
/// back exactly as it was.
///
/// Started from the welcome screen, or from a `betteryoutube://demo` link, which is what a tester
/// or App Review can be handed. Ended from Settings, or from the Demo menu on Home and Library.
@MainActor
final class DemoMode: ObservableObject {
    static let shared = DemoMode()

    nonisolated private static let runningKey = "demo_mode_running"
    private static let downloadsKey = "demo_mode_downloads"

    /// Whether a demo is running, readable from any thread: the API client and the URL protocol
    /// ask on every request. Kept in the defaults, so a demo carries on after the app is closed.
    nonisolated static var isRunning: Bool { UserDefaults.standard.bool(forKey: runningKey) }

    /// The same, for views to follow.
    @Published private(set) var isActive = DemoMode.isRunning

    private init() {}

    // MARK: - Where the demo keeps its things

    nonisolated private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// The demo's library, positions and inbox: beside the real files, never in place of them.
    nonisolated static var folder: URL {
        documents.appendingPathComponent("Demo", isDirectory: true)
    }

    /// Where a store keeps the file called `name` — the real one, or the demo's while a demo
    /// runs. Asked as the stores are made, which is how a demo running when the app was closed
    /// opens on its own files again.
    nonisolated static func storeFile(_ name: String) -> URL {
        (isRunning ? folder : documents).appendingPathComponent(name)
    }

    // MARK: - Starting and ending

    func enter() {
        guard !isActive else { return }
        // What is playing belongs to the library that is about to be put away.
        PlayerManager.shared.close()
        UserDefaults.standard.set(true, forKey: Self.runningKey)
        isActive = true
        // Moving the stores saves the real library's last changes, which iCloud still takes;
        // only then is sync paused, before anything of the demo can reach it.
        moveStores()
        ICloudSyncService.shared.suspendForDemo()
        if LibraryStore.shared.history.isEmpty, LibraryStore.shared.favorites.isEmpty {
            furnishLibrary()
        }
        GoogleAuthService.shared.demoModeChanged()
        Task { await YouTubeWebSession.shared.refresh() }
        // A demo is a way past the welcome, not a step before it.
        UserDefaults.standard.set(true, forKey: OnboardingProgress.startedKey)
        UserDefaults.standard.set(true, forKey: OnboardingProgress.completedKey)
    }

    /// Ends the demo and deletes everything it kept: its library, inbox and recent searches, and
    /// the videos downloaded while it ran. The real library, sign-ins and sync carry on from
    /// where they were. With nothing set up to fall back on, the welcome screen comes back.
    func exit() async {
        guard isActive else { return }
        PlayerManager.shared.close()
        for videoID in demoDownloads { DownloadManager.shared.remove(videoID) }
        UserDefaults.standard.removeObject(forKey: Self.downloadsKey)
        UserDefaults.standard.set(false, forKey: Self.runningKey)
        isActive = false
        // Sync is still paused here, so the demo's last saves never reach it.
        moveStores()
        try? FileManager.default.removeItem(at: Self.folder)
        UserDefaults.standard.removeObject(forKey: RecentSearchStore.demoStorageKey)
        GoogleAuthService.shared.demoModeChanged()
        await YouTubeWebSession.shared.refresh()
        ICloudSyncService.shared.resumeAfterDemo()
        #if os(iOS)
        WatchPhoneBridge.shared.publishSoon()
        #endif
        if !APIKeyStore.shared.hasKey, !GoogleAuthService.shared.isSignedIn, !YouTubeWebSession.shared.isSignedIn {
            UserDefaults.standard.set(false, forKey: OnboardingProgress.completedKey)
        }
    }

    private func moveStores() {
        LibraryStore.shared.useFile(Self.storeFile("library.json"))
        PlaybackPositionStore.shared.useFile(Self.storeFile("playback-positions.json"))
        NotificationStore.shared.useFile(Self.storeFile("notifications.json"))
        RecentSearchStore.shared.reload()
    }

    // MARK: - Downloads

    private var demoDownloads: [String] {
        UserDefaults.standard.stringArray(forKey: Self.downloadsKey) ?? []
    }

    /// Downloads work in the demo — they need no account — and the ones started in it go with it.
    func noteDownload(_ videoID: String) {
        guard isActive, !demoDownloads.contains(videoID) else { return }
        UserDefaults.standard.set(demoDownloads + [videoID], forKey: Self.downloadsKey)
    }

    // MARK: - A library that looks lived in

    /// History with two videos left part-way through, a few favorites and videos saved for
    /// later, an inbox of new uploads and some recent searches — so Library, Continue Watching
    /// and Notifications have something to show from the first minute.
    private func furnishLibrary() {
        let catalog = DemoCatalog.shared
        func video(_ id: String) -> Video? { catalog.video(id)?.asVideo(in: catalog) }
        func latest(from handle: String, skipping: Int = 0) -> Video? {
            guard let channel = catalog.channel(handle: handle) else { return nil }
            return catalog.uploads(of: channel.id).dropFirst(skipping).first?.asVideo(in: catalog)
        }

        let library = LibraryStore.shared
        // Recorded oldest first, so the last one is the most recent.
        let watched = [latest(from: "@CnesFrance"), latest(from: "@mitocw"), latest(from: "@NASA"),
                       video("_cMxraX_5RE"), video("aqz-KE-bpKQ")].compactMap { $0 }
        watched.forEach(library.recordWatch)

        let positions = PlaybackPositionStore.shared
        for (id, share) in [("aqz-KE-bpKQ", 0.42), ("_cMxraX_5RE", 0.18)] {
            guard let entry = catalog.video(id) else { continue }
            positions.record(videoID: id, seconds: Double(entry.seconds) * share, duration: Double(entry.seconds))
        }
        positions.flush()

        [video("WhWc3b3KhnY"), video("jNQXAC9IVRw"), latest(from: "@NASA", skipping: 1)]
            .compactMap { $0 }.forEach(library.toggleFavorite)
        [video("mN0zPOpADL4"), latest(from: "@NoCopyrightSounds"), latest(from: "@CnesFrance", skipping: 1)]
            .compactMap { $0 }.forEach(library.toggleWatchLater)

        NotificationStore.shared.furnishForDemo(Array(catalog.videos.prefix(4)).map { $0.asVideo(in: catalog) })

        for term in ["ncs", "nasa", "blender"] { RecentSearchStore.shared.record(term) }
    }
}
