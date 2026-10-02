import AVFoundation
import Foundation
import Testing
@testable import BetterYouTube

@MainActor
struct PlaybackPositionTests {
    private func fileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("positions.json")
    }

    @Test("Resume points survive relaunch and stay separate for each video")
    func roundTrip() {
        let url = fileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PlaybackPositionStore(fileURL: url)
        store.record(videoID: "first", seconds: 123.75, duration: 600)
        store.record(videoID: "second", seconds: 42, duration: 300)
        store.flush()
        let reopened = PlaybackPositionStore(fileURL: url)
        #expect(reopened.position(for: "first")?.seconds == 123.75)
        #expect(reopened.position(for: "first")?.duration == 600)
        #expect(reopened.position(for: "second")?.seconds == 42)
        #expect(reopened.position(for: "new") == nil)
    }

    @Test("Checkpoints are throttled but flushing saves the exact latest position")
    func checkpoints() {
        let url = fileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PlaybackPositionStore(fileURL: url)
        let now = Date()
        store.record(videoID: "video", seconds: 10, duration: 600, now: now)
        store.record(videoID: "video", seconds: 12.25, duration: 600, now: now.addingTimeInterval(2))
        #expect(PlaybackPositionStore(fileURL: url).position(for: "video")?.seconds == 10)
        store.flush(now: now.addingTimeInterval(2))
        #expect(PlaybackPositionStore(fileURL: url).position(for: "video")?.seconds == 12.25)
        store.record(videoID: "video", seconds: 17.25, duration: 600, now: now.addingTimeInterval(7))
        #expect(PlaybackPositionStore(fileURL: url).position(for: "video")?.seconds == 17.25)
    }

    @Test("Backward seeks replace the position and replaying completed videos starts at zero")
    func seeksAndCompletion() {
        let url = fileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PlaybackPositionStore(fileURL: url)
        store.record(videoID: "video", seconds: 200, duration: 600)
        store.record(videoID: "video", seconds: 30, duration: 0)
        #expect(store.position(for: "video")?.seconds == 30)
        #expect(store.position(for: "video")?.duration == 600)
        store.markFinished(videoID: "video")
        #expect(PlaybackPositionStore(fileURL: url).position(for: "video") == nil)
        store.record(videoID: "video", seconds: 5, duration: 600)
        store.record(videoID: "video", seconds: 0, duration: 600)
        store.flush()
        #expect(PlaybackPositionStore(fileURL: url).position(for: "video") == nil)
        store.record(videoID: "video", seconds: 600, duration: 600)
        #expect(store.position(for: "video") == nil)
    }

    @Test("Invalid reports preserve the checkpoint and reset removes every saved position")
    func invalidReportsAndReset() throws {
        let url = fileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PlaybackPositionStore(fileURL: url)
        store.record(videoID: "video", seconds: 50, duration: 600)
        for seconds in [Double.nan, Double.infinity, -1] {
            store.record(videoID: "video", seconds: seconds, duration: 600)
        }
        store.record(videoID: "video", seconds: 20, duration: .infinity)
        #expect(store.position(for: "video")?.seconds == 50)
        store.clear()
        #expect(PlaybackPositionStore(fileURL: url).position(for: "video") == nil)
        try Data("broken JSON".utf8).write(to: url)
        #expect(PlaybackPositionStore(fileURL: url).position(for: "video") == nil)
    }

    @Test("A downloaded file seeks before reporting its first saved position")
    func downloadedPlaybackResume() async throws {
        let bundle = Bundle(for: FixtureBundleMarker.self)
        let media = try #require(bundle.url(forResource: "video", withExtension: "mp4", subdirectory: "Fixtures"))
        let playback = LocalPlayback()
        defer { playback.stop() }
        var reports: [Double] = []
        playback.onProgress = { time, _ in reports.append(time) }
        playback.load(url: media)
        playback.seek(to: 0.6)
        for _ in 0..<100 {
            if !reports.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let first = try #require(reports.first)
        #expect(abs(first - 0.6) < 0.02)
        #expect(abs(playback.player.currentTime().seconds - 0.6) < 0.02)

        // A second seek wins over any reports or completion from the first one.
        reports = []
        playback.seek(to: 0.8)
        playback.seek(to: 0.2)
        for _ in 0..<100 {
            if !reports.isEmpty { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(abs(try #require(reports.first) - 0.2) < 0.02)
    }

    @Test("Legacy local checkpoints migrate without defeating newer cloud removals")
    func migratesLocalPositions() throws {
        let url = fileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(["video": PlaybackPosition(seconds: 30, duration: 600)]).write(to: url)
        let store = PlaybackPositionStore(fileURL: url)
        #expect(store.position(for: "video")?.seconds == 30)
        #expect(store.syncEntries["playback.video"]?.modifiedAt == .distantPast)
        store.mergeSyncEntries([CloudSyncEntry(key: "playback.video", modifiedAt: Date(timeIntervalSince1970: 100),
                                               changeID: "cloud-removal")])
        #expect(store.position(for: "video") == nil)
        let reopened = PlaybackPositionStore(fileURL: url)
        #expect(reopened.position(for: "video") == nil)
        #expect(reopened.syncEntries["playback.video"]?.changeID == "cloud-removal")
    }

    @Test("Newer backward seeks win and simultaneous edits converge without upload echoes")
    func mergesPositions() throws {
        let url = fileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PlaybackPositionStore(fileURL: url)
        let old = CloudSyncEntry(key: "playback.video", modifiedAt: Date(timeIntervalSince1970: 100),
                                 changeID: "old", position: PlaybackPosition(seconds: 200, duration: 600))
        let newer = CloudSyncEntry(key: "playback.video", modifiedAt: Date(timeIntervalSince1970: 200),
                                   changeID: "a", position: PlaybackPosition(seconds: 30, duration: 600))
        let simultaneous = CloudSyncEntry(key: "playback.video", modifiedAt: newer.modifiedAt,
                                          changeID: "z", position: PlaybackPosition(seconds: 40, duration: 600))
        var echoed: [CloudSyncEntry] = []
        store.onSyncChange = { echoed += $0 }
        store.mergeSyncEntries([old, newer, simultaneous])
        store.mergeSyncEntries([simultaneous, newer, old])
        #expect(store.position(for: "video")?.seconds == 40)
        #expect(echoed.isEmpty)
        #expect(PlaybackPositionStore(fileURL: url).syncEntries["playback.video"] == simultaneous)

        // A device whose clock is behind still produces a newer version after a remote edit.
        store.record(videoID: "video", seconds: 10, duration: 600, now: Date(timeIntervalSince1970: 50))
        store.flush()
        #expect(store.syncEntries["playback.video"]!.isNewer(than: simultaneous))
        #expect(echoed.last?.position?.seconds == 10)
    }

    @Test("Completion and clearing retain tombstones, while a device reset removes only its copy")
    func deletionVersionsAndDeviceReset() {
        let url = fileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PlaybackPositionStore(fileURL: url)
        store.record(videoID: "video", seconds: 30, duration: 600)
        let old = store.syncEntries["playback.video"]!
        store.markFinished(videoID: "video")
        store.mergeSyncEntries([old])
        #expect(store.position(for: "video") == nil)
        #expect(store.syncEntries["playback.video"]?.position == nil)
        #expect(store.syncEntries["playback.video"]!.isNewer(than: old))
        store.markFinished(videoID: "never-saved")
        #expect(store.syncEntries["playback.never-saved"] != nil)
        store.record(videoID: "other", seconds: 20, duration: 600)
        store.clear()
        #expect(store.syncEntries["playback.other"]?.position == nil)
        store.eraseLocalCopy()
        #expect(PlaybackPositionStore(fileURL: url).syncEntries.isEmpty)
        store.mergeSyncEntries([old])
        #expect(store.position(for: "video")?.seconds == 30)
    }

    @Test("Changing cloud accounts carries visible positions without the old account's tombstones")
    func accountMigration() {
        let url = fileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = PlaybackPositionStore(fileURL: url)
        store.record(videoID: "kept", seconds: 20, duration: 600)
        store.markFinished(videoID: "removed")
        store.prepareForNewCloudAccount()
        #expect(store.position(for: "kept")?.seconds == 20)
        #expect(store.syncEntries["playback.kept"]?.modifiedAt == .distantPast)
        #expect(store.syncEntries["playback.removed"] == nil)
        #expect(PlaybackPositionStore(fileURL: url).syncEntries == store.syncEntries)
    }
}

private final class FixtureBundleMarker: NSObject {}
