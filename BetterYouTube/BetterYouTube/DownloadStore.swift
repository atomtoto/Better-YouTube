import Foundation

/// Maximum requested picture height. The local engine chooses the best compatible format
/// below it; a configured server is responsible for honoring the same ceiling.
enum DownloadQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "360p"
        case .medium: return "720p"
        case .high: return "1080p"
        }
    }

    /// The tallest picture this quality accepts, in pixels. Sent to the service as a number so a
    /// homemade one can map it onto whatever its own vocabulary is.
    var maxHeight: Int {
        switch self {
        case .low: return 360
        case .medium: return 720
        case .high: return 1080
        }
    }
}

/// Where a download has got to. Persisted, so a queue survives the app being killed mid-way.
enum DownloadState: Codable, Equatable, Sendable {
    /// Waiting for a slot.
    case queued
    /// Resolving media on the device or through the selected server.
    case resolving
    case downloading
    case processing
    /// Stopped by hand, with the bytes so far kept on disk.
    case paused
    /// On disk and playable.
    case ready
    /// Gave up, with something to show the user.
    case failed(String)

    var isActive: Bool {
        switch self {
        case .queued, .resolving, .downloading, .processing: return true
        case .paused, .ready, .failed: return false
        }
    }
}

/// One video in the Downloads folder — what it is, where it got to, and how big it turned out.
///
/// It carries a whole `Video` rather than an id on purpose: the point of a download is that it
/// works with no network, and a row that has to fetch its own title to render is not offline.
/// Everything the app shows about a downloaded video is a copy taken at download time.
struct DownloadRecord: Codable, Equatable, Identifiable, Sendable {
    var video: Video
    var state: DownloadState
    var quality: DownloadQuality
    var addedAt: Date
    var completedAt: Date?
    /// Bytes written so far, and how many the server said to expect — 0 while it hasn't said.
    var receivedBytes: Int64
    var totalBytes: Int64
    /// The media URL the service last handed over.
    ///
    /// Kept only to resume an interrupted transfer. These URLs are short-lived wherever they come
    /// from, so anything that restarts a download asks the service again rather than trusting it.
    var mediaURL: URL?
    var transfer: DownloadTransfer?

    var id: String { video.id }

    init(
        video: Video,
        state: DownloadState = .queued,
        quality: DownloadQuality,
        addedAt: Date = Date(),
        completedAt: Date? = nil,
        receivedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        mediaURL: URL? = nil
    ) {
        self.video = video
        self.state = state
        self.quality = quality
        self.addedAt = addedAt
        self.completedAt = completedAt
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.mediaURL = mediaURL
    }

    /// How far along, 0...1. Zero rather than a guess while the size is unknown — a bar that
    /// jumps backwards once the real total arrives is worse than one that waits.
    var fraction: Double {
        let value = totalBytes > 0 ? min(1, max(0, Double(receivedBytes) / Double(totalBytes))) : 0
        guard let transfer, transfer.audioURL != nil else { return value }
        return transfer.downloadingAudio ? 0.8 + value * 0.15 : value * 0.8
    }

    var isReady: Bool { state == .ready }

