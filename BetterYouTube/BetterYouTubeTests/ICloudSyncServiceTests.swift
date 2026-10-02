import CloudKit
import Foundation
import Testing
@testable import BetterYouTube

@MainActor
struct ICloudSyncServiceTests {
    private struct CacheSnapshot: Codable {
        var schemaVersion = 1
        var entries: [String: CloudSyncEntry] = [:]
        var dirty: Set<String> = []
        var systemFields: [String: Data] = [:]
        var accountID: String?
        var lastSyncDate: Date?
    }

    @MainActor
    private struct Fixture {
        let folder: URL
        let suiteName: String
        let defaults: UserDefaults
        let library: LibraryStore
        let playbackPositions: PlaybackPositionStore
        var positionsURL: URL { folder.appendingPathComponent("playback-positions.json") }
        var libraryURL: URL { folder.appendingPathComponent("library.json") }
        var cacheURL: URL { folder.appendingPathComponent("icloud-sync.json") }

        init() throws {
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("icloud-sync-tests-\(UUID().uuidString)")
            suiteName = "ICloudSyncServiceTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            library = LibraryStore(fileURL: folder.appendingPathComponent("library.json"))
            playbackPositions = PlaybackPositionStore(fileURL: folder.appendingPathComponent("playback-positions.json"))
        }

        func service() -> ICloudSyncService {
            ICloudSyncService(library: library, playbackPositions: playbackPositions, defaults: defaults, fileURL: cacheURL,
                              cloudKitAvailable: { false })
        }

        func cache() throws -> CacheSnapshot {
            try JSONDecoder().decode(CacheSnapshot.self, from: Data(contentsOf: cacheURL))
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func video(_ id: String) -> Video {
        Video(id: id, title: "Video \(id)", channelId: "channel", channelTitle: "Channel",
              description: "Description", thumbnailURL: URL(string: "https://example.com/\(id).jpg"),
              publishedAt: Date(timeIntervalSince1970: 100), viewCount: 123, likeCount: 4,
              duration: "PT2M", categoryId: "22")
    }

    private func entry(_ key: String, video: Video? = nil, value: String? = nil) -> CloudSyncEntry {
        CloudSyncEntry(key: key, modifiedAt: Date(timeIntervalSince1970: 123),
                       changeID: "test-edit", video: video, value: value)
    }

    private func drainPreferenceNotifications() async {
        for _ in 0..<5 { await Task.yield() }
    }

    @Test("An unsigned build keeps the local library and outbox without contacting CloudKit")
    func missingEntitlement() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.toggleFavorite(video("favorite"))
        fixture.library.toggleWatchLater(video("later"))
        fixture.library.recordWatch(video("watched"))
        let entries = fixture.library.syncEntries
        let libraryData = try Data(contentsOf: fixture.libraryURL)
        var entitlementChecks = 0
        let service = ICloudSyncService(library: fixture.library, playbackPositions: fixture.playbackPositions, defaults: fixture.defaults,
                                        fileURL: fixture.cacheURL, cloudKitAvailable: {
            entitlementChecks += 1
            return false
        })

        await service.start()
        await service.syncNow()

        #expect(entitlementChecks > 0)
        #expect(service.isEnabled)
        #expect(!service.isSyncing)
        #expect(service.lastSyncDate == nil)
        #expect(service.statusMessage.contains("signed build"))
        #expect(fixture.library.syncEntries == entries)
        #expect(try Data(contentsOf: fixture.libraryURL) == libraryData)
        let cache = try fixture.cache()
        #expect(cache.entries == entries)
        #expect(cache.dirty == Set(entries.keys))
    }

    @Test("Disabling sync survives relaunch while offline edits remain durable")
    func disabledAndOfflineRelaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = fixture.service()
        service.setEnabled(false)
        fixture.library.toggleFavorite(video("removed"))
        fixture.library.toggleFavorite(video("removed"))
        fixture.library.toggleFavorite(video("retained"))
        fixture.library.toggleWatchLater(video("later"))
        fixture.library.recordWatch(video("watched"))
        let entries = fixture.library.syncEntries
        #expect(fixture.defaults.object(forKey: ICloudSyncService.enabledKey) as? Bool == false)
        #expect(try fixture.cache().entries == entries)
        #expect(try fixture.cache().dirty == Set(entries.keys))

