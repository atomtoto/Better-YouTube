import Foundation
import Testing
@testable import BetterYouTube

struct AccountLibraryCacheTests {
    private func cache() -> AccountLibraryCache {
        AccountLibraryCache(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("library.json"))
    }

    private func playlist(_ id: String, _ title: String, count: Int? = nil) -> Playlist {
        Playlist(id: id, title: title, description: "", thumbnailURL: nil, itemCount: count)
    }

    private var channel: Channel {
        Channel(id: "UCme", title: "Me", description: "", thumbnailURL: nil, subscriberCount: 12)
    }

    private var snapshot: AccountLibrarySnapshot {
        AccountLibrarySnapshot(
            account: channel,
            subscriptions: [Channel(id: "UCother", title: "Other", description: "", thumbnailURL: nil)],
            ownedPlaylists: [playlist("PLmine", "Mine")],
            likedVideos: [],
            webPlaylists: [playlist("PLsaved", "Saved")]
        )
    }

    @Test("The library survives a round trip, and each sign-in's half clears on its own")
    func halves() throws {
        let cache = cache()
        defer { try? FileManager.default.removeItem(at: cache.url.deletingLastPathComponent()) }
        cache.save(snapshot)
        #expect(cache.load() == snapshot)

        cache.clearAccount()
        let webOnly = try #require(cache.load())
        #expect(webOnly.account == nil)
        #expect(webOnly.subscriptions.isEmpty)
        #expect(webOnly.ownedPlaylists.isEmpty)
        #expect(webOnly.webPlaylists.map(\.id) == ["PLsaved"])

        // Nothing left to show: the file goes rather than holding an empty library.
        cache.clearWebPlaylists()
        #expect(cache.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.url.path))
    }

    @Test("Missing, empty and corrupt library caches are ignored")
    func invalid() throws {
        let cache = cache()
        defer { try? FileManager.default.removeItem(at: cache.url.deletingLastPathComponent()) }
        #expect(cache.load() == nil)
        cache.clearAccount()
        cache.save(AccountLibrarySnapshot())
        #expect(cache.load() == nil)
        try FileManager.default.createDirectory(at: cache.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken JSON".utf8).write(to: cache.url)
        #expect(cache.load() == nil)
    }

    @Test("Library opens on the cached copy, merged in YouTube's order with the API's metadata")
    @MainActor
    func opensOnCache() {
        let cache = cache()
        defer { try? FileManager.default.removeItem(at: cache.url.deletingLastPathComponent()) }
        cache.save(AccountLibrarySnapshot(
            account: channel,
            ownedPlaylists: [playlist("PLmine", "Mine (API)", count: 3), playlist("PLprivate", "Private")],
            webPlaylists: [playlist("LL", "Liked videos"), playlist("PLsaved", "Saved"), playlist("PLmine", "Mine (web)")]
        ))

        let viewModel = LibraryViewModel(cache: cache)
        #expect(viewModel.account == channel)
        #expect(viewModel.playlists.map(\.id) == ["PLsaved", "PLmine", "PLprivate"])
        #expect(viewModel.playlists[1].title == "Mine (API)")
        #expect(!viewModel.isLoading)
    }
}
