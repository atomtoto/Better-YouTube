import Foundation
import Testing
@testable import BetterYouTube

@MainActor
struct NotificationStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() -> NotificationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notifications-\(UUID().uuidString).json")
        let store = NotificationStore(fileURL: url)
        store.mode = .all
        return store
    }

    private func video(_ id: String, channel: String = "UC1", age: TimeInterval = 60 * 60 * 24 * 30) -> Video {
        Video(id: id, title: id, channelId: channel, channelTitle: channel, description: "",
              thumbnailURL: nil, publishedAt: now.addingTimeInterval(-age))
    }

    @Test("the first check only records what exists")
    func bootstrapAnnouncesNothing() {
        let store = makeStore()
        #expect(store.ingest([video("a"), video("b")], now: now).isEmpty)
        #expect(store.ingest([video("a"), video("c")], now: now).map(\.id) == ["c"])
    }

    @Test("a video still in a channel's latest uploads is never announced twice")
    func ledgerKeepsRecentlySeenVideos() {
        let store = makeStore()
        _ = store.ingest([video("keep")], now: now)
        // Fill the ledger past its cap, seeing the long-lived video again along the way, the
        // way every check of a quiet channel does.
        for batch in 0..<25 {
            let flood = (0..<100).map { video("v\(batch)-\($0)") }
            _ = store.ingest(flood + [video("keep")], now: now)
        }
        #expect(store.ingest([video("keep")], now: now).isEmpty)
    }

    @Test("a channel read for the first time announces only what it just uploaded")
    func newChannelAnnouncesOnlyFreshUploads() {
        let store = makeStore()
        _ = store.ingest([video("old", channel: "UC1")], now: now)

        let backCatalogue = video("archive", channel: "UC2", age: 60 * 60 * 24 * 10)
        let justUploaded = video("fresh", channel: "UC2", age: 60 * 60)
        let announced = store.ingest([backCatalogue, justUploaded], now: now)
        #expect(announced.map(\.id) == ["fresh"])

        // From then on the channel is known, and anything new from it is news.
        let next = video("later", channel: "UC2", age: 60 * 60 * 24 * 3)
        #expect(store.ingest([next], now: now).map(\.id) == ["later"])
    }

    @Test("selected channels are checked, not the start of the alphabet")
    func checksTheChannelsNotificationsAreOnFor() {
        let store = makeStore()
        store.mode = .selected
        store.toggleOptIn("UCzebra")
        store.toggleOptIn("UCapple")
        #expect(store.channelsToCheck(subscriptions: ["UCa", "UCb"]) == ["UCapple", "UCzebra"])

        store.mode = .all
        #expect(store.channelsToCheck(subscriptions: ["UCa", "UCzebra", "UCb"])
            == ["UCapple", "UCzebra", "UCa", "UCb"])

        store.mode = .off
        #expect(store.channelsToCheck(subscriptions: ["UCa"]).isEmpty)
    }

    @Test("the ledger survives a relaunch in order")
    func ledgerPersists() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notifications-\(UUID().uuidString).json")
        let first = NotificationStore(fileURL: url)
        first.mode = .all
        _ = first.ingest([video("a"), video("b")], now: now)

        let relaunched = NotificationStore(fileURL: url)
        #expect(relaunched.mode == .all)
        #expect(relaunched.ingest([video("a"), video("b"), video("c")], now: now).map(\.id) == ["c"])
    }
}
