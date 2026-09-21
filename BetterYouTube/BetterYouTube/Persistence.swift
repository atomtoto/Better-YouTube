import Foundation
import Combine

/// Persists the on-device library (favorites, watch later, watch history) as JSON in Documents.
///
/// Watch history is local by necessity: the API has never exposed the account's `HL` playlist, and
/// Google closed `WL` alongside it in 2016. Watch Later is local only while signed out — see
/// `WatchLaterStore`, which stands a real playlist in for the one the API won't give us.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var favorites: [Video] = []
    @Published private(set) var watchLater: [Video] = []
    @Published private(set) var history: [Video] = []

    private struct Snapshot: Codable {
        var favorites: [Video]
        var watchLater: [Video]
        var history: [Video]
    }

    private let fileURL: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = documents.appendingPathComponent("library.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        favorites = snapshot.favorites
        watchLater = snapshot.watchLater
        history = snapshot.history
    }

    private func persist() {
        let snapshot = Snapshot(favorites: favorites, watchLater: watchLater, history: history)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func isFavorite(_ video: Video) -> Bool { favorites.contains(video) }
    func isInWatchLater(_ video: Video) -> Bool { watchLater.contains(video) }

    func toggleFavorite(_ video: Video) {
        if let index = favorites.firstIndex(of: video) {
            favorites.remove(at: index)
        } else {
            favorites.insert(video, at: 0)
        }
        persist()
    }

    func toggleWatchLater(_ video: Video) {
        if let index = watchLater.firstIndex(of: video) {
            watchLater.remove(at: index)
        } else {
            watchLater.insert(video, at: 0)
        }
        persist()
    }

    /// Adds many at once, keeping the order they arrive in and skipping what is already there.
    /// Written to disk once — `toggleWatchLater` in a loop would rewrite the file per video.
    func addToWatchLater(_ videos: [Video]) {
        let known = Set(watchLater.map(\.id))
        let fresh = videos.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        watchLater.append(contentsOf: fresh)
        persist()
    }

    func recordWatch(_ video: Video) {
        history.removeAll { $0.id == video.id }
        history.insert(video, at: 0)
        if history.count > 200 {
            history.removeLast(history.count - 200)
        }
        persist()
    }

    func removeFavorites(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        persist()
    }

    func removeWatchLater(at offsets: IndexSet) {
        watchLater.remove(atOffsets: offsets)
        persist()
    }

    func removeFromHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        persist()
    }

    /// Everything this device kept, gone. For the reset in Settings.
    func eraseEverything() {
        favorites = []
        watchLater = []
        history = []
        persist()
    }

    func clearHistory() {
        history.removeAll()
        persist()
    }
}

/// The real YouTube Watch Later through the web session. Without that session, the app keeps the
/// existing on-device list. It never creates a substitute playlist in the Google account.
@MainActor
final class WatchLaterStore: ObservableObject {
    static let shared = WatchLaterStore()

    @Published private(set) var entries: [PlaylistEntry] = []
    @Published private(set) var isLoading = false
    /// Set when a write or a refresh failed, for the UI to show. Cleared by the next success.
    @Published private(set) var errorMessage: String?

    private var local: LibraryStore { .shared }
    private let service = YouTubeAPIService.shared
    private var sessionObservation: AnyCancellable?
    @Published private(set) var usesYouTubeWatchLater = false
    @Published private(set) var sessionRevision = UUID()
    @Published private(set) var pendingVideoIDs: Set<String> = []

