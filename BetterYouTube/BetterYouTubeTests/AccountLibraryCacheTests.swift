import Foundation
import Testing
@testable import BetterYouTube

struct AccountLibraryCacheTests {
    private func cache() -> AccountLibraryCache {
        AccountLibraryCache(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    private func playlist(_ id: String, _ title: String, count: Int? = nil) -> Playlist {
        Playlist(id: id, title: title, description: "", thumbnailURL: nil, itemCount: count)
    }

    private func video(_ id: String) -> Video {
        Video(id: id, title: "Title " + id, channelId: "channel", channelTitle: "Channel",
              description: "", thumbnailURL: nil, publishedAt: nil)
    }

    private var channel: Channel {
        Channel(id: "UCme", title: "Me", description: "", thumbnailURL: nil, subscriberCount: 12)
    }

    @Test("Each source survives a round trip, and each sign-in's half clears on its own")
    func halves() throws {
        let cache = cache()
        defer { try? FileManager.default.removeItem(at: cache.folder) }
        cache.save(channel, as: .account)
        cache.save([channel], as: .subscriptions)
        cache.save([video("liked")], as: .likedVideos)
        cache.save([playlist("PLmine", "Mine")], as: .ownedPlaylists)
        cache.save([playlist("PLsaved", "Saved")], as: .webPlaylists)
        cache.save([PlaylistEntry(id: "item", video: video("later"))], as: .watchLater)

        let account: Channel? = cache.load(.account)
        #expect(account == channel)
        let liked: [Video]? = cache.load(.likedVideos)
        #expect(liked?.map(\.id) == ["liked"])

        cache.clearAccount()
        let clearedAccount: Channel? = cache.load(.account)
        let clearedSubscriptions: [Channel]? = cache.load(.subscriptions)
        let clearedLiked: [Video]? = cache.load(.likedVideos)
        let clearedOwned: [Playlist]? = cache.load(.ownedPlaylists)
        #expect(clearedAccount == nil && clearedSubscriptions == nil && clearedLiked == nil && clearedOwned == nil)
        let saved: [Playlist]? = cache.load(.webPlaylists)
        let watchLater: [PlaylistEntry]? = cache.load(.watchLater)
        #expect(saved?.map(\.id) == ["PLsaved"])
        #expect(watchLater?.map(\.id) == ["item"])
        #expect(watchLater?.first?.video.id == "later")

        cache.clearWebSession()
        let clearedSaved: [Playlist]? = cache.load(.webPlaylists)
        let clearedWatchLater: [PlaylistEntry]? = cache.load(.watchLater)
        #expect(clearedSaved == nil && clearedWatchLater == nil)
    }

    @Test("Saving nothing forgets, and missing or corrupt files are ignored")
    func invalid() throws {
        let cache = cache()
        defer { try? FileManager.default.removeItem(at: cache.folder) }
        let missing: Channel? = cache.load(.account)
        #expect(missing == nil)
        cache.clearAccount()

        cache.save(channel, as: .account)
        cache.save(nil as Channel?, as: .account)
        let forgotten: Channel? = cache.load(.account)
        #expect(forgotten == nil)

        try Data("broken JSON".utf8).write(to: cache.folder.appendingPathComponent("subscriptions-v1.json"))
        let corrupt: [Channel]? = cache.load(.subscriptions)
        #expect(corrupt == nil)
    }

    @Test("Library opens on the cached copy, merged in YouTube's order with the API's metadata")
    @MainActor
    func opensOnCache() {
        let cache = cache()
        defer { try? FileManager.default.removeItem(at: cache.folder) }
        cache.save(channel, as: .account)
        cache.save([channel, channel], as: .subscriptions)
        cache.save([video("a"), video("b"), video("c")], as: .likedVideos)
        cache.save([playlist("PLmine", "Mine (API)", count: 3), playlist("PLprivate", "Private")], as: .ownedPlaylists)
        cache.save([playlist("LL", "Liked videos"), playlist("PLsaved", "Saved"), playlist("PLmine", "Mine (web)")],
                   as: .webPlaylists)

        let viewModel = LibraryViewModel(cache: cache)
        #expect(viewModel.account == channel)
        #expect(viewModel.subscriptions.count == 2)
        #expect(viewModel.likedVideos.count == 3)
        #expect(viewModel.playlists.map(\.id) == ["PLsaved", "PLmine", "PLprivate"])
        #expect(viewModel.playlists[1].title == "Mine (API)")
        #expect(!viewModel.isLoading)
    }
}
