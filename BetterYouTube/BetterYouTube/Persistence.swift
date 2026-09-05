import Foundation

/// Persists the on-device library (favorites, watch later, watch history) as JSON in Documents.
///
/// These lists are local by necessity: the YouTube Data API has never exposed the account's
/// Watch Later or watch history playlists (Google removed API access to `WL` and `HL` in 2016).
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
