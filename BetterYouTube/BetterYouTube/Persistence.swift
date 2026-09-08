import Foundation

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

    func clearHistory() {
        history.removeAll()
        persist()
    }
}

/// Watch Later, backed by a real playlist in the signed-in account.
///
/// The account's own `WL` playlist has been closed to the API since 2016 and no scope reopens it,
/// so the app keeps a private playlist of its own instead: created on first use, found again by
/// title on a second device or after a reinstall. It is an ordinary playlist, so it syncs
/// everywhere and shows up in the YouTube app like any other. Signed out, this falls straight
/// through to `LibraryStore`'s on-device list, which is what the app has always used.
///
/// The playlist is the source of truth and `entries` is a cache of it. A change is applied
/// locally at once so nothing waits on the network, then sent; if the send fails the local change
/// is rolled back and the reason surfaced. There is no offline queue — a write that failed is
/// reported as failed rather than quietly remembered.
@MainActor
final class WatchLaterStore: ObservableObject {
    static let shared = WatchLaterStore()

    /// Also how the playlist is found again when its id isn't known: renaming it in YouTube means
    /// the app will make a new one.
    static let playlistTitle = "Watch Later — Better YouTube"
    private static let playlistDescription =
        "Your Watch Later list from Better YouTube. YouTube's own Watch Later is closed to apps, so this stands in for it."
    private static let playlistIdKey = "watch_later_playlist_id"

    @Published private(set) var entries: [PlaylistEntry] = []
    @Published private(set) var isLoading = false
    /// Set when a write or a refresh failed, for the UI to show. Cleared by the next success.
    @Published private(set) var errorMessage: String?

    private var playlistId: String? {
        didSet { UserDefaults.standard.set(playlistId, forKey: Self.playlistIdKey) }
    }

    private var auth: GoogleAuthService { .shared }
    private var local: LibraryStore { .shared }
    private let service = YouTubeAPIService.shared

    private init() {
        playlistId = UserDefaults.standard.string(forKey: Self.playlistIdKey)
    }

    // MARK: What the UI reads

    /// True when the list lives in the account rather than only on this device.
    var isSynced: Bool { auth.isSignedIn }

    var videos: [Video] { isSynced ? entries.map(\.video) : local.watchLater }

    func contains(_ video: Video) -> Bool {
        isSynced ? entries.contains { $0.video.id == video.id } : local.isInWatchLater(video)
    }

    /// Videos on this device that the account playlist doesn't have yet.
    var videosOnlyOnThisDevice: [Video] {
        guard isSynced else { return [] }
        return local.watchLater.filter { video in !entries.contains { $0.video.id == video.id } }
    }

    // MARK: Reading

