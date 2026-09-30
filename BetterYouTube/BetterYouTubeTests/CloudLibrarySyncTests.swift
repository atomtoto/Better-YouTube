import Foundation
import Testing
@testable import BetterYouTube

@MainActor
struct CloudLibrarySyncTests {
    private func video(_ id: String, title: String? = nil) -> Video {
        Video(id: id, title: title ?? "Video \(id)", channelId: "channel", channelTitle: "Channel",
              description: "Description", thumbnailURL: nil, publishedAt: nil, duration: "PT2M")
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cloud-library-\(UUID().uuidString)")
            .appendingPathComponent("library.json")
    }

    private func entry(_ id: String, list: CloudLibraryList = .favorite, at seconds: TimeInterval,
                       changeID: String = UUID().uuidString, deleted: Bool = false) -> CloudSyncEntry {
        CloudSyncEntry(key: list.key(for: id), modifiedAt: Date(timeIntervalSince1970: seconds),
                       changeID: changeID, video: deleted ? nil : video(id))
    }

    @Test("Independent additions merge into the same library on both devices")
    func independentAdditions() {
        let firstURL = temporaryURL()
        let secondURL = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }
        let first = LibraryStore(fileURL: firstURL)
        let second = LibraryStore(fileURL: secondURL)
        first.toggleFavorite(video("first"))
        second.toggleFavorite(video("second"))
        first.mergeSyncEntries(Array(second.syncEntries.values))
        second.mergeSyncEntries(Array(first.syncEntries.values))
        #expect(Set(first.favorites.map(\.id)) == ["first", "second"])
        #expect(first.syncEntries == second.syncEntries)
        #expect(first.favorites.map(\.id) == second.favorites.map(\.id))
    }

    @Test("Deletion survives a stale device; an explicit later add restores the item")
    func deletionAndReaddition() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LibraryStore(fileURL: url)
        store.toggleFavorite(video("item"))
        let stale = Array(store.syncEntries.values)
        store.toggleFavorite(video("item"))
        let deletion = try #require(store.syncEntries["favorite.item"])
        #expect(deletion.video == nil)
        store.mergeSyncEntries(stale)
        #expect(store.favorites.isEmpty)
        store.toggleFavorite(video("item"))
        let readdition = try #require(store.syncEntries["favorite.item"])
        #expect(readdition.modifiedAt > deletion.modifiedAt)
        store.mergeSyncEntries([deletion])
        #expect(store.favorites.map(\.id) == ["item"])
    }

    @Test("Simultaneous edits converge using the change ID, independent of arrival order")
    func simultaneousEdits() {
        let saved = entry("item", at: 100, changeID: "A")
        let deleted = entry("item", at: 100, changeID: "B", deleted: true)
        #expect(CloudSyncEntry.merge([saved, deleted], into: [:])
            == CloudSyncEntry.merge([deleted, saved], into: [:]))
        #expect(CloudSyncEntry.newest(saved, deleted) == deleted)
        #expect(CloudSyncEntry.newest(deleted, saved) == deleted)
    }

    @Test("Video metadata participates in sync equality")
    func videoMetadata() {
        let date = Date(timeIntervalSince1970: 100)
        let first = CloudSyncEntry(key: "favorite.item", modifiedAt: date, changeID: "A",
                                   video: video("item", title: "Original"))
        let changedPayload = CloudSyncEntry(key: "favorite.item", modifiedAt: date, changeID: "A",
                                            video: video("item", title: "Updated"))
        #expect(first != changedPayload)
        let updated = CloudSyncEntry(key: first.key, modifiedAt: date, changeID: "B",
                                     video: video("item", title: "Updated"))
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LibraryStore(fileURL: url)
        store.mergeSyncEntries([first, updated])
        #expect(store.favorites.first?.title == "Updated")
        #expect(LibraryStore(fileURL: url).favorites.first?.title == "Updated")
    }

    @Test("History keeps the latest 200 visible and clears retained older items too")
    func historyOrderingAndClear() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LibraryStore(fileURL: url)
        let remote = (0..<205).map { entry("h\($0)", list: .history, at: TimeInterval($0)) }
        store.mergeSyncEntries(remote)
        #expect(store.history.count == 200)
        #expect(store.history.first?.id == "h204")
        #expect(store.history.last?.id == "h5")
        #expect(store.syncEntries.count == 205)
        store.recordWatch(video("h0"))
        #expect(store.history.first?.id == "h0")
        #expect(store.history.count == 200)
        store.clearHistory()
        #expect(store.history.isEmpty)
        #expect(store.syncEntries.values.allSatisfy { $0.video == nil })
        store.mergeSyncEntries(remote)
        #expect(store.history.isEmpty)
        #expect(LibraryStore(fileURL: url).history.isEmpty)
    }

    @Test("Clearing known history preserves a concurrent watch from another device")
    func clearHistoryAndConcurrentWatch() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LibraryStore(fileURL: url)
        store.mergeSyncEntries([entry("old", list: .history, at: 100)])
        store.clearHistory()
        store.mergeSyncEntries([entry("other-device", list: .history, at: 200)])
        #expect(store.history.map(\.id) == ["other-device"])
    }

    @Test("Legacy arrays preserve their order and never override a remote deletion on migration")
    func migrationAndRelaunch() throws {
        struct LegacySnapshot: Encodable {
            let favorites: [Video]
            let watchLater: [Video]
            let history: [Video]
        }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = LegacySnapshot(favorites: [video("newer"), video("older")],
                                    watchLater: [video("wl2"), video("wl1")],
                                    history: [video("h2"), video("h1")])
        try JSONEncoder().encode(legacy).write(to: url)
        let store = LibraryStore(fileURL: url)
        #expect(store.favorites.map(\.id) == ["newer", "older"])
        #expect(store.watchLater.map(\.id) == ["wl2", "wl1"])
        #expect(store.history.map(\.id) == ["h2", "h1"])
        #expect(store.syncEntries.values.allSatisfy { $0.modifiedAt < Date(timeIntervalSince1970: 0) })
        let deletion = entry("newer", at: 100, deleted: true)
        store.mergeSyncEntries([deletion])
        let restored = LibraryStore(fileURL: url)
        #expect(restored.syncEntries == store.syncEntries)
        #expect(restored.favorites.map(\.id) == ["older"])
        #expect(restored.syncEntries["favorite.newer"]?.video == nil)
    }

    @Test("Local batches call sync once; remote changes and repeated merges never echo")
    func callbacksAndIdempotence() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LibraryStore(fileURL: url)
        var batches: [[CloudSyncEntry]] = []
        store.onSyncChange = { batches.append($0) }
        store.addToWatchLater([video("first"), video("second"), video("first")])
        #expect(store.watchLater.map(\.id) == ["first", "second"])
        #expect(batches.count == 1)
        #expect(batches.first?.count == 2)
        store.addToWatchLater([video("first")])
        #expect(batches.count == 1)
        store.mergeSyncEntries([entry("remote", at: 100)])
        #expect(batches.count == 1)
        let before = try Data(contentsOf: url)
        let snapshot = store.syncEntries
        store.mergeSyncEntries(Array(snapshot.values))
        #expect(store.syncEntries == snapshot)
        #expect(try Data(contentsOf: url) == before)
        #expect(batches.count == 1)
        store.removeWatchLater(at: IndexSet([0, 1]))
        #expect(batches.count == 2)
        #expect(batches.last?.count == 2)
        #expect(batches.last?.allSatisfy { $0.video == nil } == true)
    }

    @Test("Future device clocks cannot prevent a later local removal")
    func monotonicLocalClock() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LibraryStore(fileURL: url)
        let future = entry("item", at: Date().addingTimeInterval(86_400).timeIntervalSince1970)
        store.mergeSyncEntries([future])
        store.recordWatch(video("recent-watch"))
        let watched = try #require(store.syncEntries["history.recent-watch"])
        #expect(watched.modifiedAt > future.modifiedAt)
        store.toggleFavorite(video("item"))
        let removal = try #require(store.syncEntries[future.key])
        #expect(removal.modifiedAt > future.modifiedAt)
        #expect(removal.video == nil)
    }

    @Test("A device reset keeps no tombstones to delete the cloud copy when re-enabled")
    func localReset() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LibraryStore(fileURL: url)
        store.toggleFavorite(video("cloud-copy"))
        let cloud = Array(store.syncEntries.values)
        var calls = 0
        store.onSyncChange = { _ in calls += 1 }
        store.eraseLocalCopy()
        #expect(calls == 0)
        #expect(store.syncEntries.isEmpty)
        #expect(store.favorites.isEmpty)
        let relaunched = LibraryStore(fileURL: url)
        relaunched.mergeSyncEntries(cloud)
        #expect(relaunched.favorites.map(\.id) == ["cloud-copy"])
    }

    @Test("Switching Apple accounts copies active items without old deletion history")
    func newCloudAccount() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LibraryStore(fileURL: url)
        store.toggleFavorite(video("deleted-in-old-account"))
        store.toggleFavorite(video("deleted-in-old-account"))
        store.toggleFavorite(video("kept-first"))
        store.toggleFavorite(video("kept-second"))
        store.addToWatchLater([video("wl-first"), video("wl-second")])
        store.recordWatch(video("watched"))
        var callbacks = 0
        store.onSyncChange = { _ in callbacks += 1 }
        store.prepareForNewCloudAccount()
        #expect(callbacks == 0)
        #expect(store.favorites.map(\.id) == ["kept-second", "kept-first"])
        #expect(store.watchLater.map(\.id) == ["wl-first", "wl-second"])
        #expect(store.history.map(\.id) == ["watched"])
        #expect(store.syncEntries["favorite.deleted-in-old-account"] == nil)
        #expect(store.syncEntries.values.allSatisfy {
            $0.video != nil && $0.modifiedAt < Date(timeIntervalSince1970: 0)
        })
        store.mergeSyncEntries([
            entry("deleted-in-old-account", at: 100),
            entry("kept-first", at: 200, deleted: true)
        ])
        #expect(Set(store.favorites.map(\.id)) == ["deleted-in-old-account", "kept-second"])
        #expect(LibraryStore(fileURL: url).syncEntries == store.syncEntries)
    }

    @Test("Settings keys and malformed library entries do not enter the library")
    func ignoresUnrelatedEntries() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LibraryStore(fileURL: url)
        store.mergeSyncEntries([
            CloudSyncEntry(key: "setting.player", modifiedAt: .now, changeID: "A", value: "floating"),
            CloudSyncEntry(key: "favorite.", modifiedAt: .now, changeID: "B"),
            CloudSyncEntry(key: "favorite.expected", modifiedAt: .now, changeID: "C", video: video("other")),
            CloudSyncEntry(key: "history.item", modifiedAt: .now, changeID: "D", value: "unrelated")
        ])
        #expect(store.syncEntries.isEmpty)
        #expect(store.favorites.isEmpty)
        #expect(store.history.isEmpty)
    }
}
