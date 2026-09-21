import AVFoundation
import Foundation
import Network
import Testing
@testable import BetterYouTube

struct LocalDownloadSelectionTests {
    private func candidate(_ name: String, height: Int? = nil, audio: Bool = false, compatible: Bool = true, bitrate: Int = 100) -> LocalMediaCandidate {
        LocalMediaCandidate(url: URL(string: "https://media.example/\(name)")!, height: height, bitrate: bitrate,
                            hasVideo: height != nil, hasAudio: audio, compatible: compatible)
    }

    @Test func qualityAndAudio() throws {
        let items = [candidate("1080", height: 1080), candidate("720", height: 720),
                     candidate("360", height: 360, audio: true), candidate("aac", audio: true),
                     candidate("webm", height: 720, compatible: false, bitrate: 10000)]
        let medium = try LocalDownloadResolver.select(items, maxHeight: 720)
        #expect(medium.url.lastPathComponent == "720")
        #expect(medium.audioURL?.lastPathComponent == "aac")
        let low = try LocalDownloadResolver.select(items, maxHeight: 360)
        #expect(low.url.lastPathComponent == "360")
        #expect(low.audioURL == nil)
    }

    @Test func prefersProgressiveAtSameQuality() throws {
        let media = try LocalDownloadResolver.select([
            candidate("video", height: 720, bitrate: 1000), candidate("aac", audio: true),
            candidate("muxed", height: 720, audio: true)
        ], maxHeight: 720)
        #expect(media.url.lastPathComponent == "muxed")
        #expect(media.audioURL == nil)
    }

    @Test func neverDownloadsSilentOrOversizedVideo() {
        #expect(throws: DownloadError.self) {
            try LocalDownloadResolver.select([candidate("silent", height: 720)], maxHeight: 720)
        }
        #expect(throws: DownloadError.self) {
            try LocalDownloadResolver.select([candidate("large", height: 1080, audio: true)], maxHeight: 360)
        }
        #expect(throws: DownloadError.self) { try LocalDownloadResolver.select([], maxHeight: 720) }
    }

    @Test func rejectsInvalidByteRanges() {
        let range = MediaByteRange(header: "bytes 1024-2047/4096")
        #expect(range?.start == 1024)
        #expect(range?.end == 2047)
        #expect(range?.total == 4096)
        for header in ["", "bytes */400", "bytes 3-2/5", "bytes 0-5/5", "bytes 0-0/*", "bytes 0-0/-2"] {
            #expect(MediaByteRange(header: header) == nil)
        }
    }

    @Test func backendMigration() {
        #expect(DownloadBackend.restored(saved: nil, endpoint: "") == .local)
        #expect(DownloadBackend.restored(saved: nil, endpoint: "https://my-server.example") == .server)
        #expect(DownloadBackend.restored(saved: "local", endpoint: "https://my-server.example") == .local)
        #expect(DownloadBackend.restored(saved: "server", endpoint: "") == .server)
    }

    @Test func oldManifestStillDecodes() throws {
        let record = DownloadRecord(video: testVideo(), quality: .medium)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json.removeValue(forKey: "transfer")
        let decoded = try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.transfer == nil)
        #expect(decoded.quality == .medium)
    }
}

@Suite(.serialized)
@MainActor
struct LocalDownloadQueueTests {
    @Test func splitDownloadBecomesPlayableFile() async throws {
        let server = try await FixtureHTTPServer.start()
        defer { server.stop() }
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        let manager = DownloadManager(store: store, configuration: .ephemeral) { _, _, _ in
            ResolvedMedia(url: server.url("video.mp4"), byteCount: nil, audioURL: server.url("audio.m4a"))
        }
        let video = testVideo()
        store.upsert(DownloadRecord(video: video, state: .paused, quality: .medium))
        manager.resume(video.id)
        try await waitUntil { store.isDownloaded(video.id) || isFailed(store.state(for: video.id)) }
        #expect(store.state(for: video.id) == .ready, "\(String(describing: store.state(for: video.id)))")
        try await DownloadMediaAssembler.validate(store.paths.mediaURL(for: video.id))
        #expect(!FileManager.default.fileExists(atPath: store.paths.componentURL(for: video.id, audio: false).path))
        #expect(!FileManager.default.fileExists(atPath: store.paths.componentURL(for: video.id, audio: true).path))
        let reopened = DownloadStore(root: store.paths.root)
        #expect(reopened.state(for: video.id) == .ready)
        manager.removeAll()
    }

