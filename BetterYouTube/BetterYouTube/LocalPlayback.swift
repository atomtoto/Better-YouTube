import AVFoundation
import AVKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// Plays a downloaded file.
///
/// The app has two players, and which one runs is decided per video rather than per screen: a
/// video with a file in the Downloads folder plays through this, and everything else through
/// YouTube's embed. `PlayerManager` owns both and presents one face to the rest of the app, so
/// nothing above it — the mini bar, the lock screen, the up-next queue — knows or cares which is
/// playing. That is what makes a downloaded video playable from wherever it happens to be listed.
///
/// This one reports the same things the embed's JavaScript bridge does: position, duration,
/// whether it is playing, whether it is stalled, and the audio and caption tracks there are to
/// choose from — so `PlayerManager` can treat them alike, and the same controls drive both.
@MainActor
final class LocalPlayback {
    let player = AVPlayer()
    #if os(iOS)
    /// Installed by the inline AVPlayerViewController. Rotation requests are queued until the
    /// surface exists, which also covers launching a downloaded video while already landscape.
    var onFullScreenRequest: ((Bool) -> Void)? {
        didSet { onFullScreenRequest?(wantsFullScreen) }
    }
    var onFullScreenChanged: ((Bool) -> Void)?
    private(set) var wantsFullScreen = false

    func setFullScreen(_ active: Bool) {
        wantsFullScreen = active
        onFullScreenRequest?(active)
    }
    #endif
    /// Position and duration, in seconds.
    var onProgress: ((Double, Double) -> Void)?
    /// Playing, as opposed to paused or stalled.
    var onPlayingChanged: ((Bool) -> Void)?
    /// Waiting on the disk or a decode, which the bar shows as a spinner.
    var onBufferingChanged: ((Bool) -> Void)?
    /// Reached the end, which is what advances the queue.
    var onEnded: (() -> Void)?
    /// The file wouldn't play, with something to say about it.
    var onFailure: ((String) -> Void)?
    /// The file's audio and caption tracks, and which of each is selected.
    var onMediaOptions: (([PlaybackChoice], String?, [PlaybackChoice], String?) -> Void)?
    /// Installed by the surface, which owns the Picture in Picture controller. Answers whether
    /// Picture in Picture could start.
    var onPictureInPictureRequest: (() -> Bool)?
    /// Set by the surface while the video is in its Picture in Picture window, where it goes on
    /// playing with the app in the background whatever Settings say about the sound alone.
    var isInPictureInPicture = false

    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    /// Feeds a YouTube stream to the player — see `RangedStreamLoader` and
    /// `PlaylistStreamLoader`. Kept here because the asset only holds its delegate weakly.
    private var streamLoader: NSObject?

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var currentURL: URL?
    private var pendingSeek: Double?
    private var seekGeneration = 0
    private var isSeeking = false

