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

/// Why playback isn't running.
enum PlaybackIssue: Equatable {
    /// YouTube's player refused the video, with its own error code.
    case playerError(Int)
    /// The page hosting the player failed to load.
    case loadFailed(String)
    /// The page loaded but never reported back.
    case noResponse
}

/// Surfaces page-level load failures, which never reach the JavaScript bridge.
final class PlayerNavigationBridge: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in PlayerManager.shared.handleLoadFailure(message) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in PlayerManager.shared.handleLoadFailure(message) }
    }
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

/// Playback position, deliberately kept off `PlayerManager`: the embed reports it several times
/// a second, and publishing it on the manager would re-render every view that watches the player
/// at that rate — which is what made dragging the player down feel jerky. Only the hairline of
/// progress in the docked bar observes this.
@MainActor
final class PlaybackProgress: ObservableObject {
    @Published fileprivate(set) var currentTime: Double = 0
    @Published fileprivate(set) var duration: Double = 0

    /// How much of the video has played, 0...1.
    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    fileprivate func reset() {
        currentTime = 0
        duration = 0
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
    /// True while the docked bar is shrunk to its pill, which is what scrolling down does — the
    /// same gesture that minimizes the tab bar underneath it.
    @Published private(set) var isBarCompact = false
    /// True while the video fills the screen on its own, which is what turning the phone on its
    /// side does. The expanded player's chrome steps aside for it.
    @Published private(set) var isFullScreen = false
    /// True while *iOS* is the one showing the video full screen — its own full-screen
    /// presentation over the app, with the system's controls — rather than the app laying the
    /// video out edge to edge itself. `isFullScreen` is that fallback, and stays true underneath.
    @Published private(set) var isSystemFullScreen = false
    /// Position and duration, published apart from everything else because they tick constantly.
    let progress = PlaybackProgress()
    /// Set whenever playback fails to start, so the UI can say what happened instead of
    /// showing a silent black rectangle.
    @Published private(set) var issue: PlaybackIssue?

    let webView: WKWebView

    private let bridge = PlayerScriptBridge()
    private let navigationBridge = PlayerNavigationBridge()
    private var watchdog: Task<Void, Never>?
    /// The video that should be playing, and the one the web view actually has.
    private var desiredVideoId: String?
    private var loadedVideoId: String?
    private var isShellLoaded = false
    private var isLoadingShell = false
    /// YouTube refuses to start in a zero-sized, off-screen player, so nothing loads until the
    /// surface is really on screen.
    private var isSurfaceOnScreen = false
    /// Whether the phone is on its side. Kept even with nothing playing, so a video started in
    /// landscape opens full screen straight away.
    private var isLandscape = false
    /// Where the player was before landscape took it full screen, so turning the phone back puts
    /// it where it was rather than always expanded.
    private var wasExpandedBeforeFullScreen = false
    /// Set while the phone is on its side with a video that hasn't been handed to iOS yet.
    private var wantsSystemFullScreen = false
    /// The run of attempts to hand it over, cancelled as soon as one takes.
    private var fullScreenRequest: Task<Void, Never>?
    /// WebKit's own account of whether its full-screen window is up.
    private var fullScreenObserver: NSKeyValueObservation?

    private init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Lets the page hand the video to the system's full-screen presentation, which is what
        // turning the phone now does. Without it WebKit refuses the request and all the app can
        // do is draw an imitation of full screen itself.
        configuration.preferences.isElementFullscreenEnabled = true

        let controller = WKUserContentController()
        configuration.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .black
        webView.backgroundColor = .black
        webView.isOpaque = false

        controller.add(bridge, name: "player")
        webView.navigationDelegate = navigationBridge

        // Whatever opens or closes the system's full-screen window — a rotation, the embed's own
        // full-screen button, the Done button over the video — WebKit reports it here, so the
        // app's idea of the state never drifts from what is on screen.
        fullScreenObserver = webView.observe(\.fullscreenState) { webView, _ in
            let active = webView.fullscreenState == .inFullscreen
            Task { @MainActor in PlayerManager.shared.setSystemFullScreen(active) }
        }
    }

    // MARK: - Playback

    /// Starts a video and expands the player. `upNext` becomes the auto-play queue.
    func play(_ video: Video, upNext queue: [Video] = []) {
        LibraryStore.shared.recordWatch(video)

        upNext = queue.filter { $0.id != video.id }
        progress.reset()
        setBuffering(true)
        issue = nil
        scrollRun = 0

        wasExpandedBeforeFullScreen = true
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            currentVideo = video
            isExpanded = true
            isBarCompact = false
            isFullScreen = isLandscape
        }