        let relaunchedLibrary = LibraryStore(fileURL: fixture.libraryURL)
        let relaunched = ICloudSyncService(library: relaunchedLibrary, playbackPositions: PlaybackPositionStore(fileURL: fixture.positionsURL), defaults: fixture.defaults,
                                           fileURL: fixture.cacheURL, cloudKitAvailable: { false })
        await relaunched.syncNow()
        #expect(!relaunched.isEnabled)
        #expect(relaunchedLibrary.syncEntries == entries)
        #expect(relaunchedLibrary.favorites.map(\.id) == ["retained"])
        #expect(relaunchedLibrary.watchLater.map(\.id) == ["later"])
        #expect(relaunchedLibrary.history.map(\.id) == ["watched"])

        relaunched.setEnabled(true)
        await relaunched.start()
        #expect(relaunched.isEnabled)
        #expect(fixture.defaults.object(forKey: ICloudSyncService.enabledKey) as? Bool == true)
        #expect(relaunched.lastSyncDate == nil)
        #expect(relaunchedLibrary.syncEntries == entries)
        #expect(try fixture.cache().dirty == Set(entries.keys))
    }

    @Test("Resetting the sync device preserves its library and never contacts the cloud")
    func resetPreservesLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.toggleFavorite(video("cloud-copy"))
        fixture.library.recordWatch(video("watched"))
        let entries = fixture.library.syncEntries
        let libraryData = try Data(contentsOf: fixture.libraryURL)
        var entitlementChecks = 0
        let service = ICloudSyncService(library: fixture.library, playbackPositions: fixture.playbackPositions, defaults: fixture.defaults,
                                        fileURL: fixture.cacheURL, cloudKitAvailable: {
            entitlementChecks += 1
            return false
        })

        await service.resetForDevice()

