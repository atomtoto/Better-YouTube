import AVFoundation
import Foundation
import Network
import YouTubeKit

/// No remote fallback: only YouTube receives extraction and media requests.
actor LocalDownloadResolver {
    static let shared = LocalDownloadResolver()

    func resolve(videoID: String, quality: DownloadQuality, wifiOnly: Bool) async throws -> ResolvedMedia {
        if wifiOnly { try await Self.requireUnmeteredConnection() }
        try Task.checkCancellation()
        do {
            let streams = try await YouTube(videoID: videoID, methods: [.local]).streams
            try Task.checkCancellation()
            let candidates = streams.map { stream in
                LocalMediaCandidate(
                    url: stream.url,
                    height: stream.videoResolution,
                    bitrate: stream.bitrate ?? 0,
                    hasVideo: stream.includesVideoTrack,
                    hasAudio: stream.includesAudioTrack,
                    compatible: (stream.fileExtension == .mp4 || stream.fileExtension == .m4a)
                        && (!stream.includesVideoTrack || stream.videoCodec == .avc1)
                        && (!stream.includesAudioTrack || stream.audioCodec == .mp4a)
                )
            }
            let selected = try Self.select(candidates, maxHeight: quality.maxHeight)
            let videoBytes = try await Self.contentLength(selected.url, wifiOnly: wifiOnly)
            var audioBytes: Int64?
            if let audio = selected.audioURL { audioBytes = try await Self.contentLength(audio, wifiOnly: wifiOnly) }
            return ResolvedMedia(url: selected.url, byteCount: videoBytes, audioURL: selected.audioURL,
                                 audioByteCount: audioBytes, usesByteRanges: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DownloadError.service("On-device download couldn't resolve this video. \(error.localizedDescription) You can retry, update the app, or choose your server in Settings → Downloads.")
        }
    }

    /// Prefer the best picture under the ceiling, with audio always included. A progressive
    /// stream wins ties; otherwise AVFoundation joins the H.264 and AAC tracks without encoding.
    nonisolated static func select(_ candidates: [LocalMediaCandidate], maxHeight: Int) throws -> ResolvedMedia {
        let usable = candidates.filter { candidate in
            candidate.compatible && candidate.url.scheme == "https" && candidate.url.host != nil
        }
        let audio = usable.filter { $0.hasAudio && !$0.hasVideo }.max { $0.bitrate < $1.bitrate }
        let videos = usable.filter {
            $0.hasVideo && ($0.hasAudio || audio != nil) && ($0.height ?? 0) > 0
                && ($0.height ?? Int.max) <= maxHeight
        }.sorted {
            if $0.height != $1.height { return ($0.height ?? 0) > ($1.height ?? 0) }
            if $0.hasAudio != $1.hasAudio { return $0.hasAudio }
            return $0.bitrate > $1.bitrate
        }
        guard let video = videos.first else {
            throw DownloadError.service("No compatible video with audio is available at this quality. Try a higher quality or your server. Live and restricted videos may not be downloadable on this device.")
        }
        return ResolvedMedia(url: video.url, byteCount: nil, audioURL: video.hasAudio ? nil : audio?.url)
    }

    /// YouTube may accept bounded byte ranges while refusing an unbounded GET. Probe a single
    /// byte for the exact length, then hand bounded transfers to the background queue.
    private static func contentLength(_ url: URL, wifiOnly: Bool) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.allowsCellularAccess = !wifiOnly
        request.allowsExpensiveNetworkAccess = !wifiOnly
        request.timeoutInterval = 30
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw DownloadError.noMedia }
        guard response.statusCode == 206 else { throw DownloadError.http(response.statusCode) }
        guard let range = MediaByteRange(header: response.value(forHTTPHeaderField: "Content-Range")),
              range.start == 0, range.end == 0 else {
            throw DownloadError.service("YouTube didn't provide the media length needed to download this video.")
        }
        return range.total
    }

    /// YouTubeKit's metadata requests use its own session. Gate extraction on the current path;
    /// the large media transfers additionally enforce the preference on every URLRequest.
    private static func requireUnmeteredConnection() async throws {
        let monitor = NWPathMonitor()
        let allowed = await withCheckedContinuation { continuation in
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied && !path.isExpensive && !path.usesInterfaceType(.cellular))
            }
            monitor.start(queue: DispatchQueue(label: "com.atomtoto.BetterYouTube.download-network"))
        }
        try Task.checkCancellation()
        guard allowed else {
            throw DownloadError.service("Connect to Wi-Fi to download, or turn off Wi-Fi Only in Settings → Downloads.")
        }
    }
}

struct LocalMediaCandidate: Sendable {
    let url: URL
    let height: Int?
    let bitrate: Int
    let hasVideo: Bool
    let hasAudio: Bool
    let compatible: Bool
}

/// Runs only on completed local files. No FFmpeg, subprocess, or server is involved.
enum DownloadMediaAssembler {
    static func merge(video: URL, audio: URL, output: URL) async throws {
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw DownloadError.service("The downloaded files are missing a video or audio track.")
        }
        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw DownloadError.service("Couldn't prepare the downloaded video.")
        }
        let videoRange = try await videoTrack.load(.timeRange)
        let audioRange = try await audioTrack.load(.timeRange)
        let duration = CMTimeMinimum(videoRange.duration, audioRange.duration)
        guard duration.isNumeric, duration > .zero else { throw DownloadError.noMedia }
        try picture.insertTimeRange(CMTimeRange(start: videoRange.start, duration: duration), of: videoTrack, at: .zero)
        picture.preferredTransform = try await videoTrack.load(.preferredTransform)
        try sound.insertTimeRange(CMTimeRange(start: audioRange.start, duration: duration), of: audioTrack, at: .zero)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw DownloadError.service("Couldn't assemble the downloaded video.")
        }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await export.export(to: output, as: .mp4)
        } onCancel: {
            export.cancelExport()
        }
        try Task.checkCancellation()
        try await validate(output)
    }

    static func validate(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable),
              !(try await asset.loadTracks(withMediaType: .video)).isEmpty,
              !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw DownloadError.service("The download isn't a playable video with audio.")
        }
    }
}

/// Strict parsing prevents a truncated or ignored Range response from becoming a ready file.
struct MediaByteRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64
    init?(header: String?) {
        guard let header, header.hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst(6).split(separator: "/")
        guard parts.count == 2, let total = Int64(parts[1]), total > 0 else { return nil }
        let bounds = parts[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start, end < total else { return nil }
        self.start = start
        self.end = end
        self.total = total
    }
}
