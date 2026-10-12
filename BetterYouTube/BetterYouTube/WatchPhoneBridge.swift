#if os(iOS)
import Combine
import Foundation
import UIKit
import WatchConnectivity

/// Exposes the iPhone player and a small library snapshot to the paired watch.
@MainActor
final class WatchPhoneBridge: NSObject {
    static let shared = WatchPhoneBridge()

    private let session = WCSession.default
    private var observations = Set<AnyCancellable>()
    private var started = false
    private var lastAccountRefresh: Date?
    private var accountLibrary: WatchAccountLibrary = .empty
    private var lastLocalLibrary: WatchLocalLibrary?
    private var lastLocalLibraryData: Data?
    private var accountLibraryURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watch-account-library.json")
    }
    private var localLibraryURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watch-local-library.json")
    }

    func start() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        session.delegate = self
        session.activate()

        let player = PlayerManager.shared
        let library = LibraryStore.shared
        let watchLater = WatchLaterStore.shared
        let downloads = DownloadStore.shared
        let apiKey = APIKeyStore.shared
        let webSession = YouTubeWebSession.shared
        let auth = GoogleAuthService.shared

        if let data = try? Data(contentsOf: accountLibraryURL),
           let cached = try? JSONDecoder().decode(WatchAccountLibrary.self, from: data) {
            accountLibrary = cached
        }

        player.$currentVideo.sink { [weak self] _ in self?.publishSoon() }.store(in: &observations)
        player.$isPlaying.sink { [weak self] _ in self?.publishSoon() }.store(in: &observations)
        player.$upNext.sink { [weak self] _ in self?.publishSoon() }.store(in: &observations)
        player.progress.$duration.sink { [weak self] _ in self?.publishSoon() }.store(in: &observations)
        player.progress.$currentTime
            .throttle(for: .seconds(10), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.publishSoon() }
            .store(in: &observations)
        library.$favorites.sink { [weak self] _ in self?.publishSoon() }.store(in: &observations)
        library.$watchLater.sink { [weak self] _ in self?.publishSoon() }.store(in: &observations)
        library.$history.sink { [weak self] _ in self?.publishSoon() }.store(in: &observations)
        watchLater.$entries.sink { [weak self] _ in self?.publishSoon() }.store(in: &observations)
        watchLater.$usesYouTubeWatchLater.sink { [weak self] _ in self?.publishSoon() }.store(in: &observations)
        downloads.$records.sink { [weak self] _ in self?.publishSoon() }.store(in: &observations)
        apiKey.$apiKey.sink { [weak self] _ in self?.publishSoon() }.store(in: &observations)
        webSession.$isSignedIn.sink { [weak self] _ in self?.publishSoon() }.store(in: &observations)
        auth.$isSignedIn.sink { [weak self] signedIn in
            guard let self else { return }
            if !signedIn {
                self.accountLibrary = .empty
                try? FileManager.default.removeItem(at: self.accountLibraryURL)
            }
            self.publishSoon()
        }.store(in: &observations)
        // Posted by whichever thread saved the cache; the closure is the main actor's.
        NotificationCenter.default.publisher(for: YouTubeHomeCache.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.publishSoon() }.store(in: &observations)
    }

    private var pendingPublish: Task<Void, Never>?

    /// Also called when a demo ends, to send the real library again.
    func publishSoon() {
        pendingPublish?.cancel()
        pendingPublish = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }

    private func snapshot() -> WatchSnapshot {
        let player = PlayerManager.shared
        let library = LibraryStore.shared
        return WatchSnapshot(
            current: player.currentVideo.map(WatchVideo.init),
            isPlaying: player.isPlaying,
            elapsed: player.progress.currentTime,
            duration: player.progress.duration,
            upNext: Array(player.upNext.prefix(20)).map(WatchVideo.init),
            homeFeed: YouTubeWebSession.shared.isSignedIn
                ? (YouTubeWebSession.shared.feedCache.load()?.videos.prefix(30).map(WatchVideo.init) ?? [])
                : [],
            favorites: Array(library.favorites.prefix(30)).map(WatchVideo.init),
            watchLater: Array(WatchLaterStore.shared.videos.prefix(30)).map(WatchVideo.init),
            history: Array(library.history.prefix(50)).map(WatchVideo.init),
            downloads: DownloadStore.shared.records.filter(\.isReady).prefix(30).map { WatchVideo($0.video) },
            accountSignedIn: GoogleAuthService.shared.isSignedIn,
            updatedAt: .now
        )
    }

    private func encodedSnapshot() -> Data? {
        try? JSONEncoder().encode(snapshot())
    }

    private func transferLocalLibraryIfNeeded() -> Data? {
        let library = WatchLocalLibrary(
            favorites: LibraryStore.shared.favorites.map(WatchVideo.init),
            watchLater: WatchLaterStore.shared.videos.map(WatchVideo.init),
            history: LibraryStore.shared.history.map(WatchVideo.init),
            downloads: DownloadStore.shared.records.filter(\.isReady).map { WatchVideo($0.video) }
        )
        guard library != lastLocalLibrary else { return lastLocalLibraryData }
        guard let data = try? JSONEncoder().encode(library),
              (try? data.write(to: localLibraryURL, options: .atomic)) != nil else {
            return lastLocalLibraryData
        }
        lastLocalLibrary = library
        lastLocalLibraryData = data
        session.transferFile(localLibraryURL, metadata: ["kind": "localLibrary"])
        return data
    }

    private func publish() {
        // The watch keeps the real library; a demo's would only have to be taken back.
        guard !DemoMode.isRunning,
              session.activationState == .activated,
              session.isWatchAppInstalled,
              let data = encodedSnapshot() else { return }
        var context: [String: Any] = [WatchMessage.snapshot: data,
                                      WatchMessage.apiKey: APIKeyStore.shared.apiKey]
        if let local = transferLocalLibraryIfNeeded(), local.count <= 24 * 1024 {
            context[WatchMessage.localLibrary] = local
        }
        try? session.updateApplicationContext(context)
        if session.isReachable {
            session.sendMessage(context, replyHandler: nil, errorHandler: nil)
        }
    }

    private func video(withID id: String) -> Video? {
        let player = PlayerManager.shared
        return ([player.currentVideo].compactMap { $0 } + player.upNext
            + LibraryStore.shared.favorites + WatchLaterStore.shared.videos
            + LibraryStore.shared.history + DownloadStore.shared.records.map(\.video)).first { $0.id == id }
    }

    private func refreshAccountLibrary() async -> String? {
        guard GoogleAuthService.shared.isSignedIn else {
            accountLibrary = .empty
            return String(localized: "Connect the Google account in the iPhone app to sync this library.")
        }
        if let lastAccountRefresh, Date().timeIntervalSince(lastAccountRefresh) < 15 * 60,
           FileManager.default.fileExists(atPath: accountLibraryURL.path) {
            session.transferFile(accountLibraryURL, metadata: ["kind": "accountLibrary"])
            return nil
        }
        let api = YouTubeAPIService.shared
        let fetched: WatchAccountLibrary
        do {
            async let channels = api.mySubscriptions()
            async let playlists = api.myPlaylists()
            async let liked = api.likedVideos()
            let (subscriptions, accountPlaylists, likedVideos) = try await (channels, playlists, liked)
            fetched = WatchAccountLibrary(
                subscriptions: subscriptions.map {
                    WatchChannel(id: $0.id, title: $0.title, thumbnailURL: $0.thumbnailURL)
                },
                playlists: accountPlaylists.filter { !$0.isLikedVideos }.map {
                    WatchPlaylist(id: $0.id, title: $0.title, thumbnailURL: $0.thumbnailURL)
                },
                likedVideos: likedVideos.map(WatchVideo.init)
            )
        } catch {
            return String(localized: "Couldn’t sync the account: \(error.localizedDescription)")
        }
        guard GoogleAuthService.shared.isSignedIn else { return String(localized: "The Google account was signed out.") }
        accountLibrary = fetched
        lastAccountRefresh = .now
        guard let data = try? JSONEncoder().encode(fetched),
              (try? data.write(to: accountLibraryURL, options: .atomic)) != nil else {
            return String(localized: "Couldn’t save the library for the watch.")
        }
        session.transferFile(accountLibraryURL, metadata: ["kind": "accountLibrary"])
        publishSoon()
        return nil
    }

    private func handle(_ message: [String: Any]) async -> [String: Any] {
        guard let command = message[WatchMessage.command] as? String else {
            return [WatchMessage.error: String(localized: "Unknown command.")]
        }
        let player = PlayerManager.shared
        var error: String?
        switch command {
        case "refresh": break
        case "refreshLibrary":
            if let issue = await refreshAccountLibrary() { error = issue }
        case "playlistVideos", "channelVideos":
            guard let id = message[WatchMessage.videoID] as? String,
                  !id.isEmpty, id.count <= 128,
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
                error = String(localized: "Invalid list ID.")
                break
            }
            do {
                let videos = command == "playlistVideos"
                    ? try await YouTubeAPIService.shared.entries(inPlaylist: id, limit: 200).map(\.video)
                    : try await YouTubeAPIService.shared.videos(byChannel: id, maxResults: 50)
                let data = try JSONEncoder().encode(videos.map(WatchVideo.init))
                return [WatchMessage.videos: data]
            } catch let loadError { error = loadError.localizedDescription }
        case "toggle":
            if player.currentVideo != nil { player.togglePlayPause() }
            else { error = String(localized: "Nothing is playing on the iPhone.") }
        case "next":
            if !player.upNext.isEmpty { player.playNext() }
            else { error = String(localized: "The queue is empty.") }
        case "back15":
            if player.currentVideo != nil { player.seek(to: player.progress.currentTime - 15) }
            else { error = String(localized: "Nothing is playing on the iPhone.") }
        case "forward15":
            if player.currentVideo != nil { player.seek(to: player.progress.currentTime + 15) }
            else { error = String(localized: "Nothing is playing on the iPhone.") }
        case "play":
            guard let id = message[WatchMessage.videoID] as? String,
                  let video = video(withID: id) else {
                error = String(localized: "This video is no longer in the iPhone’s library.")
                break
            }
            // WebKit needs an on-screen surface to begin a new embed. An existing native
            // playback can still be controlled while the iPhone is locked.
            if UIApplication.shared.applicationState != .active {
                error = String(localized: "Open Better YouTube on the iPhone to start this video.")
            } else {
                player.play(video)
            }
        case "transferDownload":
            guard let id = message[WatchMessage.videoID] as? String,
                  let video = video(withID: id),
                  let file = DownloadStore.shared.readyMediaURL(for: id),
                  let videoData = try? JSONEncoder().encode(WatchVideo(video)) else {
                error = String(localized: "Download not found on the iPhone.")
                break
            }
            session.transferFile(file, metadata: ["video": videoData])
        case "prepareAudio":
            guard let id = message[WatchMessage.videoID] as? String,
                  id.count == 11,
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else {
                error = String(localized: "Invalid video ID.")
                break
            }
            do {
                let media = try await LocalDownloadResolver.shared.resolveWatchAudio(videoID: id)
                return [WatchMessage.mediaURL: media.url.absoluteString,
                        WatchMessage.byteCount: media.byteCount]
            } catch let resolutionError {
                error = resolutionError.localizedDescription
            }
        default:
            error = String(localized: "Unknown command.")
        }
        if let error { return [WatchMessage.error: error] }
        publishSoon()
        var reply: [String: Any] = [WatchMessage.apiKey: APIKeyStore.shared.apiKey]
        if let data = encodedSnapshot() { reply[WatchMessage.snapshot] = data }
        if let data = transferLocalLibraryIfNeeded(), data.count <= 24 * 1024 {
            reply[WatchMessage.localLibrary] = data
        }
        return reply
    }
}

private extension WatchVideo {
    init(_ video: Video) {
        self.init(id: video.id, title: video.title, channel: video.channelTitle,
                  thumbnailURL: video.thumbnailURL)
    }
}

extension WatchPhoneBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.publish() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.publish() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.publish() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        let message = WatchDictionary(message)
        let reply = WatchReply(send: replyHandler)
        Task { @MainActor in reply.send(await self.handle(message.value)) }
    }
}
#endif
