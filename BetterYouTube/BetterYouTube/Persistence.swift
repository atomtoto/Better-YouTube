import Foundation
import Combine

/// The offline library and its per-video sync history, persisted together as JSON in Documents.
/// Watch Later here is the app's own list; the separate youtube.com session uses the account's
/// real playlist through `WatchLaterStore`. Neither YouTube sign-in is copied through iCloud.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore(fileURL: FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("library.json"))

    @Published private(set) var favorites: [Video] = []
    @Published private(set) var watchLater: [Video] = []
    @Published private(set) var history: [Video] = []

    private(set) var syncEntries: [String: CloudSyncEntry] = [:]
    /// Installed by the sync service. Applying remote entries never calls this back.
    var onSyncChange: (([CloudSyncEntry]) -> Void)?

    private struct Snapshot: Codable {
        var favorites: [Video]
        var watchLater: [Video]
        var history: [Video]
        var syncEntries: [String: CloudSyncEntry]?
    }

    private let fileURL: URL
    private var lastLocalMutation = Date.distantPast

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        syncEntries = (snapshot.syncEntries ?? [:]).filter { Self.isLibraryEntry($0.value) }
        // Old installs have only arrays. Give their entries stable, ancient dates, rather than
        // claiming the app's launch time as a fresh edit that could override remote deletions.
        seedLegacy(snapshot.favorites, in: .favorite)
        seedLegacy(snapshot.watchLater, in: .watchLater)
        seedLegacy(snapshot.history, in: .history)
        lastLocalMutation = syncEntries.values.map(\.modifiedAt).max() ?? .distantPast
        rebuildLists()
        persist()
    }

    private func persist() {
        let snapshot = Snapshot(favorites: favorites, watchLater: watchLater, history: history,
                                syncEntries: syncEntries)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func seedLegacy(_ videos: [Video], in list: CloudLibraryList) {
        for (index, video) in videos.enumerated() {
            let key = list.key(for: video.id)
            guard syncEntries[key] == nil else { continue }
            syncEntries[key] = CloudSyncEntry(
                key: key,
                modifiedAt: .distantPast.addingTimeInterval(TimeInterval(videos.count - index)),
                changeID: "legacy.\(key)", video: video
            )
        }
    }

    private static func isLibraryEntry(_ entry: CloudSyncEntry) -> Bool {
        guard let list = CloudLibraryList(key: entry.key),
              let id = list.videoID(in: entry.key), entry.value == nil, entry.position == nil else { return false }
        return entry.video.map { $0.id == id } ?? true
    }

    private func rebuildLists() {
        let ordered = syncEntries.values.filter { $0.video != nil }.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            if $0.changeID != $1.changeID { return $0.changeID > $1.changeID }
            return $0.key < $1.key
        }
        favorites = ordered.filter { CloudLibraryList(key: $0.key) == .favorite }.compactMap(\.video)
        watchLater = ordered.filter { CloudLibraryList(key: $0.key) == .watchLater }.compactMap(\.video)
        history = Array(ordered.filter { CloudLibraryList(key: $0.key) == .history }
            .compactMap(\.video).prefix(200))
    }

    func mergeSyncEntries(_ entries: [CloudSyncEntry]) {
        let merged = CloudSyncEntry.merge(entries.filter(Self.isLibraryEntry), into: syncEntries)
        guard merged != syncEntries else { return }
        syncEntries = merged
        lastLocalMutation = max(lastLocalMutation, merged.values.map(\.modifiedAt).max() ?? .distantPast)
        rebuildLists()
        persist()
    }

    private typealias Edit = (list: CloudLibraryList, videoID: String, video: Video?)

    /// Each operation saves and announces its changed entries once, including deletions. Keep
    /// dates monotonic even after receiving an edit from a device whose clock is ahead.
    private func applyLocal(_ edits: [Edit]) {
        guard !edits.isEmpty else { return }
        var changed: [CloudSyncEntry] = []
        for edit in edits {
            let key = edit.list.key(for: edit.videoID)
            let previous = syncEntries[key]?.modifiedAt ?? .distantPast
            let date = max(Date(), max(previous.addingTimeInterval(0.001),
                                       lastLocalMutation.addingTimeInterval(0.001)))
            lastLocalMutation = date
            let entry = CloudSyncEntry(key: key, modifiedAt: date, changeID: UUID().uuidString,
                                       video: edit.video)
            syncEntries[key] = entry
            changed.append(entry)
        }
        rebuildLists()
        persist()
        onSyncChange?(changed)
    }

    func isFavorite(_ video: Video) -> Bool { favorites.contains(video) }
    func isInWatchLater(_ video: Video) -> Bool { watchLater.contains(video) }

    func toggleFavorite(_ video: Video) {
        applyLocal([(.favorite, video.id, isFavorite(video) ? nil : video)])
    }

    func toggleWatchLater(_ video: Video) {
        applyLocal([(.watchLater, video.id, isInWatchLater(video) ? nil : video)])
    }

    /// Adds a batch at the front, preserving its order and ignoring already saved or repeated
    /// videos. Reversing the edits gives the first imported video the latest ordering date.
    func addToWatchLater(_ videos: [Video]) {
        var known = Set(watchLater.map(\.id))
        let fresh = videos.filter { known.insert($0.id).inserted }
        applyLocal(fresh.reversed().map { (.watchLater, $0.id, $0) })
    }

    func recordWatch(_ video: Video) {
        applyLocal([(.history, video.id, video)])
    }

    func removeFavorites(at offsets: IndexSet) {
        remove(at: offsets, from: favorites, in: .favorite)
    }

    func removeWatchLater(at offsets: IndexSet) {
        remove(at: offsets, from: watchLater, in: .watchLater)
    }

    func removeFromHistory(at offsets: IndexSet) {
        remove(at: offsets, from: history, in: .history)
    }

    private func remove(at offsets: IndexSet, from videos: [Video], in list: CloudLibraryList) {
        applyLocal(offsets.compactMap { index in
            guard videos.indices.contains(index) else { return nil }
            return (list, videos[index].id, nil)
        })
    }

    /// Deletes every saved item, retaining tombstones so an offline device cannot bring it back.
    func eraseEverything() {
        applyLocal(syncEntries.values.compactMap { entry in
            guard entry.video != nil, let list = CloudLibraryList(key: entry.key),
                  let id = list.videoID(in: entry.key) else { return nil }
            return (list, id, nil)
        })
    }

    /// Used only after disabling sync for a reset of this device. No fresh tombstones remain
    /// to erase the iCloud library if the user later enables sync again.
    func eraseLocalCopy() {
        syncEntries = [:]
        rebuildLists()
        lastLocalMutation = .distantPast
        persist()
    }

    /// Moving to another iCloud account copies the visible library only. Deletions from the
    /// previous account must never remove entries in the new one; ancient dates also allow that
    /// account's own removals to win over copied favorites or history.
    func prepareForNewCloudAccount() {
        let savedFavorites = favorites
        let savedWatchLater = watchLater
        let savedHistory = history
        syncEntries = [:]
        seedLegacy(savedFavorites, in: .favorite)
        seedLegacy(savedWatchLater, in: .watchLater)
        seedLegacy(savedHistory, in: .history)
        rebuildLists()
        lastLocalMutation = .distantPast
        persist()
    }

    func clearHistory() {
        // Include retained entries outside the 200-row display cap, or older history would
        // immediately become visible after clearing the newest rows.
        applyLocal(syncEntries.values.compactMap { entry in
            guard entry.video != nil, CloudLibraryList(key: entry.key) == .history,
                  let id = CloudLibraryList.history.videoID(in: entry.key) else { return nil }
            return (.history, id, nil)
        })
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

    /// Explicit removal: removing a video from Watch Later.
    func remove(_ video: Video) async {
        guard usesYouTubeWatchLater else {
            if let index = local.watchLater.firstIndex(of: video) {
                local.removeWatchLater(at: IndexSet(integer: index))
            }
            errorMessage = nil
            return
        }
        guard contains(video) else { errorMessage = nil; return }
        await setWebSaved(false, video: video)
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