    private init() {
        // Remove the obsolete pointer. The playlist itself belongs to the user, so the app does
        // not delete it remotely; it simply never discovers, displays or writes to it again.
        UserDefaults.standard.removeObject(forKey: "watch_later_playlist_id")
        let session = YouTubeWebSession.shared
        usesYouTubeWatchLater = session.isSignedIn
        sessionObservation = session.$isSignedIn.combineLatest(session.$feedGeneration)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .dropFirst().sink { [weak self] signedIn, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.usesYouTubeWatchLater = signedIn
                    self.entries = []
                    self.errorMessage = nil
                    // Library reloads on demand; do not compete with Home during app startup.
                    self.sessionRevision = UUID()
                }
            }
    }

    // MARK: What the UI reads

    /// True when the list lives in the account rather than only on this device.
    var isSynced: Bool { usesYouTubeWatchLater }

    var videos: [Video] { isSynced ? entries.map(\.video) : local.watchLater }

    func contains(_ video: Video) -> Bool {
        isSynced ? entries.contains { $0.video.id == video.id } : local.isInWatchLater(video)
    }

    // MARK: Reading

    func refresh() async {
        guard usesYouTubeWatchLater else { entries = []; return }
        let generation = YouTubeWebSession.shared.feedGeneration
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await YouTubeWebPlaylistService.shared.entries()
            guard usesYouTubeWatchLater, generation == YouTubeWebSession.shared.feedGeneration else { return }
            entries = fetched
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            guard generation == YouTubeWebSession.shared.feedGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Clears the cached account state. Called when signing out, since the next account will have
    /// a playlist of its own.
    func reset() {
        sessionRevision = UUID()
        entries = []
        errorMessage = nil
    }

    // MARK: Writing

    func toggle(_ video: Video) async {
        guard usesYouTubeWatchLater else {
            local.toggleWatchLater(video)
            errorMessage = nil
            return
        }
        await setWebSaved(!contains(video), video: video)
    }

    func remove(atOffsets offsets: IndexSet) async {
        guard isSynced else {
            local.removeWatchLater(at: offsets)
            return
        }
        // Resolve up front because every confirmed web removal replaces `entries`.
        let doomed = offsets.compactMap { index -> PlaylistEntry? in
            entries.indices.contains(index) ? entries[index] : nil
        }
        for entry in doomed { await setWebSaved(false, video: entry.video) }
    }

    // MARK: Importing a Takeout export

    struct TakeoutImport: Equatable {
        var videos: [Video] = []
        /// Ids the file listed that YouTube no longer serves — deleted or gone private.
        var missing = 0
        /// Older entries left behind by the cap below.
        var skippedOlder = 0
        var failure: String?

        var isEmpty: Bool { videos.isEmpty && missing == 0 }
    }

    /// Keep imports bounded. Custom playlist writes cost 50 quota units each and the website path
    /// also confirms every addition, so an unbounded historical import would be surprising.
    static let importLimit = 60

    /// Reads a playlist CSV without choosing its destination. Settings presents the destination
    /// afterwards, so importing a Takeout file can never recreate the removed substitute list.
    func importTakeout(from url: URL) async -> TakeoutImport {
        isLoading = true
        defer { isLoading = false }

        // The picker hands back a security-scoped url: without this the read fails on device.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            return TakeoutImport(failure: "Couldn't read that file.")
        }
        // Takeout writes UTF-8; fall back to Latin-1 rather than refusing a file over one byte.
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return TakeoutImport(failure: "Couldn't read that file as text.")
        }

        let rows = TakeoutPlaylistCSV.rows(in: text)
        guard !rows.isEmpty else {
            return TakeoutImport(
                failure: "No videos in that file. In the Takeout archive, look under “YouTube and YouTube Music” → “playlists” and pick the CSV for the playlist you want."
            )
        }

        // Newest additions first, which is also the order they read in down the list.
        let ids = TakeoutPlaylistCSV.mostRecentlyAdded(in: rows, limit: Self.importLimit)
        let skippedOlder = rows.count - ids.count

        do {
            let fetched = try await service.videos(ids: ids)
            let byID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let videos = ids.compactMap { byID[$0] }
            return TakeoutImport(
                videos: videos,
                missing: ids.count - videos.count,
                skippedOlder: skippedOlder
            )
        } catch {
            return TakeoutImport(failure: error.localizedDescription)
        }
    }

    // MARK: Private

    /// Explicit save, unlike toggle: swiping twice must never remove a saved video.
    func add(_ video: Video) async {
        guard usesYouTubeWatchLater else {
            local.addToWatchLater([video])
            errorMessage = nil
            return
        }
        guard !contains(video) else { errorMessage = nil; return }
        await setWebSaved(true, video: video)
    }

    private func setWebSaved(_ saved: Bool, video: Video) async {
        guard pendingVideoIDs.insert(video.id).inserted else { return }
        defer { pendingVideoIDs.remove(video.id) }
        let generation = YouTubeWebSession.shared.feedGeneration
        do {
            let fetched = try await YouTubeWebPlaylistService.shared.setSaved(saved, videoID: video.id)
            guard usesYouTubeWatchLater, generation == YouTubeWebSession.shared.feedGeneration else { return }
            entries = fetched
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            guard generation == YouTubeWebSession.shared.feedGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

}

/// Recent search terms, mirroring the "Recently Searched" list in Apple's own apps.
@MainActor
final class RecentSearchStore: ObservableObject {
    static let shared = RecentSearchStore()

    @Published private(set) var terms: [String] = []

    private static let storageKey = "recent_searches"
    private static let limit = 12

    private init() {
        terms = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
    }

    func record(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        terms.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        terms.insert(trimmed, at: 0)
        if terms.count > Self.limit { terms.removeLast(terms.count - Self.limit) }
        UserDefaults.standard.set(terms, forKey: Self.storageKey)
    }

    func remove(_ term: String) {
        terms.removeAll { $0 == term }
        UserDefaults.standard.set(terms, forKey: Self.storageKey)
    }

    func clear() {
        terms.removeAll()
        UserDefaults.standard.set(terms, forKey: Self.storageKey)
    }
}
