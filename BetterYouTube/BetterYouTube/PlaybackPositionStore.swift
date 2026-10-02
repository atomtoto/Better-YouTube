import Foundation

struct PlaybackPosition: Codable, Equatable, Sendable {
    let seconds: Double
    let duration: Double

    var isResumable: Bool {
        seconds.isFinite && seconds > 0 && duration.isFinite && duration >= 0
            && (duration == 0 || seconds < duration)
    }
}

/// Streaming and downloaded playback share one position per video. Versioned checkpoints
/// remain usable offline and join the library's iCloud outbox when synchronization is enabled.
@MainActor
final class PlaybackPositionStore {
    static let shared = PlaybackPositionStore(fileURL: FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("playback-positions.json"))

    typealias Position = PlaybackPosition

    private struct Snapshot: Codable {
        var syncEntries: [String: CloudSyncEntry]
    }

    private let fileURL: URL
    private var positions: [String: Position] = [:]
    private(set) var syncEntries: [String: CloudSyncEntry] = [:]
    /// Installed by iCloud sync. Receiving a remote checkpoint never echoes it back.
    var onSyncChange: (([CloudSyncEntry]) -> Void)?
    private var changedKeys: Set<String> = []
    private var hasChanges = false
    private var lastSaved = Date.distantPast
    private var lastLocalMutation = Date.distantPast

    init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            syncEntries = snapshot.syncEntries.filter { $0.key == $0.value.key && CloudPlaybackPosition.isValid($0.value) }
            rebuildPositions()
            lastLocalMutation = syncEntries.values.map(\.modifiedAt).max() ?? .distantPast
        } else if let saved = try? JSONDecoder().decode([String: Position].self, from: data) {
            positions = saved.filter { !$0.key.isEmpty && $0.value.isResumable }
            seedLegacyPositions()
            hasChanges = true
            flush()
        }
    }

    func position(for videoID: String) -> Position? { positions[videoID] }

    /// Update in memory on every report, save and enqueue at most every five seconds during
    /// playback. Pauses, seeks and leaving playback flush the latest value immediately.
    func record(videoID: String, seconds: Double, duration: Double, now: Date = Date()) {
        guard !videoID.isEmpty, seconds.isFinite, seconds >= 0,
              duration.isFinite, duration >= 0 else { return }
        let knownDuration = duration > 0 ? duration : positions[videoID]?.duration ?? 0
        let position = Position(seconds: seconds, duration: knownDuration)
        let next = position.isResumable ? position : nil
        if positions[videoID] != next || syncEntries[CloudPlaybackPosition.key(for: videoID)] == nil {
            applyLocal(videoID: videoID, position: next, now: now)
        }
        if now.timeIntervalSince(lastSaved) >= 5 { flush(now: now) }
    }

    func markFinished(videoID: String) {
        guard !videoID.isEmpty else { return }
        // Preserve a deletion even if this device never saved a positive time for the video.
        // An offline device must not bring its older resume point back later.
        applyLocal(videoID: videoID, position: nil, now: Date())
        flush()
    }

    func flush(now: Date = Date()) {
        guard hasChanges || !changedKeys.isEmpty, persist() else { return }
        let changed = changedKeys.sorted().compactMap { syncEntries[$0] }
        changedKeys = []
        hasChanges = false
        lastSaved = now
        if !changed.isEmpty { onSyncChange?(changed) }
    }

    func mergeSyncEntries(_ entries: [CloudSyncEntry]) {
        let merged = CloudSyncEntry.merge(entries.filter(CloudPlaybackPosition.isValid), into: syncEntries)
        guard merged != syncEntries else { return }
        for (key, entry) in merged where syncEntries[key] != entry { changedKeys.remove(key) }
        syncEntries = merged
        lastLocalMutation = max(lastLocalMutation, merged.values.map(\.modifiedAt).max() ?? .distantPast)
        rebuildPositions()
        hasChanges = true
        if persist() { hasChanges = false }
    }

    /// A user-requested clear propagates removals while retaining their versions.
    func clear() {
        for videoID in Array(positions.keys) { applyLocal(videoID: videoID, position: nil, now: Date()) }
        flush()
    }

    /// Reset only this device, after sync is disabled. No tombstones should erase other devices.
    func eraseLocalCopy() {
        positions = [:]
        syncEntries = [:]
        changedKeys = []
        lastLocalMutation = .distantPast
        hasChanges = true
        flush()
    }

    func prepareForNewCloudAccount() {
        syncEntries = [:]
        changedKeys = []
        lastLocalMutation = .distantPast
        seedLegacyPositions()
        hasChanges = true
        if persist() { hasChanges = false }
    }

    private func applyLocal(videoID: String, position: Position?, now: Date) {
        let key = CloudPlaybackPosition.key(for: videoID)
        let previous = syncEntries[key]?.modifiedAt ?? .distantPast
        let date = max(now, max(previous.addingTimeInterval(0.001), lastLocalMutation.addingTimeInterval(0.001)))
        lastLocalMutation = date
        positions[videoID] = position
        syncEntries[key] = CloudSyncEntry(key: key, modifiedAt: date, changeID: UUID().uuidString,
                                         position: position)
        changedKeys.insert(key)
        hasChanges = true
    }

    private func seedLegacyPositions() {
        for (videoID, position) in positions {
            let key = CloudPlaybackPosition.key(for: videoID)
            syncEntries[key] = CloudSyncEntry(key: key, modifiedAt: .distantPast,
                                             changeID: "legacy.\(key)", position: position)
        }
    }

    private func rebuildPositions() {
        positions = Dictionary(uniqueKeysWithValues: syncEntries.values.compactMap { entry in
            guard let videoID = CloudPlaybackPosition.videoID(in: entry.key), let position = entry.position else { return nil }
            return (videoID, position)
        })
    }

    private func persist() -> Bool {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(Snapshot(syncEntries: syncEntries)).write(to: fileURL, options: .atomic)
            return true
        } catch {
            // Keep pending edits in memory and retry on the next checkpoint.
            return false
        }
    }
}