    init() {
        // The app's own transport and the lock screen drive playback; nothing should autoplay the
        // next thing behind their back.
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        #if os(iOS)
        // CarPlay owns the parked-video display and its driving restrictions through AirPlay.
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif

        // Reported four times a second: often enough that the scrubber tracks smoothly, rarely
        // enough that it isn't redrawing the player on every frame.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.reportProgress(at: time)
            }
        }

        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                self.onPlayingChanged?(player.timeControlStatus == .playing)
                self.onBufferingChanged?(player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
            }
        }
    }

    // Isolated, so it runs on the main actor with the observers it removes.
    isolated deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: - Transport

    /// Points the player at a file. Re-loading the file already playing is a no-op, so replaying a
    /// video from a list doesn't restart what is already on screen.
    /// `ranged` is for a stream the player fetches itself; a stream handed to an AirPlay
    /// receiver — CarPlay's video — has to stay a plain URL the receiver can fetch. With the
    /// stream's `index`, the player is handed it as a playlist of its pieces instead, and starts
    /// anywhere in it at once.
    func load(url: URL, ranged: Bool = true, index: StreamIndex? = nil) {
        guard currentURL != url else { return }
        currentURL = url
        pendingSeek = nil
        seekGeneration += 1
        isSeeking = false

        let item: AVPlayerItem
        let isPlaylist = index?.url == url
        // A playlist only starts once the player may wait for its first piece: told to play at
        // once, it stood at zero speed for good.
        player.automaticallyWaitsToMinimizeStalling = isPlaylist
        if let index, isPlaylist {
            let loader = PlaylistStreamLoader(index: index)
            streamLoader = loader
            item = AVPlayerItem(asset: loader.asset)
        } else if !url.isFileURL, ranged, let loader = RangedStreamLoader(url: url) {
            streamLoader = loader
            item = AVPlayerItem(asset: loader.asset)
        } else {
            streamLoader = nil
            item = AVPlayerItem(url: url)
        }
        audibleGroup = nil
        legibleGroup = nil
        observe(item)
        player.replaceCurrentItem(with: item)
    }

    func play() {
        // Play at the end of the file starts it over, as the embed's replay does.
        if let item = player.currentItem, item.duration.isNumeric,
           player.currentTime().seconds >= item.duration.seconds - 0.5 {
            seek(to: 0)
        }
        player.play()
        onPlayingChanged?(true)
    }

    /// The speed playback runs at, now and whenever it is next started.
    func setRate(_ rate: Double) {
        player.defaultRate = Float(rate)
        if player.rate != 0 { player.rate = Float(rate) }
    }

    func startPictureInPicture() -> Bool {
        onPictureInPictureRequest?() ?? false
    }

    // MARK: - Tracks

    func selectAudioTrack(_ id: String) {
        guard let group = audibleGroup, let index = Int(id), group.options.indices.contains(index) else { return }
        player.currentItem?.select(group.options[index], in: group)
        reportMediaOptions()
    }

    /// A caption track by its index, or nil for none.
    func selectCaption(_ id: String?) {
        guard let group = legibleGroup else { return }
        let option = id.flatMap(Int.init).flatMap { group.options.indices.contains($0) ? group.options[$0] : nil }
        player.currentItem?.select(option, in: group)
        reportMediaOptions()
    }

    private func loadMediaOptions(for item: AVPlayerItem) {
        Task { [weak self] in
            let asset = item.asset
            let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
            let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self, self.player.currentItem === item else { return }
            self.audibleGroup = audible ?? nil
            self.legibleGroup = legible ?? nil
            self.reportMediaOptions()
        }
    }

    private func reportMediaOptions() {
        guard let item = player.currentItem else { return }
        let selection = item.currentMediaSelection
        func choices(in group: AVMediaSelectionGroup?) -> ([PlaybackChoice], String?) {
            guard let group else { return ([], nil) }
            let choices = group.options.enumerated().map {
                PlaybackChoice(id: String($0.offset), title: $0.element.displayName)
            }
            let selected = selection.selectedMediaOption(in: group)
                .flatMap { group.options.firstIndex(of: $0) }
                .map(String.init)
            return (choices, selected)
        }
        let audio = choices(in: audibleGroup)
        let captions = choices(in: legibleGroup)
        // One audio track is no choice at all, and the menu leaves it out.
        onMediaOptions?(audio.0.count > 1 ? audio.0 : [], audio.1, captions.0, captions.1)
    }

    func pause() {
        player.pause()
        onPlayingChanged?(false)
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        guard player.currentItem?.status == .readyToPlay else {
            pendingSeek = max(0, seconds)
            return
        }
        let item = player.currentItem
        seekGeneration += 1
        let generation = seekGeneration
        isSeeking = true
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // Exact, because this is also what the lock screen's scrubber and a 15-second skip land
        // on, and snapping to the nearest keyframe makes both feel like they missed.
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.player.currentItem === item,
                      self.seekGeneration == generation else { return }
                self.isSeeking = false
                if finished { self.reportProgress(at: self.player.currentTime()) }
            }
        }
    }

    /// Stops and lets go of the file — called when the player closes, or when a video that isn't
    /// downloaded takes over and the embed becomes the one playing.
    func stop() {
        #if os(iOS)
        setFullScreen(false)
        #endif
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentURL = nil
        pendingSeek = nil
        seekGeneration += 1
        isSeeking = false
        audibleGroup = nil
        legibleGroup = nil
        streamLoader = nil
        itemStatusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    var isPlaying: Bool { player.timeControlStatus == .playing }

    // MARK: - Watching the item

    private func observe(_ item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, self.player.currentItem === item else { return }
                self.onEnded?()
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    if let seconds = self.pendingSeek {
                        self.pendingSeek = nil
                        self.seek(to: seconds)
                    }
                    self.reportProgress(at: self.player.currentTime())
                    if self.audibleGroup == nil, self.legibleGroup == nil {
                        self.loadMediaOptions(for: item)
                    }
                case .failed:
                    let reason = item.error?.localizedDescription
                        ?? String(localized: "The downloaded file couldn't be played.")
                    self.onFailure?(reason)
                default:
                    break
                }
            }
        }
    }

    private func reportProgress(at time: CMTime) {
        guard player.currentItem != nil, pendingSeek == nil, !isSeeking else { return }
        let elapsed = time.seconds.isFinite ? time.seconds : 0
        let total = player.currentItem?.duration.seconds ?? 0
        onProgress?(elapsed, total.isFinite ? total : 0)
    }
}