    func refresh() async {
        guard isSynced else { return }
        guard let id = await existingPlaylistId() else {
            entries = []
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await service.entries(inPlaylist: id)
            errorMessage = nil
        } catch APIError.notFound {
            // Deleted from YouTube, or belonging to the account that was signed in before. Forget
            // it so the next add builds a fresh one instead of failing forever. Only a 404 means
            // this — treating every failure as "gone" would make a quota error spawn a duplicate.
            playlistId = nil
            entries = []
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Clears the cached account state. Called when signing out, since the next account will have
    /// a playlist of its own.
    func reset() {
        entries = []
        playlistId = nil
        errorMessage = nil
    }

    // MARK: Writing

    func toggle(_ video: Video) async {
        guard isSynced else {
            local.toggleWatchLater(video)
            return
        }
        if let existing = entries.first(where: { $0.video.id == video.id }) {
            // Still on its way to YouTube: it has no item id yet, so there is nothing to delete.
            guard !Self.isPending(existing) else { return }
            await remove(existing)
        } else {
            await add(video)
        }
    }

    func remove(atOffsets offsets: IndexSet) async {
        guard isSynced else {
            local.removeWatchLater(at: offsets)
            return
        }
        // Resolved up front: each removal mutates `entries`, so the offsets go stale as we go.
        let doomed = offsets.compactMap { index -> PlaylistEntry? in
            entries.indices.contains(index) ? entries[index] : nil
        }
        for entry in doomed where !Self.isPending(entry) {
            await remove(entry)
        }
    }

    /// Sends the videos this device kept before the account playlist existed, oldest first so the
    /// newest ends up on top. 50 quota units each, so it stops at the first refusal rather than
    /// burning the day's allowance on retries.
    func uploadVideosOnlyOnThisDevice() async {
        guard isSynced else { return }
        isLoading = true
        defer { isLoading = false }

        for video in videosOnlyOnThisDevice.reversed() {
            do {
                let id = try await resolvePlaylistId(creatingIfMissing: true)
                let itemId = try await service.addToPlaylist(playlistId: id, videoId: video.id)
                entries.insert(PlaylistEntry(id: itemId, video: video), at: 0)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    // MARK: Importing a Takeout export

    /// What an import did, in the terms the user cares about.
    struct ImportSummary: Equatable {
        var added = 0
        var alreadyThere = 0
        /// Ids the file listed that YouTube no longer serves — deleted or gone private.
        var missing = 0
        var failure: String?

        var isEmpty: Bool { added == 0 && alreadyThere == 0 && missing == 0 }
    }

    /// Reads a playlist CSV from a Google Takeout export into the on-device list.
    ///
    /// It lands on the device rather than in the account playlist on purpose: adding to a playlist
    /// costs 50 quota units a video, so a list of any size would blow through the day's 10,000 in
    /// one go. Settings pushes them up afterwards, at whatever pace the quota allows.
    func importTakeout(from url: URL) async -> ImportSummary {
        isLoading = true
        defer { isLoading = false }

        // The picker hands back a security-scoped url: without this the read fails on device.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            return ImportSummary(failure: "Couldn't read that file.")
        }
        // Takeout writes UTF-8; fall back to Latin-1 rather than refusing a file over one byte.
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return ImportSummary(failure: "Couldn't read that file as text.")
        }

        let ids = TakeoutPlaylistCSV.videoIDs(in: text)
        guard !ids.isEmpty else {
            return ImportSummary(
                failure: "No videos in that file. In the Takeout archive, look under “YouTube and YouTube Music” → “playlists” and pick the CSV for the playlist you want."
            )
        }

        let known = Set(local.watchLater.map(\.id))
        let alreadyThere = ids.filter { known.contains($0) }.count
        let wanted = ids.filter { !known.contains($0) }

        do {
            let videos = try await service.videos(ids: wanted)
            local.addToWatchLater(videos)
            return ImportSummary(
                added: videos.count,
                alreadyThere: alreadyThere,
                missing: wanted.count - videos.count
            )
        } catch {
            return ImportSummary(failure: error.localizedDescription)
        }
    }

    // MARK: Private

    private static func pendingId(for video: Video) -> String { "pending:\(video.id)" }
    private static func isPending(_ entry: PlaylistEntry) -> Bool { entry.id.hasPrefix("pending:") }

    private func add(_ video: Video) async {
        entries.insert(PlaylistEntry(id: Self.pendingId(for: video), video: video), at: 0)
        do {
            let id = try await resolvePlaylistId(creatingIfMissing: true)
            let itemId = try await service.addToPlaylist(playlistId: id, videoId: video.id)
            if let index = entries.firstIndex(where: { $0.id == Self.pendingId(for: video) }) {
                entries[index] = PlaylistEntry(id: itemId, video: video)
            }
            errorMessage = nil
        } catch {
            entries.removeAll { $0.id == Self.pendingId(for: video) }
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ entry: PlaylistEntry) async {
        guard let index = entries.firstIndex(of: entry) else { return }
        entries.remove(at: index)
        do {
            try await service.removePlaylistItem(id: entry.id)
            errorMessage = nil
        } catch {
            entries.insert(entry, at: min(index, entries.count))
            errorMessage = error.localizedDescription
        }
    }

    /// The playlist's id if it exists, without creating one — so simply opening Library never
    /// leaves a playlist behind in the account of someone who never used the feature.
    private func existingPlaylistId() async -> String? {
        if let playlistId { return playlistId }
        guard let found = try? await service.myPlaylists().first(where: { $0.title == Self.playlistTitle })
        else { return nil }
        playlistId = found.id
        return found.id
    }

    private func resolvePlaylistId(creatingIfMissing: Bool) async throws -> String {
        if let id = await existingPlaylistId() { return id }
        guard creatingIfMissing else { throw APIError.notSignedIn }
        let created = try await service.createPlaylist(
            title: Self.playlistTitle,
            description: Self.playlistDescription
        )
        playlistId = created
        return created
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
