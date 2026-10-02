import Foundation

/// One independently editable value. A missing payload keeps a deletion in the merge history.
struct CloudSyncEntry: Codable, Equatable, Sendable {
    let key: String
    let modifiedAt: Date
    let changeID: String
    let video: Video?
    let value: String?
    let position: PlaybackPosition?

    init(key: String, modifiedAt: Date, changeID: String, video: Video? = nil, value: String? = nil,
         position: PlaybackPosition? = nil) {
        self.key = key
        self.modifiedAt = modifiedAt
        self.changeID = changeID
        self.video = video
        self.value = value
        self.position = position
    }

    /// The later date wins; a lexical change ID breaks simultaneous edits consistently on every
    /// device. A change ID identifies an immutable edit, so receiving it twice changes nothing.
    func isNewer(than other: CloudSyncEntry) -> Bool {
        modifiedAt > other.modifiedAt || (modifiedAt == other.modifiedAt && changeID > other.changeID)
    }

    static func newest(_ lhs: CloudSyncEntry, _ rhs: CloudSyncEntry) -> CloudSyncEntry {
        rhs.isNewer(than: lhs) ? rhs : lhs
    }

    static func merge(_ incoming: [CloudSyncEntry], into existing: [String: CloudSyncEntry]) -> [String: CloudSyncEntry] {
        var result = existing
        for entry in incoming {
            result[entry.key] = result[entry.key].map { newest($0, entry) } ?? entry
        }
        return result
    }

    // Video equality deliberately compares only IDs elsewhere in the app. Sync equality also
    // compares its display metadata, so a remotely refreshed title or thumbnail is persisted.
    static func == (lhs: CloudSyncEntry, rhs: CloudSyncEntry) -> Bool {
        lhs.key == rhs.key && lhs.modifiedAt == rhs.modifiedAt && lhs.changeID == rhs.changeID
            && lhs.value == rhs.value && lhs.position == rhs.position && sameVideo(lhs.video, rhs.video)
    }

    private static func sameVideo(_ lhs: Video?, _ rhs: Video?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left?, right?):
            return left.id == right.id && left.title == right.title
                && left.channelId == right.channelId && left.channelTitle == right.channelTitle
                && left.description == right.description && left.thumbnailURL == right.thumbnailURL
                && left.publishedAt == right.publishedAt && left.viewCount == right.viewCount
                && left.likeCount == right.likeCount && left.duration == right.duration
                && left.categoryId == right.categoryId
        default: return false
        }
    }
}

/// Separate keys keep resume checkpoints from changing the order of watch history.
enum CloudPlaybackPosition {
    static func key(for videoID: String) -> String { "playback.\(videoID)" }

    static func videoID(in key: String) -> String? {
        let prefix = "playback."
        guard key.hasPrefix(prefix), key.count > prefix.count else { return nil }
        return String(key.dropFirst(prefix.count))
    }

    static func isValid(_ entry: CloudSyncEntry) -> Bool {
        videoID(in: entry.key) != nil && entry.video == nil && entry.value == nil
            && (entry.position?.isResumable ?? true)
    }
}

enum CloudLibraryList: String, CaseIterable, Sendable {
    case favorite, watchLater, history

    func key(for videoID: String) -> String { "\(rawValue).\(videoID)" }

    init?(key: String) {
        guard let separator = key.firstIndex(of: "."),
              separator < key.index(before: key.endIndex) else { return nil }
        self.init(rawValue: String(key[..<separator]))
    }

    func videoID(in key: String) -> String? {
        let prefix = rawValue + "."
        guard key.hasPrefix(prefix), key.count > prefix.count else { return nil }
        return String(key.dropFirst(prefix.count))
    }
}
