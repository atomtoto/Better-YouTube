import Foundation
import SwiftUI
import WebKit

/// One event coming back from the YouTube IFrame API. Kept to primitives so it can cross
/// actor boundaries from the script-message handler.
struct PlayerEvent: Sendable {
    let type: String
    let time: Double?
    let duration: Double?
    let state: Int?
}

/// Bridges `window.webkit.messageHandlers.player` into `PlayerManager`.
final class PlayerScriptBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        let event = PlayerEvent(
            type: type,
            time: body["time"] as? Double,
            duration: body["duration"] as? Double,
            state: body["state"] as? Int
        )
        Task { @MainActor in
            PlayerManager.shared.handle(event)
        }
    }
}

/// Owns playback for the whole app: a single web view that outlives any screen, so the video
/// keeps playing while you browse — the mini player in the YouTube app, the Now Playing bar in
/// Apple Music.
///
/// Playback runs through YouTube's IFrame Player API (`controls: 0`), which is what lets the app
/// draw its own transport controls while staying inside the official embed.
@MainActor
final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    @Published private(set) var currentVideo: Video?
    @Published private(set) var upNext: [Video] = []
    @Published var isExpanded = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var areControlsVisible = true

    /// True while a finger is on the scrubber, so time updates don't fight it.
    var isScrubbing = false

    let webView: WKWebView

    private let bridge = PlayerScriptBridge()
    private var isPlayerReady = false
    private var pendingVideoId: String?
    private var hideControlsTask: Task<Void, Never>?

    private init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let controller = WKUserContentController()
        configuration.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .black
        webView.backgroundColor = .black
        webView.isOpaque = false

        controller.add(bridge, name: "player")
    }

    // MARK: - Playback

    /// Starts a video and expands the player. `upNext` becomes the auto-play queue.
    func play(_ video: Video, upNext queue: [Video] = []) {
        LibraryStore.shared.recordWatch(video)

        upNext = queue.filter { $0.id != video.id }
        currentTime = 0
        duration = 0
        isBuffering = true
        showControls()

        let isFirstVideo = currentVideo == nil
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            currentVideo = video
            isExpanded = true
        }

        if isFirstVideo || !isPlayerReady {
            pendingVideoId = video.id
            loadShell(initialVideoId: video.id)
        } else {
            evaluate("loadVideo('\(video.id)')")
        }
    }

    /// Resolves a video ID (from a notification tap) and plays it.
    func open(videoId: String) async {
        if let video = try? await YouTubeAPIService.shared.video(id: videoId) {
            play(video)
        }
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
        showControls()
    }

    func resume() {
        evaluate("resume()")
        isPlaying = true
    }

    func pause() {
        evaluate("pauseVideo()")
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        currentTime = target
        evaluate("seekTo(\(target))")
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
        showControls()
    }

    /// Updates the displayed time while the scrubber is being dragged.
    func scrub(to seconds: Double) {
        currentTime = seconds
    }

    func playNext() {
        guard !upNext.isEmpty else {
            isPlaying = false
            return
        }
        var queue = upNext
        let next = queue.removeFirst()
        play(next, upNext: queue)
    }

    func close() {
        evaluate("stopVideo()")
        hideControlsTask?.cancel()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            isExpanded = false
            currentVideo = nil
        }
        upNext = []
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func expand() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            isExpanded = true
        }
        showControls()
    }

    func collapse() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            isExpanded = false
        }
    }

    // MARK: - Controls visibility

    func showControls(autoHide: Bool = true) {
        hideControlsTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            areControlsVisible = true
        }
        guard autoHide else { return }
        hideControlsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.isPlaying else { return }
            withAnimation(.easeIn(duration: 0.25)) {
                self.areControlsVisible = false
            }
        }
    }

    func toggleControls() {
        if areControlsVisible {
            hideControlsTask?.cancel()
            withAnimation(.easeIn(duration: 0.2)) { areControlsVisible = false }
        } else {
            showControls()
        }
    }

    // MARK: - Events from the web player

    func handle(_ event: PlayerEvent) {
        if let duration = event.duration, duration > 0 {
            self.duration = duration
        }

        switch event.type {
        case "ready":
            isPlayerReady = true
            if let pending = pendingVideoId {
                pendingVideoId = nil
                evaluate("loadVideo('\(pending)')")
            }

        case "state":
            // YT.PlayerState: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued
            guard let state = event.state else { return }
            isPlaying = state == 1
            isBuffering = state == 3
            if state == 1 { showControls() }
            if state == 0 { playNext() }

        case "time":
            if !isScrubbing, let time = event.time {
                currentTime = time
            }

        default:
            break
        }
    }

    // MARK: - Web view plumbing

    private func evaluate(_ javaScript: String) {
        webView.evaluateJavaScript(javaScript, completionHandler: nil)
    }

    private func loadShell(initialVideoId: String) {
        isPlayerReady = false
        let html = Self.shellHTML.replacingOccurrences(of: "__VIDEO_ID__", with: initialVideoId)
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
    }

    private static let shellHTML = """
    <!DOCTYPE html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
      <style>
        html, body { margin: 0; padding: 0; background: #000; height: 100%; overflow: hidden; }
        #player { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }
      </style>
    </head>
    <body>
      <div id="player"></div>
      <script src="https://www.youtube.com/iframe_api"></script>
      <script>
        var player;
        var ticker;

        function post(message) {
          try { window.webkit.messageHandlers.player.postMessage(message); } catch (e) {}
        }

        function safeDuration() {
          return (player && player.getDuration) ? player.getDuration() : 0;
        }

        function startTicker() {
          clearInterval(ticker);
          ticker = setInterval(function () {
            if (player && player.getCurrentTime) {
              post({ type: 'time', time: player.getCurrentTime(), duration: safeDuration() });
            }
          }, 400);
        }

        function onYouTubeIframeAPIReady() {
          player = new YT.Player('player', {
            videoId: '__VIDEO_ID__',
            playerVars: {
              playsinline: 1,
              controls: 0,
              rel: 0,
              modestbranding: 1,
              fs: 0,
              origin: 'https://www.youtube.com'
            },
            events: {
              onReady: function () {
                post({ type: 'ready', duration: safeDuration() });
                startTicker();
                player.playVideo();
              },
              onStateChange: function (event) {
                post({ type: 'state', state: event.data, duration: safeDuration() });
              },
              onError: function (event) {
                post({ type: 'error', state: event.data });
              }
            }
          });
        }

        function loadVideo(id) { if (player && player.loadVideoById) { player.loadVideoById(id); } }
        function resume() { if (player && player.playVideo) { player.playVideo(); } }
        function pauseVideo() { if (player && player.pauseVideo) { player.pauseVideo(); } }
        function seekTo(seconds) { if (player && player.seekTo) { player.seekTo(seconds, true); } }
        function stopVideo() { if (player && player.stopVideo) { player.stopVideo(); } }
      </script>
    </body>
    </html>
    """
}
