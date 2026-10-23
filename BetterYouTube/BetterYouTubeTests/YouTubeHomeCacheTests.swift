import Foundation
import Testing
@testable import BetterYouTube

struct YouTubeHomeCacheTests {
    private func video(_ id: String) -> Video {
        Video(id: id, title: "Title " + id, channelId: "channel", channelTitle: "Channel",
              description: "Description", thumbnailURL: nil, publishedAt: nil,
              viewCount: 123, duration: "PT2M")
    }

    @Test("Home cache preserves YouTube ordering and display metadata, then clears")
    func roundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = YouTubeHomeCache(url: folder.appendingPathComponent("home.json"))
        let now = Date()
        let avatar = URL(string: "https://example.com/avatar.jpg")!
        cache.save(YouTubeHomeSnapshot(videos: [video("second"), video("first")],
                                      avatars: ["channel": avatar], savedAt: now))
        let restored = try #require(cache.load(now: now))
        #expect(restored.videos.map(\.id) == ["second", "first"])
        #expect(restored.videos.first?.title == "Title second")
        #expect(restored.videos.first?.viewCount == 123)
        #expect(restored.videos.first?.duration == "PT2M")
        #expect(restored.avatars["channel"] == avatar)
        #expect(cache.load(now: now.addingTimeInterval(86399)) != nil)
        #expect(cache.load(now: now.addingTimeInterval(86400)) == nil)
        #expect(cache.load(now: now.addingTimeInterval(-1)) == nil)
        cache.clear()
        #expect(cache.load(now: now) == nil)
    }

    @Test("Missing, empty and corrupt home caches are ignored")
    func invalidCache() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = YouTubeHomeCache(url: folder.appendingPathComponent("home.json"))
        #expect(cache.load() == nil)
        cache.save(YouTubeHomeSnapshot(videos: [], avatars: [:], savedAt: Date()))
        #expect(cache.load() == nil)
        try Data("broken JSON".utf8).write(to: cache.url)
        #expect(cache.load() == nil)
    }

    @Test("Home's own feeds open on what was saved, and a fresh one isn't bought again")
    @MainActor
    func savedFeedsAreReused() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = AccountLibraryCache(folder: folder)
        let now = Date()
        let signedIn = GoogleAuthService.shared.isSignedIn
        cache.save(HomeFeedSnapshot(recommended: [video("pick")], subscriptionVideos: [video("upload")],
                                    avatars: [:], signedIn: signedIn, savedAt: now.addingTimeInterval(-60)),
                   as: .homeFeeds)

        let stub = StubAPI()
        let home = HomeViewModel(service: stub.service, cache: cache, now: now)
        #expect(home.recommended.map(\.id) == ["pick"])
        #expect(home.subscriptionVideos.map(\.id) == ["upload"])

        let library = LibraryStore(fileURL: folder.appendingPathComponent("library.json"))
        await home.load(isSignedIn: signedIn, library: library)
        #expect(stub.requests.isEmpty)

        // A day on, the saved feed is too old to stand in for one.
        let later = HomeViewModel(service: stub.service, cache: cache, now: now.addingTimeInterval(24 * 60 * 60))
        #expect(later.recommended.isEmpty)
    }
}