        #expect(entitlementChecks == 0)
        #expect(!service.isEnabled)
        #expect(!service.isSyncing)
        #expect(service.lastSyncDate == nil)
        #expect(fixture.library.syncEntries == entries)
        #expect(try Data(contentsOf: fixture.libraryURL) == libraryData)
        #expect(!FileManager.default.fileExists(atPath: fixture.cacheURL.path))
        #expect(fixture.defaults.object(forKey: ICloudSyncService.enabledKey) as? Bool == false)
    }

    @Test("A full device reset cannot enqueue library or preference deletions")
    func fullDeviceResetDoesNotPublishDeletions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(MiniPlayerStyle.floatingVideo.rawValue, forKey: MiniPlayerStyle.storageKey)
        fixture.defaults.set(FloatingMiniPlayerSize.large.rawValue, forKey: FloatingMiniPlayerSize.storageKey)
        fixture.library.toggleFavorite(video("cloud-copy"))
        fixture.playbackPositions.record(videoID: "watched", seconds: 30, duration: 600)
        let service = fixture.service()
        #expect(try fixture.cache().entries.count == 4)

        await service.resetForDevice()
        fixture.library.eraseLocalCopy()
        fixture.playbackPositions.eraseLocalCopy()
        fixture.defaults.removeObject(forKey: MiniPlayerStyle.storageKey)
        fixture.defaults.removeObject(forKey: FloatingMiniPlayerSize.storageKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: fixture.defaults)
        await drainPreferenceNotifications()
        service.finishDeviceReset()
        await drainPreferenceNotifications()

        let relaunched = fixture.service()
        #expect(!relaunched.isEnabled)
        #expect(fixture.library.syncEntries.isEmpty)
        #expect(fixture.playbackPositions.syncEntries.isEmpty)
        let cache = try fixture.cache()
        #expect(cache.entries.isEmpty)
        #expect(cache.dirty.isEmpty)
    }

    @Test("Only explicit whitelisted preferences migrate to the cloud outbox")
    func explicitPreferenceMigration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(MiniPlayerStyle.playbackBar.rawValue, forKey: MiniPlayerStyle.storageKey)
        fixture.defaults.set("private-token", forKey: "youtube_api_key")
        fixture.defaults.set("private-path", forKey: "download_folder")
        fixture.defaults.set("private-query", forKey: "recent_searches")
        let service = fixture.service()
        let key = "preference.\(MiniPlayerStyle.storageKey)"
        let cache = try fixture.cache()
        #expect(service.isEnabled)
        #expect(Set(cache.entries.keys) == [key])
        #expect(cache.entries[key]?.value == MiniPlayerStyle.playbackBar.rawValue)
        #expect(cache.entries[key]?.modifiedAt == .distantPast)
        #expect(cache.dirty == [key])
        #expect(fixture.library.syncEntries.isEmpty)
    }

    @Test("A preference saved before a crash becomes a newer pending edit on the next launch")
    func recoversPreferenceBeforeNotification() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let key = "preference.\(MiniPlayerStyle.storageKey)"
        let previous = entry(key, value: MiniPlayerStyle.playbackBar.rawValue)
        var savedCache = CacheSnapshot()
        savedCache.entries = [key: previous]
        try JSONEncoder().encode(savedCache).write(to: fixture.cacheURL)
        // Simulate AppStorage completing its write before the process delivers the notification.
        fixture.defaults.set(MiniPlayerStyle.floatingVideo.rawValue, forKey: MiniPlayerStyle.storageKey)

        let service = fixture.service()
        let cache = try fixture.cache()
        let recovered = try #require(cache.entries[key])
        #expect(service.isEnabled)
        #expect(recovered.value == MiniPlayerStyle.floatingVideo.rawValue)
        #expect(recovered.modifiedAt > previous.modifiedAt)
        #expect(recovered.changeID != previous.changeID)
        #expect(cache.dirty.contains(key))
        #expect(fixture.defaults.string(forKey: MiniPlayerStyle.storageKey) == MiniPlayerStyle.floatingVideo.rawValue)
    }

    @Test("Unsupported cache schemas are preserved while the local library remains editable")
    func unsupportedCacheSchema() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.toggleFavorite(video("local"))
        var futureCache = CacheSnapshot()
        futureCache.schemaVersion = 2
        futureCache.entries = ["favorite.future": entry("favorite.future", video: video("future"))]
        futureCache.dirty = Set(futureCache.entries.keys)
        let originalCache = try JSONEncoder().encode(futureCache)
        try originalCache.write(to: fixture.cacheURL)
        let service = fixture.service()
        service.setEnabled(true)
        await service.start()
        fixture.library.toggleWatchLater(video("offline-edit"))

        #expect(!service.isEnabled)
        #expect(service.statusMessage.contains("Update the app"))
        #expect(fixture.library.favorites.map(\.id) == ["local"])
        #expect(fixture.library.watchLater.map(\.id) == ["offline-edit"])
        #expect(try Data(contentsOf: fixture.cacheURL) == originalCache)
    }

    @Test("A corrupt cache disables sync, preserves a backup and rebuilds a safe local queue")
    func corruptCacheRecovery() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.toggleFavorite(video("removed"))
        fixture.library.toggleFavorite(video("removed"))
        fixture.library.toggleFavorite(video("retained"))
        let corruptData = Data("broken sync cache".utf8)
        try corruptData.write(to: fixture.cacheURL)
        let service = fixture.service()
        #expect(!service.isEnabled)
        #expect(fixture.defaults.object(forKey: ICloudSyncService.enabledKey) as? Bool == false)
        #expect(service.statusMessage.contains("couldn't be read"))
        #expect(fixture.library.favorites.map(\.id) == ["retained"])
        #expect(fixture.library.syncEntries["favorite.removed"] == nil)
        #expect(fixture.library.syncEntries.values.allSatisfy { $0.modifiedAt < Date(timeIntervalSince1970: 0) })
        #expect(try fixture.cache().entries == fixture.library.syncEntries)
        #expect(try fixture.cache().dirty == Set(fixture.library.syncEntries.keys))
        let backups = try FileManager.default.contentsOfDirectory(at: fixture.folder,
                                                                  includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("icloud-sync.json.recovery-") }
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(try Data(contentsOf: backup) == corruptData)
    }

    @Test("Cloud records and their securely archived system fields round-trip all supported values")
    func recordRoundTrip() throws {
        var entries = CloudLibraryList.allCases.flatMap { list in
            [entry(list.key(for: "item"), video: video("item")), entry(list.key(for: "deleted"))]
        }
        entries += MiniPlayerStyle.allCases.map {
            entry("preference.\(MiniPlayerStyle.storageKey)", value: $0.rawValue)
        }
        entries += FloatingMiniPlayerSize.allCases.map {
            entry("preference.\(FloatingMiniPlayerSize.storageKey)", value: $0.rawValue)
        }
        entries += ICloudSyncService.preferenceKeys.map { entry("preference.\($0)") }
        entries += [CloudSyncEntry(key: "playback.item", modifiedAt: Date(timeIntervalSince1970: 123),
                                   changeID: "checkpoint", position: PlaybackPosition(seconds: 30.75, duration: 600)),
                    entry("playback.deleted")]

        for value in entries {
            let record = try ICloudSyncService.record(for: value)
            #expect(record.recordID.recordName == value.key)
            #expect(record.recordID.zoneID == ICloudSyncService.zoneID)
            #expect(ICloudSyncService.entry(from: record) == value)
            let archived = ICloudSyncService.systemFields(of: record)
            #expect(!archived.isEmpty)
            let restored = try ICloudSyncService.record(for: value, systemFields: archived)
            #expect(restored.recordID == record.recordID)
            #expect(restored.recordType == ICloudSyncService.recordType)
            #expect(ICloudSyncService.entry(from: restored) == value)
        }
    }

    @Test("Cached system fields cannot redirect an upload to another record or zone")
    func archivedIdentityValidation() throws {
        let value = entry("favorite.item", video: video("item"))
        let wrongID = CKRecord.ID(recordName: "favorite.other",
                                 zoneID: CKRecordZone.ID(zoneName: "UnrelatedZone"))
        let wrongRecord = CKRecord(recordType: "UnrelatedType", recordID: wrongID)
        let restored = try ICloudSyncService.record(for: value,
                                                     systemFields: ICloudSyncService.systemFields(of: wrongRecord))
        #expect(restored.recordID.recordName == value.key)
        #expect(restored.recordID.zoneID == ICloudSyncService.zoneID)
        #expect(restored.recordType == ICloudSyncService.recordType)
        #expect(ICloudSyncService.entry(from: restored) == value)
    }

    @Test("Corrupt system fields can be recovered through a fresh record upload")
    func corruptSystemFieldsRecovery() throws {
        let value = entry("favorite.item", video: video("item"))
        let record = try ICloudSyncService.record(for: value, systemFields: Data("broken archive".utf8))
        #expect(record.recordID.recordName == value.key)
        #expect(record.recordID.zoneID == ICloudSyncService.zoneID)
        #expect(ICloudSyncService.entry(from: record) == value)
    }

    @Test("Unsupported schemas, mismatched keys and unapproved preference values are rejected")
    func rejectsInvalidRecords() throws {
        let valid = entry("favorite.item", video: video("item"))
        let future = try ICloudSyncService.record(for: valid)
        future["schemaVersion"] = Int64(2)
        #expect(ICloudSyncService.entry(from: future) == nil)
        let mismatched = CKRecord(recordType: ICloudSyncService.recordType,
                                   recordID: CKRecord.ID(recordName: "favorite.other",
                                                        zoneID: ICloudSyncService.zoneID))
        mismatched["schemaVersion"] = Int64(1)
        mismatched["payload"] = try JSONEncoder().encode(valid)
        #expect(ICloudSyncService.entry(from: mismatched) == nil)
        let malformed = try ICloudSyncService.record(for: valid)
        malformed["payload"] = Data("invalid JSON".utf8)
        #expect(ICloudSyncService.entry(from: malformed) == nil)

        let invalidEntries = [
            entry("playback."),
            entry("playback.item", video: video("item")),
            entry("playback.item", value: "unrelated"),
            CloudSyncEntry(key: "playback.item", modifiedAt: Date(), changeID: "invalid",
                           position: PlaybackPosition(seconds: -1, duration: 600)),
            CloudSyncEntry(key: "playback.item", modifiedAt: Date(), changeID: "invalid",
                           position: PlaybackPosition(seconds: 600, duration: 600)),
            CloudSyncEntry(key: "history.item", modifiedAt: Date(), changeID: "invalid", video: video("item"),
                           position: PlaybackPosition(seconds: 30, duration: 600)),
            CloudSyncEntry(key: "preference.\(MiniPlayerStyle.storageKey)", modifiedAt: Date(), changeID: "invalid",
                           position: PlaybackPosition(seconds: 30, duration: 600)),
            entry("favorite."),
            entry("favorite.expected", video: video("other")),
            entry("history.item", video: video("item"), value: "unrelated"),
            entry("unknown.item", video: video("item")),
            entry("preference.youtube_api_key", value: "secret"),
            entry("preference.\(MiniPlayerStyle.storageKey)", value: "unknown-style"),
            entry("preference.\(FloatingMiniPlayerSize.storageKey)", value: "unknown-size"),
            entry("preference.\(MiniPlayerStyle.storageKey)", video: video("item"),
                  value: MiniPlayerStyle.floatingVideo.rawValue)
        ]
        for value in invalidEntries {
            #expect(ICloudSyncService.entry(from: try ICloudSyncService.record(for: value)) == nil)
        }
    }

    @Test("Two devices exchange resume checkpoints, backward seeks and completion through cloud records")
    func syncsPlaybackBetweenDevices() throws {
        let first = try Fixture()
        let second = try Fixture()
        defer { first.cleanup(); second.cleanup() }
        let firstService = first.service()
        let secondService = second.service()
        let now = Date()
        first.playbackPositions.record(videoID: "video", seconds: 120, duration: 600, now: now)
        let original = try #require(first.cache().entries["playback.video"])
        secondService.mergeServerRecord(try ICloudSyncService.record(for: original))
        #expect(second.playbackPositions.position(for: "video")?.seconds == 120)
        #expect(try !second.cache().dirty.contains("playback.video"))

        second.playbackPositions.record(videoID: "video", seconds: 20, duration: 600, now: now.addingTimeInterval(5))
        second.playbackPositions.flush()
        let backward = try #require(second.cache().entries["playback.video"])
        firstService.mergeServerRecord(try ICloudSyncService.record(for: backward))
        #expect(first.playbackPositions.position(for: "video")?.seconds == 20)

        first.playbackPositions.markFinished(videoID: "video")
        let finished = try #require(first.cache().entries["playback.video"])
        secondService.mergeServerRecord(try ICloudSyncService.record(for: finished))
        firstService.mergeServerRecord(try ICloudSyncService.record(for: original))
        #expect(first.playbackPositions.position(for: "video") == nil)
        #expect(second.playbackPositions.position(for: "video") == nil)
        #expect(PlaybackPositionStore(fileURL: second.positionsURL).syncEntries["playback.video"] == finished)
        #expect(try !second.cache().dirty.contains("playback.video"))
    }

    @Test("A fetched checkpoint cannot replace newer unflushed local playback")
    func pendingPlaybackWinsConflict() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = fixture.service()
        let now = Date()
        fixture.playbackPositions.record(videoID: "video", seconds: 10, duration: 600, now: now)
        fixture.playbackPositions.record(videoID: "video", seconds: 20, duration: 600, now: now.addingTimeInterval(2))
        #expect(try fixture.cache().entries["playback.video"]?.position?.seconds == 10)
        let fetched = CloudSyncEntry(key: "playback.video", modifiedAt: now.addingTimeInterval(1),
                                     changeID: "remote", position: PlaybackPosition(seconds: 15, duration: 600))
        service.mergeServerRecord(try ICloudSyncService.record(for: fetched))
        #expect(fixture.playbackPositions.position(for: "video")?.seconds == 20)
        #expect(try fixture.cache().entries["playback.video"]?.position?.seconds == 20)
        #expect(try fixture.cache().dirty.contains("playback.video"))
    }

    @Test("Offline playback stays queued across relaunch and disabled sync ignores cloud records")
    func offlinePlaybackRelaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = fixture.service()
        service.setEnabled(false)
        fixture.playbackPositions.record(videoID: "video", seconds: 40, duration: 600)
        let saved = try #require(fixture.cache().entries["playback.video"])
        let relaunched = fixture.service()
        let newer = CloudSyncEntry(key: saved.key, modifiedAt: saved.modifiedAt.addingTimeInterval(1),
                                   changeID: "remote", position: PlaybackPosition(seconds: 50, duration: 600))
        relaunched.mergeServerRecord(try ICloudSyncService.record(for: newer))
        #expect(!relaunched.isEnabled)
        #expect(fixture.playbackPositions.position(for: "video")?.seconds == 40)
        #expect(try fixture.cache().dirty.contains("playback.video"))
        #expect(PlaybackPositionStore(fileURL: fixture.positionsURL).position(for: "video")?.seconds == 40)
    }
}