    @Test func rangedTracksResumeFromSavedOffset() async throws {
        let server = try await FixtureHTTPServer.start()
        defer { server.stop() }
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        let video = testVideo()
        let videoData = try Data(contentsOf: fixture("video.mp4"))
        let audioData = try Data(contentsOf: fixture("audio.m4a"))
        var record = DownloadRecord(video: video, state: .downloading, quality: .medium)
        record.mediaURL = server.url("video.mp4")
        record.transfer = DownloadTransfer(audioURL: server.url("audio.m4a"), wifiOnly: false,
                                           usesByteRanges: true, videoByteCount: Int64(videoData.count),
                                           audioByteCount: Int64(audioData.count), offset: 1024)
        store.upsert(record)
        try FileManager.default.createDirectory(at: store.paths.folder(for: video.id), withIntermediateDirectories: true)
        try videoData.prefix(1024).write(to: store.paths.componentURL(for: video.id, audio: false))
        let reopened = DownloadStore(root: store.paths.root)
        let manager = DownloadManager(store: reopened, configuration: .ephemeral, chunkSize: 1024) { _, _, _ in
            Issue.record("Resume must use the saved byte offset")
            throw DownloadError.noMedia
        }
        manager.resume(video.id)
        try await waitUntil { reopened.isDownloaded(video.id) || isFailed(reopened.state(for: video.id)) }
        #expect(reopened.isDownloaded(video.id), "\(String(describing: reopened.state(for: video.id)))")
        try await DownloadMediaAssembler.validate(reopened.paths.mediaURL(for: video.id))
        #expect(server.ranges.first == "bytes=1024-\(videoData.count - 1)")
        #expect(server.ranges.count > 3)
        manager.removeAll()
    }

    @Test func resumesAssemblyAfterRelaunchWithoutNetwork() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        let video = testVideo()
        var record = DownloadRecord(video: video, state: .processing, quality: .medium)
        record.transfer = DownloadTransfer(audioURL: URL(string: "https://expired.example/audio"), downloadingAudio: true, wifiOnly: true)
        store.upsert(record)
        try FileManager.default.createDirectory(at: store.paths.folder(for: video.id), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture("video.mp4"), to: store.paths.componentURL(for: video.id, audio: false))
        try FileManager.default.copyItem(at: fixture("audio.m4a"), to: store.paths.componentURL(for: video.id, audio: true))
        let reopened = DownloadStore(root: store.paths.root)
        #expect(reopened.state(for: video.id) == .paused)
        let manager = DownloadManager(store: reopened, configuration: .ephemeral) { _, _, _ in
            Issue.record("Assembly must not resolve a new URL")
            throw DownloadError.noMedia
        }
        manager.resume(video.id)
        try await waitUntil { reopened.isDownloaded(video.id) || isFailed(reopened.state(for: video.id)) }
        #expect(reopened.isDownloaded(video.id))
        manager.removeAll()
    }

    @Test func lateResolveCannotUndoPauseOrRemoval() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        let gate = ResolveGate()
        let manager = DownloadManager(store: store, configuration: .ephemeral) { _, _, _ in
            await gate.wait()
            throw DownloadError.service("Late result")
        }
        let video = testVideo()
        store.upsert(DownloadRecord(video: video, state: .paused, quality: .medium))
        manager.resume(video.id)
        try await waitUntil { store.state(for: video.id) == .resolving }
        // Yield so the injected resolver reaches its continuation before pausing it.
        try await waitUntil { await gate.isWaiting }
        manager.pause(video.id)
        await gate.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.state(for: video.id) == .paused)
        manager.resume(video.id)
        try await waitUntil { await gate.isWaiting }
        manager.remove(video.id)
        await gate.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.record(for: video.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.paths.folder(for: video.id).path))
    }

    @Test func httpErrorNeverInstallsAndRetryResolvesAgain() async throws {
        let server = try await FixtureHTTPServer.start()
        defer { server.stop() }
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.paths.root) }
        var attempts = 0
        let manager = DownloadManager(store: store, configuration: .ephemeral) { _, _, _ in
            attempts += 1
            return ResolvedMedia(url: server.url(attempts == 1 ? "forbidden" : "video.mp4"), byteCount: nil,
                                 audioURL: attempts == 1 ? nil : server.url("audio.m4a"))
        }
        let video = testVideo()
        store.upsert(DownloadRecord(video: video, state: .paused, quality: .medium))
        manager.resume(video.id)
        try await waitUntil { isFailed(store.state(for: video.id)) }
        #expect(store.readyMediaURL(for: video.id) == nil)
        manager.retry(video.id)
        try await waitUntil { store.isDownloaded(video.id) || attempts > 1 && isFailed(store.state(for: video.id)) }
        #expect(store.isDownloaded(video.id))
        #expect(attempts == 2)
        manager.removeAll()
    }

    @Test func refusesAudioOnlyAndErrorPage() async throws {
        await #expect(throws: (any Error).self) { try await DownloadMediaAssembler.validate(fixture("audio.m4a")) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let html = folder.appendingPathComponent("error.mp4")
        try Data("<html>Forbidden</html>".utf8).write(to: html)
        await #expect(throws: (any Error).self) { try await DownloadMediaAssembler.validate(html) }
    }

    private func makeStore() -> DownloadStore {
        DownloadStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("download-test-\(UUID().uuidString)"))
    }
}

private func testVideo() -> Video {
    Video(id: "test-\(UUID().uuidString)", title: "Fixture", channelId: "fixture", channelTitle: "Fixture",
          description: "", thumbnailURL: nil, publishedAt: nil)
}

private func fixture(_ name: String) -> URL {
    Bundle(for: FixtureBundle.self).url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
}
private final class FixtureBundle: NSObject {}
private func isFailed(_ state: DownloadState?) -> Bool {
    if case .failed = state { return true }
    return false
}

