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
}