/// Feeds a YouTube stream to AVPlayer in bounded byte ranges.
///
/// YouTube serves a bounded range — `bytes=0-2097151` — at full speed, but throttles the
/// open-ended requests AVPlayer makes on its own to about 30 KB/s. That is a crawl even for
/// sound alone, and playback never got going. So the player is given the stream under a scheme
/// of the app's own, and this asks YouTube for it one bounded piece at a time, which is also how
/// downloads fetch it.
final class RangedStreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "betteryoutube-stream"
    /// Small enough to answer quickly, big enough that a song is a handful of requests.
    private static let pieceSize: Int64 = 2 * 1024 * 1024

    let asset: AVURLAsset
    private let remoteURL: URL
    /// Everything below runs on this queue: AVFoundation calls the delegate there, and the
    /// session reports there too.
    private let queue = DispatchQueue(label: "com.atomtoto.BetterYouTube.ranged-stream")
    private let session: URLSession
    private var contentLength: Int64?
    private var contentType: String?
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    init?(url: URL) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https" else { return nil }
        components.scheme = Self.scheme
        guard let streamURL = components.url else { return nil }
        remoteURL = url
        asset = AVURLAsset(url: streamURL)
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .default, delegate: nil, delegateQueue: delegateQueue)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let start: Int64
        var end: Int64?
        if let data = loadingRequest.dataRequest {
            start = data.currentOffset != 0 ? data.currentOffset : data.requestedOffset
            if !data.requestsAllDataToEndOfResource {
                end = data.requestedOffset + Int64(data.requestedLength) - 1
            }
        } else {
            start = 0
            end = 1
        }
        fetch(Request(loadingRequest), from: start, through: end)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    /// One piece, then the next, until the player has what it asked for — or the whole stream,
    /// when it asked for everything to the end.
    private func fetch(_ request: Request, from offset: Int64, through end: Int64?) {
        var last = offset + Self.pieceSize - 1
        if let end { last = min(last, end) }
        if let contentLength { last = min(last, contentLength - 1) }
        var urlRequest = URLRequest(url: remoteURL)
        urlRequest.setValue("bytes=\(offset)-\(last)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: urlRequest) { [weak self] data, response, error in
            self?.receive(request, offset: offset, end: end, data: data, response: response, error: error)
        }
        tasks[request.id] = task
        task.resume()
    }

    private func receive(_ request: Request, offset: Int64, end: Int64?,
                         data: Data?, response: URLResponse?, error: Error?) {
        let loading = request.loading
        guard !loading.isCancelled, !loading.isFinished else { return }
        if let error {
            tasks[request.id] = nil
            if (error as? URLError)?.code != .cancelled { loading.finishLoading(with: error) }
            return
        }
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
              let data else {
            tasks[request.id] = nil
            loading.finishLoading(with: URLError(.badServerResponse))
            return
        }
        if contentLength == nil {
            contentLength = MediaByteRange(header: response.value(forHTTPHeaderField: "Content-Range"))?.total
                ?? (response.statusCode == 200 ? Int64(data.count) : nil)
        }
        if contentType == nil { contentType = response.mimeType }
        if let information = loading.contentInformationRequest {
            information.contentType = contentType.flatMap { UTType(mimeType: $0)?.identifier }
                ?? UTType.mpeg4Movie.identifier
            information.contentLength = contentLength ?? Int64(data.count)
            information.isByteRangeAccessSupported = true
        }
        guard let dataRequest = loading.dataRequest else {
            tasks[request.id] = nil
            loading.finishLoading()
            return
        }
        dataRequest.respond(with: data)
        let next = offset + Int64(data.count)
        let target = end ?? ((contentLength ?? next) - 1)
        if data.isEmpty || next > target {
            tasks[request.id] = nil
            loading.finishLoading()
        } else {
            fetch(request, from: next, through: end)
        }
    }

    /// A loading request, carried across the session's callbacks. They all run on `queue`, the
    /// one AVFoundation hands the request over on.
    private struct Request: @unchecked Sendable {
        let loading: AVAssetResourceLoadingRequest
        var id: ObjectIdentifier { ObjectIdentifier(loading) }
        init(_ loading: AVAssetResourceLoadingRequest) { self.loading = loading }
    }
}

