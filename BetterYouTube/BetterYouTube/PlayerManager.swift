import Foundation
import SwiftUI
import WebKit

/// One event coming back from the embedded player. Kept to primitives so it can cross actor
/// boundaries from the script-message handler.
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
/// The embed draws its own transport (the same controls as the YouTube app); this type drives it
/// over postMessage for the mini player's play/pause and progress, and for auto-advancing the
/// queue.
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

    let webView: WKWebView

    private let bridge = PlayerScriptBridge()
    private var isPlayerReady = false
    private var pendingVideoId: String?

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

        let isFirstVideo = currentVideo == nil
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            currentVideo = video
            isExpanded = true
        }

        if isFirstVideo || !isPlayerReady {
            pendingVideoId = video.id
            loadShell(initialVideoId: video.id)
        } else {
            evaluate("setVideo('\(video.id)')")
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
    }

    func collapse() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            isExpanded = false
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
                evaluate("setVideo('\(pending)')")
            }

        case "state":
            // YT.PlayerState: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued
            guard let state = event.state else { return }
            isPlaying = state == 1
            isBuffering = state == 3
            if state == 0 { playNext() }

        case "time":
            if let time = event.time {
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

    /// A plain `youtube-nocookie.com/embed` iframe — the same embed that plays reliably in a
    /// `WKWebView`. Control and state ride on the embed's `enablejsapi` postMessage protocol, so
    /// nothing depends on loading YouTube's IFrame API script into a `loadHTMLString` document,
    /// whose origin the API rejects (playback failed with error 152).
    private static let shellHTML = """
    <!DOCTYPE html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
      <style>
        html, body { margin: 0; padding: 0; background: #000; height: 100%; overflow: hidden; }
        #frame { position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: 0; }
      </style>
    </head>
    <body>
      <iframe id="frame"
        src="https://www.youtube-nocookie.com/embed/__VIDEO_ID__?enablejsapi=1&playsinline=1&autoplay=1&rel=0&modestbranding=1&controls=1"
        allow="accelerometer; autoplay; encrypted-media; gyroscope; picture-in-picture"
        allowfullscreen>
      </iframe>
      <script>
        var frame = document.getElementById('frame');
        var handshake;

        function post(message) {
          try { window.webkit.messageHandlers.player.postMessage(message); } catch (e) {}
        }

        function send(message) {
          try { frame.contentWindow.postMessage(JSON.stringify(message), '*'); } catch (e) {}
        }

        function command(func, args) {
          send({ event: 'command', func: func, args: args || [] });
        }

        function setVideo(id) {
          frame.src = 'https://www.youtube-nocookie.com/embed/' + id +
            '?enablejsapi=1&playsinline=1&autoplay=1&rel=0&modestbranding=1&controls=1';
        }

        // The embed only starts reporting state once we introduce ourselves; it can miss the
        // first few messages while it boots, so repeat briefly.
        frame.addEventListener('load', function () {
          clearInterval(handshake);
          var attempts = 0;
          handshake = setInterval(function () {
            send({ event: 'listening', id: 'frame', channel: 'widget' });
            if (++attempts > 20) { clearInterval(handshake); }
          }, 250);
          post({ type: 'ready' });
        });

        window.addEventListener('message', function (event) {
          var data;
          try { data = JSON.parse(event.data); } catch (e) { return; }
          if (!data) { return; }

          if (data.event === 'onStateChange') {
            post({ type: 'state', state: data.info });
          } else if (data.event === 'infoDelivery' && data.info) {
            var info = data.info;
            if (typeof info.playerState === 'number') {
              post({ type: 'state', state: info.playerState, duration: info.duration || 0 });
            }
            if (typeof info.currentTime === 'number') {
              post({ type: 'time', time: info.currentTime, duration: info.duration || 0 });
            }
          }
        });

        function resume() { command('playVideo'); }
        function pauseVideo() { command('pauseVideo'); }
        function seekTo(seconds) { command('seekTo', [seconds, true]); }
        function stopVideo() { frame.src = 'about:blank'; }
      </script>
    </body>
    </html>
    """
}