    /// What the row says under the title.
    var sizeDescription: String {
        let bytes = state == .ready ? totalBytes : receivedBytes
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The Downloads folder, and the manifest that says what is in it.
///
/// Layout under Documents, which is also what the Files app shows:
///
/// ```
/// Downloads/
///   manifest.json
///   <videoId>/
///     video.mp4      the media itself
///     poster.jpg     the thumbnail, so a row draws with no network
///     resume.dat     a paused transfer's resume data
/// ```
///
/// Paths are never stored — only ids. iOS gives the app container a new UUID on every update, so
/// an absolute URL written to disk today is wrong tomorrow; every path here is rebuilt from the
/// container at the moment it is used.
@MainActor
final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()

    /// Newest first, which is the order the Downloads screen reads in.
    @Published private(set) var records: [DownloadRecord] = []

    /// See `bytesOnDisk()`.
    private var cachedBytes: Int64?

    func invalidateSize() { cachedBytes = nil }

    let paths: DownloadPaths

    init(root: URL = DownloadStore.root) {
        paths = DownloadPaths(root: root)
        prepareFolders()
        load()
        reconcile()
    }

    // MARK: - Where things live

    /// Not main-actor isolated: the background session's delegate needs these paths too, and it
    /// arrives on a queue of its own. `FileManager.default` is safe to ask from anywhere.
    nonisolated static var root: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Where a finished transfer is parked between the delegate callback and the move into place.
    nonisolated static var staging: URL { DownloadPaths(root: root).staging }

    nonisolated static func folder(for videoId: String) -> URL {
        DownloadPaths(root: root).folder(for: videoId)
    }
    nonisolated static func mediaURL(for videoId: String) -> URL {
        DownloadPaths(root: root).mediaURL(for: videoId)
    }
    nonisolated static func posterFileURL(for videoId: String) -> URL {
        DownloadPaths(root: root).posterFileURL(for: videoId)
    }
    nonisolated static func resumeDataURL(for videoId: String) -> URL {
        DownloadPaths(root: root).resumeDataURL(for: videoId)
    }

    private var manifestURL: URL { paths.root.appendingPathComponent("manifest.json") }

    /// Creates the folders and keeps them out of iCloud. Video is the biggest thing this app will
    /// ever write and none of it is worth backing up — it can always be fetched again.
    private func prepareFolders() {
        let manager = FileManager.default
        for folder in [paths.root, paths.staging] {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var directory = paths.root
        try? directory.setResourceValues(resourceValues)
    }

    // MARK: - Reading

    func record(for videoId: String) -> DownloadRecord? {
        records.first { $0.id == videoId }
    }

    func isDownloaded(_ videoId: String) -> Bool {
        record(for: videoId)?.isReady == true
    }

    func state(for videoId: String) -> DownloadState? {
        record(for: videoId)?.state
    }

    /// The file to play, or nil. Both halves matter: the manifest has to call it finished *and*
    /// the file has to actually be there, or a download deleted behind the app's back — from the
    /// Files app, or by iOS reclaiming space — would play as a black screen instead of falling
    /// back to streaming.
    func readyMediaURL(for videoId: String) -> URL? {
        guard isDownloaded(videoId) else { return nil }
        let url = paths.mediaURL(for: videoId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The cached thumbnail, so a downloaded video draws its artwork with no network.
    func posterURL(for videoId: String) -> URL? {
        let url = paths.posterFileURL(for: videoId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Artwork for a video, preferring the copy on disk. What every card and row asks for, so a
    /// downloaded video looks like itself on a plane.
    func artworkURL(for video: Video) -> URL? {
        posterURL(for: video.id) ?? video.thumbnailURL
    }

    var readyRecords: [DownloadRecord] { records.filter(\.isReady) }
    var activeRecords: [DownloadRecord] { records.filter { $0.state.isActive || $0.state == .paused } }

    /// Downloaded videos as plain videos, for the player's queue and the Downloads list.
    var downloadedVideos: [Video] { readyRecords.map(\.video) }

    /// What the whole folder weighs, measured rather than totted up from the manifest — the two
    /// drift whenever a transfer dies halfway, and the number Settings shows should be the one
    /// the phone's storage screen agrees with.
    ///
    /// Cached, because Settings and the Downloads screen both ask for it from a view body. Only
    /// installing or deleting can change it: a transfer in flight writes to the system's own
    /// temporary area and doesn't land here until it finishes, so progress never invalidates it.
    func bytesOnDisk() -> Int64 {
        if let cachedBytes { return cachedBytes }
        let measured = measureBytesOnDisk()
        cachedBytes = measured
        return measured
    }

    private func measureBytesOnDisk() -> Int64 {
        let manager = FileManager.default
        guard let walker = manager.enumerator(
            at: paths.root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    // MARK: - Writing

    /// Inserts or replaces a record, newest first.
    func upsert(_ record: DownloadRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
        persist()
    }

    /// Edits one record in place. A no-op if it has since been deleted, which is what makes it
    /// safe to call from a transfer that outlived the user's patience.
    @discardableResult
    func update(_ videoId: String, _ change: (inout DownloadRecord) -> Void) -> DownloadRecord? {
        guard let index = records.firstIndex(where: { $0.id == videoId }) else { return nil }
        change(&records[index])
        persist()
        return records[index]
    }

    /// Forgets a download and takes its folder with it.
    func remove(_ videoId: String) {
        cachedBytes = nil
        records.removeAll { $0.id == videoId }
        try? FileManager.default.removeItem(at: paths.folder(for: videoId))
        persist()
    }

    func removeAll() {
        cachedBytes = nil
        let manager = FileManager.default
        for record in records {
            try? manager.removeItem(at: paths.folder(for: record.id))
        }
        records.removeAll()
        // Anything the manifest had lost track of goes too, so "remove all" really empties the
        // folder rather than leaving orphans behind to puzzle over in the Files app.
        try? manager.removeItem(at: paths.root)
        prepareFolders()
        persist()
    }

    /// Moves a finished transfer into place and marks the record playable.
    func install(_ videoId: String, from staged: URL, byteCount: Int64) throws {
        let manager = FileManager.default
        let destination = paths.mediaURL(for: videoId)
        try manager.createDirectory(at: paths.folder(for: videoId), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: staged, to: destination)
        try? manager.removeItem(at: paths.resumeDataURL(for: videoId))
        cachedBytes = nil

        update(videoId) { record in
            record.state = .ready
            record.completedAt = Date()
            record.receivedBytes = byteCount
            record.totalBytes = byteCount
            record.mediaURL = nil
            record.transfer = nil
        }
    }

    /// Keeps the thumbnail beside the video so the row draws offline. Best-effort: a download
    /// with no poster is still a download, so nothing here is allowed to fail loudly.
    func cachePoster(for video: Video) async {
        guard let remote = video.thumbnailURL else { return }
        let destination = paths.posterFileURL(for: video.id)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: remote), !data.isEmpty,
              record(for: video.id) != nil else { return }
        try? FileManager.default.createDirectory(
            at: paths.folder(for: video.id),
            withIntermediateDirectories: true
        )
        try? data.write(to: destination, options: .atomic)
        cachedBytes = nil
        // The poster is what the row draws, so a view watching this store has to hear about it.
        objectWillChange.send()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let stored = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return }
        records = stored
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// Squares the manifest with what is actually on disk, at launch.
    ///
    /// Two things can have happened while the app was gone. A record can say `ready` with no file
    /// behind it — iOS reclaims space from Documents under pressure, and the user can delete the
    /// folder from the Files app — and that one becomes a failure the user can retry rather than
    /// a video that plays black. And anything caught mid-transfer is now stopped, whatever the
    /// manifest last managed to write, so it reads as paused and offers to carry on.
    private func reconcile() {
        let manager = FileManager.default
        var changed = false

        for index in records.indices {
            let id = records[index].id
            switch records[index].state {
            case .ready:
                if !manager.fileExists(atPath: paths.mediaURL(for: id).path) {
                    records[index].state = .failed("The file is no longer on this device.")
                    records[index].receivedBytes = 0
                    records[index].completedAt = nil
                    changed = true
                }
            case .queued, .resolving, .downloading, .processing:
                records[index].state = .paused
                changed = true
            case .paused, .failed:
                break
            }
        }

        // A stray staged file belongs to a transfer that was interrupted between landing and
        // being installed; the resume data is what carries that on, not the fragment.
        if let stale = try? manager.contentsOfDirectory(at: paths.staging, includingPropertiesForKeys: nil) {
            for url in stale { try? manager.removeItem(at: url) }
        }

        if changed { persist() }
    }
}

/// Persisted alongside the record so a background video transfer can be followed by audio
/// even after the app has been relaunched. Missing on manifests from older versions.
struct DownloadTransfer: Codable, Equatable, Sendable {
    var audioURL: URL?
    var downloadingAudio: Bool = false
    var wifiOnly: Bool
    var usesByteRanges: Bool? = nil
    var videoByteCount: Int64? = nil
    var audioByteCount: Int64? = nil
    var offset: Int64? = nil

    var currentByteCount: Int64? { downloadingAudio ? audioByteCount : videoByteCount }
}

/// Instances allow isolated stores and queue tests without touching the user's downloads.
struct DownloadPaths: Sendable {
    let root: URL
    var staging: URL { root.appendingPathComponent(".staging", isDirectory: true) }
    func folder(for id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func mediaURL(for id: String) -> URL { folder(for: id).appendingPathComponent("video.mp4") }
    func posterFileURL(for id: String) -> URL { folder(for: id).appendingPathComponent("poster.jpg") }
    func resumeDataURL(for id: String) -> URL { folder(for: id).appendingPathComponent("resume.dat") }
    func componentURL(for id: String, audio: Bool) -> URL {
        folder(for: id).appendingPathComponent(audio ? ".audio-track.m4a" : ".video-track.mp4")
    }
}