/// Where each piece of a YouTube stream lies, read from the index YouTube puts at its start.
///
/// Played as one file, a stream has to be read from its first byte to wherever playback is to
/// begin before any of it plays: AVFoundation only finds a piece of a fragmented MP4 by reading
/// every piece before it. Twenty minutes into a video that was some 25 MB — and a phone just
/// locked doesn't give the app the time for it, so the sound never came back. YouTube's streams
/// carry their own index, a `sidx` box right after the header, listing every piece's size and
/// length; with it the stream becomes an HLS playlist, and AVPlayer fetches the header and the
/// one piece it needs. Each fetch is a bounded range, which YouTube serves at full speed.
struct StreamIndex: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        let offset: Int64
        let length: Int64
        /// In seconds.
        let duration: Double
    }

    let url: URL
    /// The header — everything before the index — which the playlist names as its map.
    let headerLength: Int64
    let segments: [Segment]

    /// The most of the stream's start read to find the index. Sound has a header of a few
    /// kilobytes and an index of a few more, even for hours of it.
    private static let firstRead: Int64 = 64 * 1024
    private static let longestRead: Int64 = 4 * 1024 * 1024

    static func load(_ url: URL, session: URLSession = .shared) async throws -> StreamIndex {
        var length = firstRead
        while true {
            var request = URLRequest(url: url)
            request.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            switch parse(data, url: url) {
            case .index(let index):
                return index
            case .needs(let more) where more > length && more <= longestRead && Int64(data.count) >= length:
                length = more
            default:
                throw URLError(.cannotParseResponse)
            }
        }
    }

    enum Parsed: Equatable {
        case index(StreamIndex)
        /// The index runs past what was read: read this many bytes from the start.
        case needs(Int64)
        case invalid
    }

    /// Walks the top-level boxes to the index and reads it.
    static func parse(_ data: Data, url: URL) -> Parsed {
        let bytes = [UInt8](data)
        var offset = 0
        while offset + 8 <= bytes.count {
            var size = Int64(read(bytes, offset, 4))
            let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
            var header = 8
            if size == 1 {
                guard offset + 16 <= bytes.count else { return .needs(Int64(offset + 16)) }
                size = Int64(read(bytes, offset + 8, 8))
                header = 16
            }
            guard size >= Int64(header) else { return .invalid }
            let end = Int64(offset) + size
            if type == "sidx" {
                guard end <= Int64(bytes.count) else { return .needs(end) }
                return segments(bytes, box: offset + header, boxEnd: end, headerLength: Int64(offset), url: url)
                    .map(Parsed.index) ?? .invalid
            }
            // Pieces of sound before any index: there is none to find.
            if type == "moof" || type == "mdat" { return .invalid }
            guard end <= Int64(Int.max) else { return .invalid }
            offset = Int(end)
        }
        return .needs(Int64(offset + 8))
    }

    private static func segments(_ bytes: [UInt8], box start: Int, boxEnd: Int64,
                                 headerLength: Int64, url: URL) -> StreamIndex? {
        var cursor = start
        func take(_ count: Int) -> UInt64? {
            guard cursor + count <= Int(boxEnd) else { return nil }
            defer { cursor += count }
            return read(bytes, cursor, count)
        }
        guard let version = take(1), take(3) != nil, take(4) != nil,
              let timescale = take(4), timescale > 0 else { return nil }
        let wide = version == 0 ? 4 : 8
        guard take(wide) != nil, let firstOffset = take(wide), take(2) != nil,
              let count = take(2), count > 0 else { return nil }
        var position = boxEnd + Int64(firstOffset)
        var segments: [Segment] = []
        for _ in 0..<count {
            guard let reference = take(4), let duration = take(4), take(4) != nil else { return nil }
            // A reference to another index rather than to sound: not a shape YouTube uses.
            guard reference & 0x8000_0000 == 0 else { return nil }
            let length = Int64(reference & 0x7FFF_FFFF)
            segments.append(Segment(offset: position, length: length,
                                    duration: Double(duration) / Double(timescale)))
            position += length
        }
        return StreamIndex(url: url, headerLength: headerLength, segments: segments)
    }

    private static func read(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        bytes[offset..<(offset + count)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// The stream as an HLS playlist of byte ranges of itself.
    var playlist: String {
        let target = Int((segments.map(\.duration).max() ?? 1).rounded(.up))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(target, 1))",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(url.absoluteString)\",BYTERANGE=\"\(headerLength)@0\"",
        ]
        for segment in segments {
            lines.append("#EXTINF:\(String(format: "%.3f", segment.duration)),")
            lines.append("#EXT-X-BYTERANGE:\(segment.length)@\(segment.offset)")
            lines.append(url.absoluteString)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Hands AVPlayer a stream's playlist — see `StreamIndex` — under a scheme of the app's own.
/// The pieces it lists are YouTube's own addresses, which AVPlayer fetches itself.
final class PlaylistStreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "betteryoutube-playlist"

    let asset: AVURLAsset
    private let playlist: Data
    private let queue = DispatchQueue(label: "com.atomtoto.BetterYouTube.playlist")

    init(index: StreamIndex) {
        playlist = Data(index.playlist.utf8)
        asset = AVURLAsset(url: URL(string: "\(Self.scheme)://stream/sound.m3u8")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = UTType.m3uPlaylist.identifier
            information.contentLength = Int64(playlist.count)
            information.isByteRangeAccessSupported = false
        }
        if let data = loadingRequest.dataRequest {
            let start = min(Int(data.requestedOffset), playlist.count)
            let end = data.requestsAllDataToEndOfResource
                ? playlist.count
                : min(playlist.count, start + data.requestedLength)
            data.respond(with: playlist.subdata(in: start..<end))
        }
        loadingRequest.finishLoading()
        return true
    }
}