@MainActor
private func waitUntil(_ condition: () async -> Bool) async throws {
    for _ in 0..<400 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    throw DownloadError.service("Timed out waiting for download test")
}

private actor ResolveGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

/// Loopback HTTP fixtures exercise real URLSession download callbacks without YouTube or a
/// public resolver. Both tracks are one-second, synthetic H.264/AAC files.
private final class FixtureHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "download-http-fixture")
    private let rangeLock = NSLock()
    private var receivedRanges: [String] = []
    var ranges: [String] { rangeLock.withLock { receivedRanges } }
    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    static func start() async throws -> FixtureHTTPServer {
        let server = try FixtureHTTPServer()
        server.listener.newConnectionHandler = { connection in
            connection.start(queue: server.queue)
            server.receive(connection, buffered: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    server.listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    server.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/\(path)")! }
    func stop() { listener.newConnectionHandler = nil; listener.cancel() }
    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, complete, error in
            var request = buffered
            request.append(data ?? Data())
            if let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") {
                let path = text.components(separatedBy: " ").dropFirst().first ?? ""
                let name = path == "/video.mp4" ? "video.mp4" : "audio.m4a"
                let allowed = path == "/video.mp4" || path == "/audio.m4a"
                var body = allowed ? (try! Data(contentsOf: fixture(name))) : Data("Forbidden".utf8)
                var status = allowed ? "200 OK" : "403 Forbidden"
                var rangeHeader = ""
                if allowed, let line = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("range: ") }) {
                    let header = String(line.dropFirst(7))
                    self.rangeLock.withLock { self.receivedRanges.append(header) }
                    let bounds = header.dropFirst(6).split(separator: "-").compactMap { Int($0) }
                    if bounds.count == 2, bounds[0] >= 0, bounds[1] >= bounds[0], bounds[1] < body.count {
                        rangeHeader = "Content-Range: bytes \(bounds[0])-\(bounds[1])/\(body.count)\r\n"
                        body = body.subdata(in: bounds[0]..<(bounds[1] + 1))
                        status = "206 Partial Content"
                    }
                }
                var response = Data("HTTP/1.1 \(status)\r\n\(rangeHeader)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffered: request)
            }
        }
    }
}

/// Opt-in only: the normal suite has no dependency on YouTube availability.
@MainActor
struct LiveLocalDownloadTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BETTERYOUTUBE_LIVE_DOWNLOAD"] == "1"))
    func publicVideoDownloadsWithoutResolver() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-download-\(UUID().uuidString)")
        let store = DownloadStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.background(withIdentifier: "com.atomtoto.BetterYouTube.live-test.\(UUID().uuidString)")
        let manager = DownloadManager(store: store, configuration: configuration) { video, quality, _ in
            try await LocalDownloadResolver.shared.resolve(videoID: video.id, quality: quality, wifiOnly: false)
        }
        defer { manager.removeAll() }
        // Blender's public Big Buck Bunny demo. Override to verify another public video.
        let id = ProcessInfo.processInfo.environment["BETTERYOUTUBE_LIVE_VIDEO"] ?? "aqz-KE-bpKQ"
        let video = Video(id: id, title: "Live download check", channelId: "test", channelTitle: "Test",
                          description: "", thumbnailURL: nil, publishedAt: nil)
        store.upsert(DownloadRecord(video: video, state: .paused, quality: .low))
        manager.resume(id)
        for _ in 0..<1200 {
            if store.isDownloaded(id) || isFailed(store.state(for: id)) { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(store.isDownloaded(id), "\(String(describing: store.state(for: id)))")
        let file = try #require(store.readyMediaURL(for: id))
        try await DownloadMediaAssembler.validate(file)
        #expect((store.record(for: id)?.totalBytes ?? 0) > 0)
    }
}

#if os(iOS)
import AVKit
import UIKit

@MainActor
struct NativeLocalPlayerTests {
    @Test("Full-screen requests are retained until the native surface is attached")
    func queuedFullScreenRequest() {
        let playback = LocalPlayback()
        playback.setFullScreen(true)
        var received: [Bool] = []
        playback.onFullScreenRequest = { received.append($0) }
        #expect(received == [true])
        playback.stop()
        #expect(received == [true, false])
    }

    @Test("Background audio detaches only the presentation and restores the same player item")
    func backgroundPreservesPlayback() {
        let playback = LocalPlayback()
        playback.load(url: fixture("video.mp4"))
        let item = playback.player.currentItem
        let controller = AVPlayerViewController()
        controller.player = playback.player
        let coordinator = LocalPlayerSurface.Coordinator(playback: playback)
        coordinator.attach(controller)
        defer { coordinator.detach(); playback.stop() }

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(controller.player == nil)
        #expect(playback.player.currentItem === item)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(controller.player === playback.player)
        #expect(controller.player?.currentItem === item)

        // An active PiP presentation must keep its player even while the app is away.
        coordinator.playerViewControllerWillStartPictureInPicture(controller)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(controller.player === playback.player)
        coordinator.playerViewControllerDidStopPictureInPicture(controller)
    }
}
#endif