        desiredVideoId = video.id
        sync()
        // Started with the phone already on its side: hand it over as soon as the embed is up.
        if isLandscape { wantsSystemFullScreen = true }
    }

    /// Called by the surface once the web view is on screen with a real size.
    func surfaceDidAppear() {
        guard !isSurfaceOnScreen else { return }
        isSurfaceOnScreen = true
        sync()
    }

    /// Hands the desired video to the web view as soon as it is in a state to accept it.
    private func sync() {
        guard isSurfaceOnScreen, let desired = desiredVideoId else { return }

        if !isShellLoaded {
            guard !isLoadingShell else { return }
            isLoadingShell = true
            loadedVideoId = desired
            loadShell(initialVideoId: desired)
            startWatchdog()
        } else if loadedVideoId != desired {
            loadedVideoId = desired
            evaluate("setVideo('\(desired)')")
        }
    }

    /// If the page never reports back, say so rather than leaving a black player.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, !self.isShellLoaded else { return }
            self.issue = .noResponse
            self.setBuffering(false)
        }
    }

    /// Reported by the navigation delegate when the page itself fails to load.
    func handleLoadFailure(_ message: String) {
        guard !isShellLoaded else { return }
        isLoadingShell = false
        setBuffering(false)
        issue = .loadFailed(message)
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
        let duration = progress.duration
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        progress.currentTime = target
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
        exitSystemFullScreen()
        evaluate("stopVideo()")
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            isExpanded = false
            currentVideo = nil
            isBarCompact = false
            isFullScreen = false
        }
        upNext = []
        isPlaying = false
        progress.reset()
        scrollRun = 0
    }

    func expand() {
        scrollRun = 0
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            isExpanded = true
            isBarCompact = false
        }
    }

    // MARK: - Full screen

    /// Turning the phone on its side plays the video full screen on its own — no button to find,
    /// the way the YouTube app does it — and turning it back puts the player where it was.
    /// Driven by the container, which is where the size class is known.
    ///
    /// Full screen means the system's own: the page is asked to hand the video to iOS, which
    /// presents it over the app with the system's controls. The layout below is what is left if
    /// that request is refused, and what the video comes back to when it is dismissed.
    func setLandscape(_ landscape: Bool) {
        guard isLandscape != landscape else { return }
        isLandscape = landscape
        guard currentVideo != nil else { return }

        scrollRun = 0
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            if landscape {
                wasExpandedBeforeFullScreen = isExpanded
                isExpanded = true
                isBarCompact = false
            } else {
                isExpanded = wasExpandedBeforeFullScreen
            }
            isFullScreen = landscape
        }

        if landscape {
            requestSystemFullScreen()
        } else {
            exitSystemFullScreen()
        }
    }

    private func requestSystemFullScreen() {
        guard currentVideo != nil else { return }
        wantsSystemFullScreen = true
        startFullScreenRequest()
    }

    /// Asks the page to hand the video over, and keeps asking for a couple of seconds.
    ///
    /// Two reasons it takes more than one ask, and the same answer to both: the embed has no
    /// video element to give until it has booted, and WebKit only grants full screen to a script
    /// running under a user gesture — which a script the app evaluates has, and a timer inside
    /// the page does not. So every attempt is a fresh call from here. The last one settles for
    /// the lesser full screen if the better one never became available.
    private func startFullScreenRequest() {
        guard wantsSystemFullScreen, isShellLoaded, !isSystemFullScreen else { return }
        fullScreenRequest?.cancel()
        fullScreenRequest = Task { [weak self] in
            let attempts = 8
            for attempt in 0..<attempts {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                guard !Task.isCancelled, let self else { return }
                guard self.wantsSystemFullScreen, !self.isSystemFullScreen else { return }
                self.evaluate("enterFullScreen(\(attempt == attempts - 1))")
            }
        }
    }

    private func exitSystemFullScreen() {
        wantsSystemFullScreen = false
        fullScreenRequest?.cancel()
        fullScreenRequest = nil
        guard isShellLoaded else { return }
        evaluate("exitFullScreen()")
    }

    /// Reported by the page, and by WebKit itself, whenever the system's full-screen window
    /// opens or closes. Dismissing it by hand while the phone is still on its side leaves the
    /// app's own landscape layout showing — the player doesn't snap back to portrait, and
    /// nothing asks for full screen again until the phone is turned and turned back.
    private func setSystemFullScreen(_ active: Bool) {
        guard isSystemFullScreen != active else { return }
        isSystemFullScreen = active
        wantsSystemFullScreen = false
        fullScreenRequest?.cancel()
        fullScreenRequest = nil
    }

    // MARK: - The size of the docked bar

    /// How far you have to scroll down before the bar shrinks to its pill. The tab bar
    /// underneath reacts to the first few points of a scroll, and the two have to move together,
    /// so this is only wide enough to ignore a jittery finger — not to add a delay of its own.
    private static let compactThreshold: CGFloat = 6
    /// A scroll view settles a fraction of a point away from zero; anything inside this still
    /// counts as the top.
    private static let topTolerance: CGFloat = 0.5
    /// Downward scroll travelled since the bar was last full size.
    private var scrollRun: CGFloat = 0

    /// Fed by every screen's scroll view: scrolling down shrinks the bar to its pill, and
    /// scrolling back to the *top* brings it back — which is the rule the tab bar underneath
    /// follows. Scrolling up part-way leaves both of them small, so the two never disagree.
    func scrollDidMove(from previous: CGFloat, to current: CGFloat) {
        guard currentVideo != nil, !isExpanded else { return }

        // The top, and only the top, is what restores the bar.
        guard current > Self.topTolerance else {
            scrollRun = 0
            setBarCompact(false)
            return
        }

        let delta = current - previous
        guard delta > 0.5 else { return }

        scrollRun = min(Self.compactThreshold, scrollRun + delta)
        if scrollRun >= Self.compactThreshold {
            setBarCompact(true)
        }
    }

    private func setBarCompact(_ compact: Bool) {
        guard isBarCompact != compact else { return }
        // `.snappy` is the system's own preset for chrome that jumps between two states, which
        // is the closest we can get to the curve the tab bar minimizes on: its state isn't
        // published, so the two are kept in step by reacting to the same scroll on the same
        // frame rather than by sharing an animation.
        withAnimation(.snappy) {
            isBarCompact = compact
        }
    }

    func collapse() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            isExpanded = false
        }
    }

    // MARK: - Events from the web player

    func handle(_ event: PlayerEvent) {
        if let duration = event.duration, duration > 0, progress.duration != duration {
            progress.duration = duration
        }

        switch event.type {
        case "ready":
            isShellLoaded = true
            isLoadingShell = false
            watchdog?.cancel()
            issue = nil
            sync()
            startFullScreenRequest()

        case "error":
            setBuffering(false)
            if let code = event.state { issue = .playerError(code) }

        case "fullscreen":
            setSystemFullScreen(event.state == 1)

        case "state":
            // YT.PlayerState: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued
            guard let state = event.state else { return }
            setPlaying(state == 1)
            setBuffering(state == 3)
            // Replaying the same video reloads nothing, so there is no `ready` to wait for; the
            // moment it starts is the other chance to hand it over.
            if state == 1 { startFullScreenRequest() }
            if state == 0 { playNext() }

        case "time":
            // Ignore the sub-frame jitter the embed reports between real ticks.
            if let time = event.time, abs(time - progress.currentTime) > 0.05 {
                progress.currentTime = time
            }

        default:
            break
        }
    }

    /// The embed repeats its state with every position report, and assigning an unchanged
    /// `@Published` value still redraws every view watching the player — several times a second.
    private func setPlaying(_ playing: Bool) {
        if isPlaying != playing { isPlaying = playing }
    }

    private func setBuffering(_ buffering: Bool) {
        if isBuffering != buffering { isBuffering = buffering }
    }

    // MARK: - Web view plumbing

    private func evaluate(_ javaScript: String) {
        webView.evaluateJavaScript(javaScript, completionHandler: nil)
    }

    private func loadShell(initialVideoId: String) {
        isShellLoaded = false
        let html = Self.shellHTML.replacingOccurrences(of: "__VIDEO_ID__", with: initialVideoId)

        // The base URL matches the iframe's host, exactly as in the version that played fine.
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
    }

    /// A plain `youtube-nocookie.com/embed` iframe — the same embed that plays reliably in a
    /// `WKWebView`. Control and state ride on the embed's `enablejsapi` postMessage protocol, so
    /// nothing depends on loading YouTube's IFrame API script into a `loadHTMLString` document,
    /// whose origin the API rejects (playback failed with error 152).
    ///
    /// `rel=1` matters more than it looks: `rel=0` confines the end screen to more from the same
    /// channel, while `rel=1` leaves YouTube's own related videos there. Since the Data API
    /// retired every recommendation endpoint it had, that panel is the one place in the app
    /// where YouTube's real suggestions show up.
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
        src="https://www.youtube-nocookie.com/embed/__VIDEO_ID__?enablejsapi=1&playsinline=1&rel=1&modestbranding=1&controls=1"
        allow="accelerometer; autoplay; encrypted-media; fullscreen; gyroscope; picture-in-picture"
        allowfullscreen>
      </iframe>
      <script>
        var frame = document.getElementById('frame');
        var handshake;
        var watchedVideo;

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
          watchedVideo = null;
          frame.src = 'https://www.youtube-nocookie.com/embed/' + id +
            '?enablejsapi=1&playsinline=1&rel=1&modestbranding=1&controls=1';
        }

        // Full screen, in the two forms iOS offers, best first.
        //
        // The embed's own video element, when it can be reached, goes to the *system's* video
        // player: iOS draws the transport, the AirPlay and picture-in-picture buttons and the
        // Done button itself, which is the full screen the phone gives every other video. When
        // it can't be reached, the iframe goes into WebKit's element full screen instead —
        // still a real full-screen window over the app, drawn by the system, but with the
        // embed's own controls inside it.

        function embedDocument() {
          try { return frame.contentDocument || null; } catch (e) { return null; }
        }

        function videoElement() {
          var doc = embedDocument();
          return doc ? doc.querySelector('video') : null;
        }

        function reportFullScreen(active) {
          post({ type: 'fullscreen', state: active ? 1 : 0 });
        }

        // The system player reports its own comings and goings on the video element; the app
        // needs them to know when Done was tapped.
        function watch(video) {
          if (watchedVideo === video) { return; }
          watchedVideo = video;
          video.addEventListener('webkitbeginfullscreen', function () { reportFullScreen(true); });
          video.addEventListener('webkitendfullscreen', function () { reportFullScreen(false); });
        }

        function enterElementFullScreen() {
          var request = frame.requestFullscreen || frame.webkitRequestFullscreen;
          if (!request) { return; }
          try { request.call(frame); } catch (e) {}
        }

        // `mayFallBack` is the app's last ask of a run: settle for the iframe's full screen
        // rather than leave the video where it is.
        function enterFullScreen(mayFallBack) {
          var video = videoElement();
          if (video && typeof video.webkitEnterFullscreen === 'function') {
            watch(video);
            if (video.webkitDisplayingFullscreen) { return; }
            try { video.webkitEnterFullscreen(); return; } catch (e) {}
          }
          // An embed we can't see into will never hand over its video element, so there is
          // nothing to wait for. One we can see into is still booting, and the app asks again
          // in a moment.
          if (mayFallBack || !embedDocument()) { enterElementFullScreen(); }
        }

        function exitFullScreen() {
          var video = watchedVideo || videoElement();
          if (video && video.webkitDisplayingFullscreen) {
            try { video.webkitExitFullscreen(); } catch (e) {}
            return;
          }
          var exit = document.exitFullscreen || document.webkitExitFullscreen;
          if (exit && (document.fullscreenElement || document.webkitFullscreenElement)) {
            try { exit.call(document); } catch (e) {}
          }
        }

        function fullScreenDidChange() {
          reportFullScreen(!!(document.fullscreenElement || document.webkitFullscreenElement));
        }

        document.addEventListener('fullscreenchange', fullScreenDidChange);
        document.addEventListener('webkitfullscreenchange', fullScreenDidChange);

        // The embed only starts reporting state once we introduce ourselves; it can miss the
        // first few messages while it boots, so repeat briefly.
        frame.addEventListener('load', function () {
          clearInterval(handshake);
          watchedVideo = null;
          var attempts = 0;
          handshake = setInterval(function () {
            send({ event: 'listening', id: 'frame', channel: 'widget' });
            if (attempts === 2) { command('playVideo'); }
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
          } else if (data.event === 'onError') {
            post({ type: 'error', state: data.info });
          } else if (data.event === 'infoDelivery' && data.info) {
            var info = data.info;
            if (typeof info.playerState === 'number') {
              post({ type: 'state', state: info.playerState, duration: info.duration || 0 });
            }
            if (typeof info.currentTime === 'number') {
              post({ type: 'time', time: info.currentTime, duration: info.duration || 0 });
            }
            if (typeof info.errorCode === 'number' && info.errorCode) {
              post({ type: 'error', state: info.errorCode });
            }
          }
        });

        function resume() { command('playVideo'); }
        function pauseVideo() { command('pauseVideo'); }
        function seekTo(seconds) { command('seekTo', [seconds, true]); }
        function stopVideo() { watchedVideo = null; frame.src = 'about:blank'; }
      </script>
    </body>
    </html>
    """
}
