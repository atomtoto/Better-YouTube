import AVFoundation
import Foundation
import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// One event coming back from the embedded player. Kept to primitives so it can cross actor
/// boundaries from the script-message handler.
struct PlayerEvent: Sendable {
    let type: String
    let time: Double?
    let duration: Double?
    let state: Int?
    let videoID: String?
    let playbackID: String?
    /// The settings the player offers, as JSON, or the video the embed moved on to.
    let payload: String?
}

/// Where the picture is coming from.
///
/// Decided per video, not per screen: anything with a file in the Downloads folder plays from
/// that file, and everything else from YouTube's embed. Since the choice is made in `play`, a
/// downloaded video plays from the file wherever it was tapped — Watch Later, history, search, a
/// playlist, the up-next queue — with no screen having to know it was downloaded.
enum PlaybackSource: Equatable {
    case embed
    case local(URL)
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

/// The player's web view. It never sees the screen's safe area: the player places it, and full
/// screen with the video zoomed to fill, a web view that knew it lay under the notch moved its
/// picture aside by the notch's width.
final class PlayerWebView: WKWebView {
    #if os(iOS)
    override var safeAreaInsets: UIEdgeInsets { .zero }
    #endif
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
        if type == "pipFrame" {
            PlayerManager.shared.pictureInPictureFrame = message.frameInfo
            return
        }
        if type == "pip" {
            #if os(iOS)
            let active = body["active"] as? Bool ?? false
            Task { @MainActor in PlayerManager.shared.embedPictureInPictureDidChange(active) }
            #endif
            return
        }

        let event = PlayerEvent(
            type: type,
            time: body["time"] as? Double,
            duration: body["duration"] as? Double,
            state: body["state"] as? Int,
            videoID: body["videoID"] as? String,
            playbackID: body["playbackID"] as? String,
            payload: body["payload"] as? String
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
/// The embed only plays the video: its own controls are hidden under the app's, which drive it —
/// over postMessage for the transport, and through the embed's player object for what YouTube's
/// gear menu offers (quality, captions, audio track, speed). The same controls drive a downloaded
/// file, so the player looks and behaves the same whichever of the two is playing.
@MainActor
final class PlayerManager: ObservableObject {
    /// The one player. A screen that only tells it what to play reaches it here rather than
    /// observing it: observed, the screen is drawn again with every change to the player —
    /// several a second while the docked bar follows the tab bar, in the middle of a scroll.
    /// Observe it only to show what it is doing.
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
    @Published private(set) var isFullScreen = false {
        didSet { if isFullScreen != oldValue { updateControls() } }
    }
    /// True while *iOS* is the one showing the video full screen — its own full-screen
    /// presentation over the app, with the system's controls — rather than the app laying the
    /// video out edge to edge itself. `isFullScreen` is that fallback, and stays true underneath.
    @Published private(set) var isSystemFullScreen = false
    /// Position and duration, published apart from everything else because they tick constantly.
    let progress = PlaybackProgress()
    /// Quality, captions, audio tracks, speed and chapters, published apart for the same reason.
    let options = PlaybackOptions()
    /// The speed chosen in the player's menu, kept for the next videos as the YouTube app does.
    private var preferredRate: Double = 1
    /// The playback the preferred speed has been handed to.
    private var rateAppliedPlaybackID: String?
    /// Set whenever playback fails to start, so the UI can say what happened instead of
    /// showing a silent black rectangle.
    @Published private(set) var issue: PlaybackIssue?
    /// Which of the two players is live. Watched by the container, which swaps the surface.
    @Published private(set) var source: PlaybackSource = .embed {
        didSet { if source != oldValue { updateControls() } }
    }
    /// Whose controls are over the video now — Settings → Playback → Player, as far as it can
    /// apply. Full screen on an iPhone or an iPad is the Full-Screen Player's to decide, and
    /// YouTube's controls can't drive a downloaded file, which keeps the app's.
    @Published private(set) var controls = PlayerManager.controls(
        chosen: .stored, isFullScreen: false, isLocal: false
    )
    @Published private(set) var isAudioOnly = false
    @Published private(set) var isCarPlayVideoPlayback = false
    private(set) var isCarPlayConnected = false
    private var carPlaySupportsVideo = false
    private var carPlayPrefersVideo = false
    /// The car went while the app was out of sight: the sound is still on the native player,
    /// and the phone has yet to take the picture back.
    private var carPlayStreamPendingPicture = false
    private var usesNativeCarPlayPlayback: Bool { isAudioOnly || isCarPlayVideoPlayback }
    private var audioStreamTask: Task<Void, Never>?
    private var audioShouldPlay = true
    private let resolveAudio: @Sendable (String) async throws -> URL
    private let resolveVideo: @Sendable (String) async throws -> URL
    private let downloadedMediaURL: @MainActor (String) -> URL?

    /// Made on first use rather than at launch. Creating it — and the web content process
    /// behind it — was the largest single cost of starting the app, paid even when nothing
    /// was ever played. The container asks for it once there is something to show. Made again
    /// only after WebKit got stuck — see `rebuildWebView`.
    var webView: WKWebView {
        if let currentWebView { return currentWebView }
        let made = makeWebView()
        currentWebView = made
        return made
    }
    private var currentWebView: WKWebView?
    /// Whether `webView` exists yet. Once it does, its surface stays in the container for good,
    /// as it always has: the loading logic below counts on a surface that never goes away.
    private(set) var hasWebView = false
    /// The other player. Both exist for the app's lifetime; `source` says which one is live.
    let local = LocalPlayback()
    var pictureInPictureFrame: WKFrameInfo?
    @Published var pictureInPictureError: String?

    func startPictureInPicture() {
        if isLocal {
            if !local.startPictureInPicture() {
                pictureInPictureError = String(localized: "Picture in Picture isn't available for this video right now.")
            }
            return
        }
        requestPictureInPicture(reportsFailure: true)
    }

    private func requestPictureInPicture(reportsFailure: Bool) {
        guard let frame = pictureInPictureFrame else {
            if reportsFailure {
                pictureInPictureError = String(localized: "Wait for the YouTube video to load before starting Picture in Picture.")
            }
            return
        }
        webView.callAsyncJavaScript("""
        const video = document.querySelector('video');
        if (!video) throw new Error('Video is not ready.');
        if (video.webkitPresentationMode === 'picture-in-picture' || document.pictureInPictureElement === video)
            return;
        if (video.webkitSupportsPresentationMode?.('picture-in-picture')) {
            video.webkitSetPresentationMode('picture-in-picture');
        } else if (document.pictureInPictureEnabled && video.requestPictureInPicture) {
            await video.requestPictureInPicture();
        } else { throw new Error('YouTube does not allow Picture in Picture for this video.'); }
        """, arguments: [:], in: frame, in: .page) { [weak self] result in
            guard reportsFailure, case .failure(let error) = result else { return }
            // WebKit reports a thrown script error as "A JavaScript exception occurred"; the
            // script's own message is what says which of its two refusals this was.
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
            self?.pictureInPictureError = message.contains("not ready")
                ? String(localized: "Wait for the YouTube video to load before starting Picture in Picture.")
                : String(localized: "YouTube doesn't allow Picture in Picture for this video.")
        }
    }

    /// True while AVPlayer is active, for either a downloaded file or a background stream.
    var isLocal: Bool {
        if case .local = source { return true }
        return false
    }

    private let bridge = PlayerScriptBridge()
    private let navigationBridge = PlayerNavigationBridge()
    private var watchdog: Task<Void, Never>?
    /// The video that should be playing, and the one the web view actually has.
    private var desiredVideoId: String?
    private var loadedVideoId: String?
    private var playbackID: String?
    private var loadedPlaybackID: String?
    private var pendingSeekTime: Double?
    private var isRestoringPosition = false
    private var playbackDidEnd = false
    private var lastRecordedPosition: PlaybackPosition?
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
    /// The streamed video's sound alone, resolved while the app is on screen. It is used only
    /// once the app is in the background, where WebKit can't play: on screen the embed plays.
    private var backgroundAudioTask: Task<Void, Never>?
    private var backgroundAudioURL: URL?
    private var backgroundAudioIndex: StreamIndex?
    /// Set when the app went to the background before that sound was resolved: it takes over as
    /// soon as it arrives.
    private var backgroundAudioRequested = false
    /// The file player is carrying a streamed video's sound while the app is away, and the embed
    /// takes the video back when the app returns.
    private var isBackgroundAudio = false
    /// Whether the embed asks to start playing as it loads. Off only when a paused video comes
    /// back from the background.
    private var embedStartsPlaying = true
    /// Whether the embed starts muted: coming back from the background, while the native player
    /// still carries the sound.
    private var embedStartsMuted = false
    /// From the app's return until the embed plays again, the native player carrying the sound
    /// in the meantime — see `finishReturnToEmbed`.
    private var isReturningToEmbed = false
    private var returnTimeout: Task<Void, Never>?
    /// WebKit holds all of the page's media while the native player has the sound.
    private var isEmbedMediaSuspended = false
    #if os(iOS)
    /// From the moment the app leaves the screen until it is back.
    private var isInBackground = false
    /// Picture in Picture the app started by itself on the way out, put back when it returns.
    private var startedPictureInPictureOnLeaving = false
    /// Whether the video was playing as the app began to leave. WebKit pauses the embed on the
    /// way out, and on an iPhone its report of that can arrive before the app is told it is in
    /// the background — which used to read as a video paused on purpose, and nothing carried on.
    private var wasPlayingOnLeaving = false
    /// Whether the embed's video is in its Picture in Picture window, as WebKit reports it.
    private var isEmbedInPictureInPicture = false
    /// When the embed last stopped playing. The lock pauses a Picture in Picture window a moment
    /// before closing it, which is how that pause is told from one made in the window.
    private var embedPausedAt: Date?
    /// The embed's Picture in Picture window closed with the app away — see `rebuildWebView`.
    private var pictureInPictureEndedAway = false
    /// Keeps the app running while the sound moves from the embed to the file player.
    private var handoffTask: UIBackgroundTaskIdentifier = .invalid
    /// Where the sound starts from in the file player, while the handoff is under way.
    private var handoffStartPosition: Double?
    #endif
    #if os(macOS)
    /// The window the player took full screen, to give back when the video leaves it. A window
    /// that was full screen already stays so.
    private weak var fullScreenWindow: NSWindow?
    #endif
    private var lifecycleObservers: [NSObjectProtocol] = []

    init(resolveAudio: @escaping @Sendable (String) async throws -> URL = {
        try await LocalDownloadResolver.shared.resolveAudioPlaybackURL(videoID: $0)
    }, resolveVideo: @escaping @Sendable (String) async throws -> URL = {
        try await LocalDownloadResolver.shared.resolvePlaybackURL(videoID: $0)
    }, downloadedMediaURL: @escaping @MainActor (String) -> URL? = {
        DownloadStore.shared.readyMediaURL(for: $0)
    }) {
        self.resolveAudio = resolveAudio
        self.resolveVideo = resolveVideo
        self.downloadedMediaURL = downloadedMediaURL
        wireLocalPlayback()
        observeAppLifecycle()
    }

    isolated deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        #if os(iOS)
        // A Mac never plays video anywhere but inline, so there is nothing to ask for there.
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        #endif
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Lets the page hand the video to the system's full-screen presentation, which is what
        // turning the phone now does. Without it WebKit refuses the request and all the app can
        // do is draw an imitation of full screen itself.
        configuration.preferences.isElementFullscreenEnabled = true

        let controller = WKUserContentController()
        configuration.userContentController = controller
        controller.addUserScript(WKUserScript(source: """
        document.addEventListener('loadedmetadata', function(event) {
            if (event.target instanceof HTMLVideoElement)
                window.webkit.messageHandlers.player.postMessage({type: 'pipFrame'});
        }, true);
        function reportPictureInPicture(event) {
            if (!(event.target instanceof HTMLVideoElement)) return;
            var active = event.target.webkitPresentationMode === 'picture-in-picture' ||
                document.pictureInPictureElement === event.target;
            window.webkit.messageHandlers.player.postMessage({type: 'pip', active: active});
        }
        document.addEventListener('webkitpresentationmodechanged', reportPictureInPicture, true);
        document.addEventListener('enterpictureinpicture', reportPictureInPicture, true);
        document.addEventListener('leavepictureinpicture', reportPictureInPicture, true);
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        let webView = PlayerWebView(frame: .zero, configuration: configuration)
        // Black behind the page, so the letterboxing around a video that isn't the surface's
        // shape reads as part of the picture rather than as a gap. `underPageBackgroundColor`
        // is the one spelling both platforms share; the scroll view below is iOS's alone.
        webView.underPageBackgroundColor = .black
        #if os(iOS)
        webView.scrollView.isScrollEnabled = false
        // The page fills the web view to its edges. Inset by the safe area, as a web view is by
        // default, the video shrank inside its own frame full screen, short of the home indicator.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.backgroundColor = .black
        webView.backgroundColor = .black
        webView.isOpaque = false
        #endif

        controller.add(bridge, name: "player")
        webView.navigationDelegate = navigationBridge

        // Whatever opens or closes the system's full-screen window — a rotation, the embed's own
        // full-screen button, the Done button over the video — WebKit reports it here, so the
        // app's idea of the state never drifts from what is on screen.
        fullScreenObserver = webView.observe(\.fullscreenState, options: [.new]) { _, change in
            let active = change.newValue == .inFullscreen
            Task { @MainActor in PlayerManager.shared.setSystemFullScreen(active) }
        }

        hasWebView = true
        return webView
    }

    /// Points the file player's reports at the same state the embed's bridge feeds, so everything
    /// above — the mini bar, the scrubber, the lock screen, the up-next queue — carries on
    /// working without knowing which player is behind it.
    private func wireLocalPlayback() {
        #if os(iOS)
        local.onFullScreenChanged = { [weak self] active in
            guard let self, self.isLocal else { return }
            self.setSystemFullScreen(active)
        }
        #endif
        local.onProgress = { [weak self] elapsed, duration in
            guard let self, self.isLocal else { return }
            self.updatePlaybackProgress(elapsed: elapsed, duration: duration)
            #if os(iOS)
            // The sound is really coming out once the position moves past where it started: the
            // app can be left to iOS's audio rules now. The player says it is playing as soon as
            // it is asked, long before it has anything to play — ending the handoff there let iOS
            // suspend the app while the stream was still loading, and the sound never came back.
            if let start = self.handoffStartPosition, elapsed > start + 0.3,
               self.local.player.timeControlStatus == .playing {
                // Playing now, the app may take the sound for itself again — which is what puts
                // it back in charge of the lock screen and headphones.
                if NowPlaying.shared.isMixing { NowPlaying.shared.begin() }
                self.endHandoffTask()
            }
            #endif
        }

        local.onPlayingChanged = { [weak self] playing in
            guard let self, self.isLocal else { return }
            self.setPlaying(playing)
            if playing { self.setBuffering(false) }
        }

        local.onBufferingChanged = { [weak self] buffering in
            guard let self, self.isLocal else { return }
            self.setBuffering(buffering)
        }

        local.onEnded = { [weak self] in
            guard let self, self.isLocal else { return }
            self.finishPlayback()
            self.advanceAfterEnd()
        }

        local.onMediaOptions = { [weak self] audioTracks, audioTrack, captions, caption in
            guard let self, self.isLocal else { return }
            self.options.applyLocal(audioTracks: audioTracks, audioTrack: audioTrack,
                                    captions: captions, caption: caption)
        }

        local.onFailure = { [weak self] message in
            guard let self, self.isLocal else { return }
            self.local.pause()
            self.setBuffering(false)
            self.issue = .loadFailed(message)
            #if os(iOS)
            self.endHandoffTask()
            #endif
        }
    }

    // MARK: - Playback

    /// Starts a video and expands the player. `upNext` becomes the auto-play queue.
    ///
    /// `startTime` is a moment asked for explicitly — a shared link's `t=`, a timestamp tapped
    /// in a description — and wins over the position saved for the video.
    func play(_ video: Video, upNext queue: [Video] = [], audioOnly: Bool = false,
              carPlayVideo: Bool = false, startTime: TimeInterval? = nil) {
        finishReturnToEmbed()
        savePlaybackPosition()
        audioStreamTask?.cancel()
        audioStreamTask = nil
        isCarPlayVideoPlayback = !audioOnly && (carPlayVideo || (isCarPlayConnected && carPlaySupportsVideo))
        carPlayPrefersVideo = isCarPlayVideoPlayback
        isAudioOnly = audioOnly || (isCarPlayConnected && !isCarPlayVideoPlayback)
        audioShouldPlay = true
        LibraryStore.shared.recordWatch(video)

        upNext = queue.filter { $0.id != video.id }
        progress.reset()
        options.reset(chapters: DescriptionChapters.parse(video.description), rate: preferredRate)
        rateAppliedPlaybackID = nil
        let savedPosition = PlaybackPositionStore.shared.position(for: video.id)
        let requestedStart = startTime.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        progress.currentTime = requestedStart ?? savedPosition?.seconds ?? 0
        progress.duration = savedPosition?.duration ?? 0
        lastRecordedPosition = PlaybackPosition(seconds: progress.currentTime, duration: progress.duration)
        pendingSeekTime = requestedStart ?? savedPosition?.seconds
        // Only a restored position may turn out to be the end of the video and start over; a
        // requested moment is taken at its word.
        isRestoringPosition = requestedStart == nil && savedPosition != nil
        playbackDidEnd = false
        playbackID = UUID().uuidString
        setBuffering(true)
        issue = nil
        scrollRun = 0

        wasExpandedBeforeFullScreen = true
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            currentVideo = video
            isExpanded = !usesNativeCarPlayPlayback
            isBarCompact = false
            isFullScreen = isLandscape && !usesNativeCarPlayPlayback
        }

        isBackgroundAudio = false
        embedStartsPlaying = true

        // The one decision that makes a download worth having: if the file is here, play it.
        // `readyMediaURL` checks the disk as well as the manifest, so a download deleted behind
        // the app's back falls back to streaming rather than playing a black rectangle.
        if let file = downloadedMediaURL(video.id) {
            startLocal(file)
        } else if usesNativeCarPlayPlayback {
            startCarPlayStream(video.id)
        } else if playsInBackground {
            // The next video of the queue, or one asked for from the lock screen, while the app
            // is away: WebKit can't play there, so the sound starts on its own.
            startBackgroundAudio(video.id)
        } else {
            startEmbed(video.id)
        }

        // Claim the audio session now, so leaving the app doesn't take the sound with it.
        NowPlaying.shared.begin()
        refreshNowPlaying()
    }

    /// CarPlay can launch without an iPhone window, so never depend on the embed's surface.
    func setCarPlayConnected(_ connected: Bool, supportsVideo: Bool = false) {
        isCarPlayConnected = connected
        carPlaySupportsVideo = connected && supportsVideo
        guard connected else {
            carPlayDisconnected()
            return
        }
        guard let video = currentVideo else { return }
        guard !usesNativeCarPlayPlayback || carPlayPrefersVideo != supportsVideo else { return }
        let wasAudioOnly = isAudioOnly
        let shouldPlay = isPlaying
        isCarPlayVideoPlayback = supportsVideo
        carPlayPrefersVideo = supportsVideo
        isAudioOnly = !supportsVideo
        audioShouldPlay = shouldPlay
        exitSystemFullScreen()
        isFullScreen = false
        isExpanded = false
        #if os(iOS)
        local.setFullScreen(false)
        #endif
        if !isLocal || (wasAudioOnly && supportsVideo && downloadedMediaURL(video.id) == nil) {
            audioStreamTask?.cancel()
            startCarPlayStream(video.id)
        }
        refreshNowPlaying()
    }

    /// The car is gone: the phone takes the video back.
    ///
    /// CarPlay's shape — the phone's player collapsed, no picture, an audio-only entry on the
    /// lock screen — belongs to the car. Left as it was, the phone kept that shape long after
    /// the car had gone, and the video was nowhere to be seen.
    private func carPlayDisconnected() {
        isAudioOnly = false
        isCarPlayVideoPlayback = false
        carPlayPrefersVideo = false
        guard let video = currentVideo else { return }
        // The sound stays where it is while the app is out of sight: taking the video back
        // means loading the embed, and the car may have gone while the phone was locked. The
        // picture comes back when the app is on screen.
        #if os(iOS)
        guard !isInBackground else {
            carPlayStreamPendingPicture = true
            refreshNowPlaying()
            return
        }
        #endif
        // The phone's own player takes it from here: the file if it is on the disk, the embed
        // otherwise, at the moment the sound had reached.
        play(video, upNext: upNext, startTime: progress.currentTime)
    }

    private func startCarPlayStream(_ videoID: String) {
        issue = nil
        clearBackgroundAudio()
        if isShellLoaded { evaluate("stopVideo()") }
        local.stop()
        source = .embed
        desiredVideoId = nil
        loadedVideoId = nil
        loadedPlaybackID = nil
        watchdog?.cancel()
        exitSystemFullScreen()
        setPlaying(false)
        setBuffering(true)
        let requestID = playbackID
        let wantsVideo = isCarPlayVideoPlayback
        audioStreamTask = Task { [weak self] in
            do {
                guard let resolveAudio = self?.resolveAudio, let resolveVideo = self?.resolveVideo else { return }
                let url: URL
                if wantsVideo {
                    do { url = try await resolveVideo(videoID) }
                    catch {
                        try Task.checkCancellation()
                        // Some videos expose only a usable audio stream. Keep them listenable.
                        url = try await resolveAudio(videoID)
                        guard !Task.isCancelled, let self, self.playbackID == requestID else { return }
                        self.isCarPlayVideoPlayback = false
                        self.isAudioOnly = true
                    }
                } else { url = try await resolveAudio(videoID) }
                guard !Task.isCancelled, let self, self.playbackID == requestID else { return }
                self.audioStreamTask = nil
                self.source = .local(url)
                // CarPlay plays video through AirPlay, which needs a URL the car can fetch.
                self.local.load(url: url, ranged: !self.isCarPlayVideoPlayback)
                self.local.setRate(self.preferredRate)
                self.local.seek(to: self.progress.currentTime)
                if self.audioShouldPlay { self.local.play() }
                else { self.setBuffering(false) }
                self.refreshNowPlaying()
            } catch {
                guard !Task.isCancelled, let self, self.playbackID == requestID else { return }
                self.audioStreamTask = nil
                self.setBuffering(false)
                self.issue = .loadFailed(error.localizedDescription)
            }
        }
    }

    /// Hands over to the file player, and quiets the embed — two soundtracks at once is the
    /// failure mode here, and it is not a subtle one.
    private func startLocal(_ file: URL) {
        clearBackgroundAudio()
        if isShellLoaded { evaluate("stopVideo()") }
        desiredVideoId = nil
        loadedVideoId = nil
        watchdog?.cancel()
        wantsSystemFullScreen = false
        fullScreenRequest?.cancel()
        fullScreenRequest = nil

        source = .local(file)
        local.load(url: file)
        local.setRate(preferredRate)
        local.seek(to: progress.currentTime)
        local.play()
        #if os(iOS)
        // If playback starts while the phone is already on its side, setLandscape has already
        // run. Queue the request here so AVKit still presents the same true full-screen player.
        local.setFullScreen(isLandscape && !usesNativeCarPlayPlayback && usesSystemFullScreen)
        #endif
    }

    private func startEmbed(_ videoId: String) {
        clearBackgroundAudio()
        let wasLocal = isLocal
        source = .embed
        if wasLocal { local.stop() }

        desiredVideoId = videoId
        sync()
        resolveBackgroundAudio(for: videoId)
        // Started with the phone already on its side: hand it over as soon as the embed is up.
        if isLandscape && usesSystemFullScreen { wantsSystemFullScreen = true }
    }

    /// Resolves the video's sound alone ahead of time, so leaving the app can switch to it at
    /// once: the stream, and the index of its pieces — see `StreamIndex` — which lets the native
    /// player start anywhere in it straight away. A sound-only stream is what YouTube still
    /// offers every video — the muxed ones are gone for most — and it is all a locked phone needs.
    private func resolveBackgroundAudio(for videoID: String) {
        backgroundAudioTask?.cancel()
        backgroundAudioTask = Task { [weak self] in
            guard let resolveAudio = self?.resolveAudio,
                  let url = try? await resolveAudio(videoID) else { return }
            // Without its index the stream still plays, only slower to start.
            let index = url.isFileURL ? nil : try? await StreamIndex.load(url)
            guard !Task.isCancelled, let self,
                  self.currentVideo?.id == videoID, !self.isLocal else { return }
            self.backgroundAudioTask = nil
            self.backgroundAudioURL = url
            self.backgroundAudioIndex = index
            if self.backgroundAudioRequested {
                self.switchToBackgroundAudio(url, videoID: videoID)
            }
        }
    }

    /// Hands a streamed video's sound from the embed to the file player, where it goes on with
    /// the app in the background and the screen locked.
    private func switchToBackgroundAudio(_ url: URL, videoID: String) {
        guard !isLocal, currentVideo?.id == videoID else { return }
        backgroundAudioRequested = false
        let position = progress.currentTime
        // The embed pauses, and WebKit keeps all of the page's media suspended until the app is
        // back: the page lives on for a few seconds in the background, and YouTube's player,
        // paused on the way out, took the sound straight back from the native player. Coming back
        // loads the video again where the sound has got to. The video itself stays until then:
        // taken away while the lock was closing its Picture in Picture window, it left WebKit's
        // window for it behind, over the app, and nothing could be tapped.
        if hasWebView {
            webView.setAllMediaPlaybackSuspended(true)
            isEmbedMediaSuspended = true
        }
        if isShellLoaded { evaluate("pauseVideo()") }
        desiredVideoId = nil
        loadedVideoId = nil
        watchdog?.cancel()
        wantsSystemFullScreen = false
        fullScreenRequest?.cancel()
        fullScreenRequest = nil

        isBackgroundAudio = true
        source = .local(url)
        pendingSeekTime = position
        isRestoringPosition = false
        local.load(url: url, index: backgroundAudioIndex)
        local.setRate(preferredRate)
        local.seek(to: position)
        playBackgroundAudio()
        refreshNowPlaying()
    }

    /// Starts the sound on the native player. WebKit's playback interrupts the app's audio
    /// session while it lasts, and from the background iOS won't let the app take the sound back
    /// for itself — the session refuses to go active, "it would interrupt another app", or goes
    /// active and the player still isn't allowed to play — even once WebKit has stopped. It does
    /// let a session that mixes with other sound start, so the sound starts that way, and the
    /// session takes it for itself once it plays — see `wireLocalPlayback`.
    private func playBackgroundAudio() {
        guard isBackgroundAudio, isLocal, audioShouldPlay else { return }
        NowPlaying.shared.begin(mixing: true)
        local.play()
    }

    /// The embed plays again, muted: it takes the sound over from the native player at the moment
    /// that has got to. Also called to cut the return short — the app left again, a pause, another
    /// video — and when the embed takes too long, so the sound never ends up playing twice.
    private func finishReturnToEmbed() {
        guard isReturningToEmbed else { return }
        isReturningToEmbed = false
        returnTimeout?.cancel()
        returnTimeout = nil
        let position = local.player.currentTime().seconds
        local.stop()
        if position.isFinite, position > 0 { seek(to: position) }
        evaluate("unMute()")
    }

    /// A video started while the app is away — the next in the queue, or one asked for from the
    /// lock screen — starts straight on the file player, with its sound alone.
    private func startBackgroundAudio(_ videoID: String) {
        clearBackgroundAudio()
        if isShellLoaded { evaluate("stopVideo()") }
        if isLocal { local.stop() }
        source = .embed
        desiredVideoId = nil
        loadedVideoId = nil
        loadedPlaybackID = nil
        watchdog?.cancel()
        backgroundAudioRequested = true
        #if os(iOS)
        beginHandoffTask()
        #endif
        resolveBackgroundAudio(for: videoID)
    }

    private func clearBackgroundAudio() {
        backgroundAudioTask?.cancel()
        backgroundAudioTask = nil
        backgroundAudioURL = nil
        backgroundAudioIndex = nil
        backgroundAudioRequested = false
    }

    /// Publishes the lock screen's copy of what is playing. Called when something *jumps* — the
    /// video, the play state, the duration, a seek — and deliberately not on the position
    /// ticking: the system extrapolates that from the playback rate, several times a second
    /// more cheaply than this could hand it over.
    private func refreshNowPlaying() {
        NowPlaying.shared.update(
            video: currentVideo,
            isPlaying: isPlaying,
            elapsed: progress.currentTime,
            duration: progress.duration,
            rate: options.isSpeedingUp ? HoldToSpeedUpPreference.rate : options.rate,
            audioOnly: isAudioOnly,
            hasNext: !upNext.isEmpty
        )
    }

    /// Called by the surface once the web view is on screen with a real size.
    func surfaceDidAppear() {
        guard !isSurfaceOnScreen else { return }
        isSurfaceOnScreen = true
        sync()
    }

    /// Hands the desired video to the web view as soon as it is in a state to accept it.
    private func sync() {
        guard isSurfaceOnScreen, let desired = desiredVideoId, let playbackID else { return }
        // The page's media was suspended while the sound played elsewhere; the embed plays again.
        if isEmbedMediaSuspended {
            isEmbedMediaSuspended = false
            webView.setAllMediaPlaybackSuspended(false)
        }

        if !isShellLoaded {
            guard !isLoadingShell else { return }
            isLoadingShell = true
            loadedVideoId = desired
            loadedPlaybackID = playbackID
            loadShell(initialVideoId: desired)
            embedStartsPlaying = true
            embedStartsMuted = false
            startWatchdog()
        } else if loadedVideoId != desired || loadedPlaybackID != playbackID {
            loadedVideoId = desired
            loadedPlaybackID = playbackID
            evaluate("setVideo('\(desired)', \(progress.currentTime), '\(playbackID)', \(embedStartsPlaying), \(embedStartsMuted))")
            embedStartsPlaying = true
            embedStartsMuted = false
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
        guard !isShellLoaded, !usesNativeCarPlayPlayback else { return }
        isLoadingShell = false
        setBuffering(false)
        issue = .loadFailed(message)
    }

    /// Resolves a video ID — from a notification, a link, YouTube's own page — and plays it.
    ///
    /// The Data API supplies the title, channel and counts, but the embed needs nothing beyond
    /// the ID. So a lookup that fails — no credentials yet, the day's quota spent, no network
    /// with the file already downloaded — still plays, under whatever is already known about
    /// the video. It used to do nothing at all, which from a tapped notification looked broken.
    func open(videoId: String, fallback: Video? = nil, startTime: TimeInterval? = nil) async {
        let resolved = try? await YouTubeAPIService.shared.video(id: videoId)
        let stored = DownloadStore.shared.record(for: videoId)?.video
            ?? LibraryStore.shared.history.first { $0.id == videoId }
        // A stored copy without a channel is itself a stand-in from an earlier fallback, and
        // oEmbed can do better than it.
        let known = resolved ?? fallback ?? stored.flatMap { $0.channelId.isEmpty ? nil : $0 }
        let video: Video
        if let known {
            video = known
        } else if let embedded = await YouTubeOEmbed.video(id: videoId) {
            video = embedded
        } else {
            video = stored ?? Video(
                id: videoId,
                title: String(localized: "YouTube Video"),
                channelId: "",
                channelTitle: "",
                description: "",
                thumbnailURL: URL(string: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"),
                publishedAt: nil
            )
        }
        play(video, startTime: startTime)
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard let currentVideo else { return }
        audioShouldPlay = true
        if usesNativeCarPlayPlayback, !isLocal || (issue != nil && downloadedMediaURL(currentVideo.id) == nil) {
            if audioStreamTask == nil { startCarPlayStream(currentVideo.id) }
            return
        }
        if isLocal {
            // Play at the end of a file starts it over, as the embed's own replay does.
            if playbackDidEnd { seek(to: 0) }
            local.play()
        } else if playsInBackground {
            // Play on the lock screen for a video paused before the app left: the embed can't
            // play from there, so its sound starts on the file player.
            handOffToBackgroundAudio()
        } else {
            evaluate("resume()")
        }
        isPlaying = true
        refreshNowPlaying()
    }

    func pause() {
        finishReturnToEmbed()
        audioShouldPlay = false
        savePlaybackPosition()
        if isLocal {
            local.pause()
        } else if !usesNativeCarPlayPlayback {
            evaluate("pauseVideo()")
        }
        isPlaying = false
        refreshNowPlaying()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        finishReturnToEmbed()
        let duration = progress.duration
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        progress.currentTime = target
        pendingSeekTime = target
        isRestoringPosition = false
        playbackDidEnd = false
        lastRecordedPosition = nil // An explicit seek is a new edit, even to the same time.
        savePlaybackPosition()
        if isLocal {
            local.seek(to: target)
        } else if !usesNativeCarPlayPlayback {
            evaluate("seekTo(\(target))")
        }
        refreshNowPlaying()
    }

    /// Settings → Playback → Autoplay. On unless turned off, which is how it always behaved.
    static let autoplayKey = "autoplay_next_video"

    static var autoplaysNext: Bool {
        UserDefaults.standard.object(forKey: autoplayKey) as? Bool ?? true
    }

    /// What a video reaching its end leads to: the next in the queue, unless Autoplay is off —
    /// then the embed's own end screen, with YouTube's suggestions, stays up to choose from. In
    /// a car the queue always carries on, since picking the next one there means a screen.
    private func advanceAfterEnd() {
        // A sleep timer set for the end of this video wins over autoplay.
        if sleepTimer == .endOfVideo {
            cancelSleepTimer()
            setPlaying(false)
            refreshNowPlaying()
            return
        }
        guard Self.autoplaysNext || isCarPlayConnected else {
            setPlaying(false)
            refreshNowPlaying()
            return
        }
        playNext()
    }

    /// Puts a video first in what plays next, right after the one playing now — moving it up if
    /// it was already further down the queue. With nothing playing there is no queue to join,
    /// so the video simply starts — as it does once the current one has ended, since "after
    /// the one playing now" is then right away.
    func playAfterCurrent(_ video: Video) {
        guard let currentVideo else {
            play(video)
            return
        }
        guard currentVideo.id != video.id else { return }
        if playbackDidEnd {
            play(video, upNext: upNext)
            return
        }
        upNext.removeAll { $0.id == video.id }
        upNext.insert(video, at: 0)
        refreshNowPlaying()
    }

    /// Whether the video already plays next: it is playing now, or first in the queue.
    func playsNext(_ video: Video) -> Bool {
        currentVideo?.id == video.id || upNext.first?.id == video.id
    }

    func playNext() {
        guard !upNext.isEmpty else {
            isPlaying = false
            return
        }
        var queue = upNext
        let next = queue.removeFirst()
        play(next, upNext: queue, audioOnly: isAudioOnly && !carPlayPrefersVideo,
             carPlayVideo: carPlayPrefersVideo)
    }

    // MARK: - Sleep timer

    /// When playback stops by itself, for listening in bed: after a set time, or once the video
    /// playing now ends instead of going on to the next.
    enum SleepTimer: Equatable {
        case at(Date)
        case endOfVideo
    }

    @Published private(set) var sleepTimer: SleepTimer?
    private var sleepTask: Task<Void, Never>?

    func setSleepTimer(minutes: Int) {
        sleepTask?.cancel()
        sleepTimer = .at(.now.addingTimeInterval(TimeInterval(minutes * 60)))
        sleepTask = Task { [weak self] in
            // The continuous clock keeps counting while the device sleeps, which is the point.
            try? await Task.sleep(for: .seconds(minutes * 60), clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.cancelSleepTimer()
            if self.isPlaying { self.pause() }
        }
    }

    func setSleepTimerToEndOfVideo() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimer = .endOfVideo
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimer = nil
    }

    func close() {
        finishReturnToEmbed()
        cancelSleepTimer()
        savePlaybackPosition()
        audioStreamTask?.cancel()
        audioStreamTask = nil
        isAudioOnly = false
        isCarPlayVideoPlayback = false
        carPlayPrefersVideo = false
        carPlayStreamPendingPicture = false
        playbackID = nil
        desiredVideoId = nil
        loadedVideoId = nil
        loadedPlaybackID = nil
        pendingSeekTime = nil
        isRestoringPosition = false
        watchdog?.cancel()
        clearBackgroundAudio()
        isBackgroundAudio = false
        embedStartsPlaying = true
        exitSystemFullScreen()
        NowPlaying.shared.end()
        if isLocal {
            local.stop()
        } else {
            evaluate("stopVideo()")
        }
        source = .embed
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

    // MARK: - Leaving the app

    /// Settings → Playback → Background Playback, and only while the app is away.
    private var playsInBackground: Bool {
        #if os(iOS)
        isInBackground && BackgroundPlaybackPreference.isEnabled
        #else
        false
        #endif
    }

    /// Moves a streamed video's sound to the file player, now if its stream is resolved,
    /// otherwise as soon as it is.
    private func handOffToBackgroundAudio() {
        guard let videoID = currentVideo?.id, !isLocal, !usesNativeCarPlayPlayback else { return }
        #if os(iOS)
        beginHandoffTask()
        #endif
        if let url = backgroundAudioURL {
            switchToBackgroundAudio(url, videoID: videoID)
        } else {
            backgroundAudioRequested = true
            if backgroundAudioTask == nil { resolveBackgroundAudio(for: videoID) }
        }
    }

    /// What the player follows from outside: Settings → Playback → Player changing under a video,
    /// and the app's own lifecycle. The app runs on scenes, so the application delegate's
    /// `applicationWillResignActive` and its siblings are never called — which is why handing the
    /// sound over from there never happened. On a Mac, the window leaving full screen by itself —
    /// Esc, the green button — takes the video out of it too.
    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        typealias Event = (Notification.Name, @MainActor @Sendable (PlayerManager) -> Void)
        let settings: [Event] = [
            (UserDefaults.didChangeNotification, { $0.updateControls() }),
        ]
        #if os(iOS)
        let platform: [Event] = [
            (UIApplication.willResignActiveNotification, { $0.appWillResignActive() }),
            (UIApplication.didEnterBackgroundNotification, { $0.appDidEnterBackground() }),
            (UIApplication.willEnterForegroundNotification, { $0.appWillEnterForeground() }),
            (UIApplication.didBecomeActiveNotification, { $0.appDidBecomeActive() }),
        ]
        #else
        let platform: [Event] = [
            (NSWindow.didExitFullScreenNotification, { $0.windowDidExitFullScreen() }),
        ]
        #endif
        let events = settings + platform
        lifecycleObservers = events.map { name, action in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    action(self)
                }
            }
        }
        #if os(iOS)
        lifecycleObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo
            let ended = (info?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
            let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                self?.audioSessionInterruptionChanged(ended: ended, shouldResume: options.contains(.shouldResume))
            }
        })
        #endif
    }

    #if os(iOS)
    /// A call, an alarm, Siri — or WebKit's own playback on the way out — took the sound away,
    /// and the native player stopped with it. Once iOS says it may, the sound comes back, as long
    /// as it was meant to be playing.
    private func audioSessionInterruptionChanged(ended: Bool, shouldResume: Bool) {
        // The embed taking the sound back, a moment before it says it plays: it takes over now.
        if !ended, isReturningToEmbed {
            finishReturnToEmbed()
            return
        }
        guard ended, shouldResume, isLocal, audioShouldPlay, !local.isPlaying else { return }
        NowPlaying.shared.begin()
        local.play()
    }
    #endif

    #if os(iOS)

    /// The first sign of leaving: the Home Screen, the lock, the app switcher — or only Control
    /// Centre pulled down over the app. With Settings → Playback → Picture in Picture on, a
    /// streamed video moves to its Picture in Picture window now, while WebKit still can; a
    /// downloaded one is moved by AVKit itself, on the way to the Home Screen only.
    private func appWillResignActive() {
        savePlaybackPosition()
        wasPlayingOnLeaving = isPlaying
        guard currentVideo != nil, isPlaying, !isLocal, !usesNativeCarPlayPlayback,
              AutoPictureInPicturePreference.isEnabled, !isEmbedInPictureInPicture else { return }
        startedPictureInPictureOnLeaving = true
        requestPictureInPicture(reportsFailure: false)
    }

    /// Gone from the screen. Picture in Picture carries on by itself; otherwise the sound goes on
    /// in the background if Settings allow it, and stops if they don't.
    private func appDidEnterBackground() {
        // Left again before the embed took the sound back: it takes it now, and hands it over
        // below like any other time.
        finishReturnToEmbed()
        isInBackground = true
        savePlaybackPosition()
        let wasPlaying = isPlaying || wasPlayingOnLeaving
        wasPlayingOnLeaving = false
        guard currentVideo != nil, wasPlaying, !usesNativeCarPlayPlayback,
              !local.isInPictureInPicture, !isEmbedInPictureInPicture else { return }
        guard BackgroundPlaybackPreference.isEnabled else {
            pause()
            return
        }
        // Whatever the embed has said since, the sound is to go on.
        audioShouldPlay = true
        // A file keeps playing without its picture — see `LocalPlayerSurface` — in the session it
        // already plays in. A streamed video's sound starts its own — see `playBackgroundAudio`.
        guard !isLocal else {
            NowPlaying.shared.begin()
            return
        }
        if startedPictureInPictureOnLeaving {
            // WebKit reports its window a moment after it was asked for. Wait for it before
            // deciding the sound has to move.
            beginHandoffTask()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard let self, self.isInBackground else { return }
                if self.isEmbedInPictureInPicture {
                    self.endHandoffTask()
                } else {
                    self.handOffToBackgroundAudio()
                }
            }
        } else {
            handOffToBackgroundAudio()
        }
    }

    /// Back on screen: a streamed video's picture comes back to the embed, at the moment the
    /// sound has reached.
    private func appWillEnterForeground() {
        isInBackground = false
        endHandoffTask()
        // A sound still being resolved is no longer wanted: on screen the embed plays.
        let wasWaitingForSound = backgroundAudioRequested
        backgroundAudioRequested = false
        guard let video = currentVideo, !usesNativeCarPlayPlayback else { return }
        if carPlayStreamPendingPicture {
            // The car went while the app was out of sight. The sound is still on the native
            // player; the phone takes the picture back now that it is on screen.
            carPlayStreamPendingPicture = false
            play(video, upNext: upNext, startTime: progress.currentTime)
            return
        }
        guard isBackgroundAudio else {
            guard wasWaitingForSound, !isLocal else { return }
            if desiredVideoId == nil {
                // A video started while away whose sound never arrived: the embed plays it now.
                embedStartsPlaying = audioShouldPlay
                desiredVideoId = video.id
                loadedVideoId = nil
                sync()
            } else if audioShouldPlay {
                evaluate("resume()")
            }
            return
        }
        isBackgroundAudio = false
        let shouldPlay = audioShouldPlay && isPlaying
        let position = progress.currentTime
        // Playing, the sound carries on from the native player while the embed loads back in,
        // muted, and the embed takes over once it plays — see `finishReturnToEmbed`. Stopping
        // the sound first left a couple of seconds of silence while YouTube's player started.
        if shouldPlay {
            isReturningToEmbed = true
            returnTimeout?.cancel()
            returnTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.finishReturnToEmbed()
            }
        } else {
            local.stop()
        }
        if pictureInPictureEndedAway {
            pictureInPictureEndedAway = false
            rebuildWebView()
        }
        source = .embed
        pendingSeekTime = position
        isRestoringPosition = false
        rateAppliedPlaybackID = nil
        embedStartsPlaying = shouldPlay
        embedStartsMuted = shouldPlay
        setPlaying(shouldPlay)
        setBuffering(false)
        desiredVideoId = video.id
        loadedVideoId = nil
        sync()
        // A Picture in Picture window the lock closed leaves WebKit's window for it behind, over
        // the app, taking every tap. It goes now, and again once WebKit has settled.
        removeLeftoverVideoWindows()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.removeLeftoverVideoWindows()
        }
    }

    /// Puts the web view away and leaves a new one to be made, on a page of its own. A Picture in
    /// Picture window the lock closed with the app away leaves WebKit stuck: its window stays
    /// over the app, and Picture in Picture never starts again on that page. A new web view
    /// starts clean, and loads the video once it is on screen.
    private func rebuildWebView() {
        guard let old = currentWebView else { return }
        old.configuration.userContentController.removeScriptMessageHandler(forName: "player")
        old.navigationDelegate = nil
        old.stopLoading()
        old.removeFromSuperview()
        fullScreenObserver = nil
        currentWebView = nil
        pictureInPictureFrame = nil
        isEmbedInPictureInPicture = false
        isEmbedMediaSuspended = false
        isShellLoaded = false
        isLoadingShell = false
        isSurfaceOnScreen = false
    }

    /// The window WebKit shows a video's Picture in Picture or full screen from, left behind
    /// over the app once neither is up: the lock closes Picture in Picture with the app away,
    /// and WebKit never puts that window away, even asked to close its presentations. It is
    /// hidden, and the app's own window gets the taps and the keyboard back.
    private func removeLeftoverVideoWindows() {
        guard !isEmbedInPictureInPicture, !isSystemFullScreen else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            let appWindow = scene.windows.first { $0.windowLevel == .normal && !$0.isHidden }
            for window in scene.windows where window !== appWindow && !window.isHidden
                && window.windowLevel > .normal && window.windowLevel < .alert
                && window.rootViewController.map({ type(of: $0) == UIViewController.self }) == true {
                window.isHidden = true
                appWindow?.makeKey()
            }
        }
    }

    /// Fully back. Picture in Picture the app started on the way out goes back into the player,
    /// as in the YouTube app — and it is how Control Centre pulled down over a playing video
    /// gives it back.
    private func appDidBecomeActive() {
        isInBackground = false
        guard startedPictureInPictureOnLeaving else { return }
        startedPictureInPictureOnLeaving = false
        if isEmbedInPictureInPicture { evaluate("exitPictureInPicture()") }
    }

    /// Reported by WebKit whenever the embed's video enters or leaves its Picture in Picture
    /// window.
    func embedPictureInPictureDidChange(_ active: Bool) {
        let wasCarryingOn = isEmbedInPictureInPicture && isInBackground
        isEmbedInPictureInPicture = active
        if !active { startedPictureInPictureOnLeaving = false }
        if !active, wasCarryingOn { pictureInPictureEndedAway = true }
        // The window closed with the app still away: the lock, which pauses it a moment before
        // closing it — or its own close button. Either way the sound carries on alone, as
        // Background Playback says, unless it had been paused in the window before.
        guard !active, wasCarryingOn, BackgroundPlaybackPreference.isEnabled,
              currentVideo != nil, !isLocal, !usesNativeCarPlayPlayback else { return }
        let pausedJustNow = embedPausedAt.map { Date.now.timeIntervalSince($0) < 1 } ?? false
        guard isPlaying || pausedJustNow else { return }
        audioShouldPlay = true
        handOffToBackgroundAudio()
    }

    private func beginHandoffTask() {
        guard handoffTask == .invalid else { return }
        handoffTask = UIApplication.shared.beginBackgroundTask(withName: "Background playback") { [weak self] in
            MainActor.assumeIsolated { self?.endHandoffTask() }
        }
        handoffStartPosition = progress.currentTime
    }

    private func endHandoffTask() {
        handoffStartPosition = nil
        guard handoffTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(handoffTask)
        handoffTask = .invalid
    }
    #endif

    // MARK: - Full screen

    /// Settings → Playback → Full-Screen Player. The app's own player unless iOS's is chosen.
    private var usesSystemFullScreen: Bool {
        #if os(iOS)
        FullScreenPlayerPreference.stored == .system
        #else
        false
        #endif
    }

    /// Turning the phone on its side plays the video full screen on its own — no button to find,
    /// the way the YouTube app does it — and turning it back puts the player where it was.
    /// Driven by the container, which is where the size class is known.
    ///
    /// Full screen is the app's own player, laid out edge to edge with the same controls, unless
    /// Settings asks for iOS's: then the page is asked to hand the video to iOS, which presents it
    /// over the app with the system's controls, and the layout below is what is left if that
    /// request is refused, and what the video comes back to when it is dismissed.
    func setLandscape(_ landscape: Bool) {
        guard isLandscape != landscape else { return }
        isLandscape = landscape
        guard !usesNativeCarPlayPlayback else { return }
        guard currentVideo != nil else { return }

        scrollRun = 0
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            if landscape {
                wasExpandedBeforeFullScreen = isExpanded
                isExpanded = true
                isBarCompact = false
            } else {
                isExpanded = wasExpandedBeforeFullScreen
                matchBarToTabBar()
            }
            isFullScreen = landscape
        }

        #if os(iOS)
        if isLocal {
            local.setFullScreen(landscape && usesSystemFullScreen)
            return
        }
        #endif
        if landscape && usesSystemFullScreen {
            requestSystemFullScreen()
        } else {
            exitSystemFullScreen()
        }
    }

    /// The player's full-screen button. A phone turns to its side — the same full screen as
    /// turning it by hand. An iPad fills its window, and a Mac takes the window full screen with
    /// the video filling it. macOS's player takes its video full screen itself, as Safari does.
    func toggleFullScreen() {
        guard currentVideo != nil else { return }
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: isFullScreen ? .portrait : .landscapeRight)) { _ in }
            return
        }
        #else
        if controls == .system, !isLocal {
            if isSystemFullScreen || wantsSystemFullScreen {
                exitSystemFullScreen()
            } else {
                requestSystemFullScreen()
            }
            return
        }
        #endif
        toggleFillsWindow()
    }

    /// What full screen is where a window has no orientation to react to — a Mac, an iPad: the
    /// app's own full screen, the video filling the window and the chrome stepping aside. On a
    /// Mac the window goes full screen with it, and comes back out when the video does — unless
    /// it was full screen already.
    private func toggleFillsWindow() {
        guard currentVideo != nil else { return }
        let fills = !isFullScreen
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            if fills {
                wasExpandedBeforeFullScreen = isExpanded
                isExpanded = true
                isBarCompact = false
            } else {
                isExpanded = wasExpandedBeforeFullScreen
            }
            isFullScreen = fills
        }
        #if os(iOS)
        guard usesSystemFullScreen else { return }
        if isLocal {
            local.setFullScreen(fills)
        } else if fills {
            requestSystemFullScreen()
        } else {
            exitSystemFullScreen()
        }
        #else
        setWindowFullScreen(fills)
        #endif
    }

    #if os(macOS)
    private func setWindowFullScreen(_ fullScreen: Bool) {
        if fullScreen {
            // The window the video is in. Settings is a window too, and can be the main one.
            let window = (hasWebView ? webView.window : nil) ?? Platform.mainWindow
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            fullScreenWindow = window
            window.toggleFullScreen(nil)
        } else if let window = fullScreenWindow {
            fullScreenWindow = nil
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        }
    }

    /// The window the video went full screen in left it by itself: Esc, the green button, a
    /// swipe to another Space. The video leaves full screen with it.
    private func windowDidExitFullScreen() {
        guard let window = fullScreenWindow, !window.styleMask.contains(.fullScreen) else { return }
        fullScreenWindow = nil
        if isFullScreen { toggleFillsWindow() }
    }
    #endif

    /// Whose controls go over the video: the one chosen in Settings, as far as it can apply.
    static func controls(chosen: PlayerControlsPreference, isFullScreen: Bool,
                         isLocal: Bool) -> PlayerControlsPreference {
        #if os(iOS)
        // Full screen is the Full-Screen Player's: the app's, or iOS's own over it.
        if isFullScreen { return .app }
        #endif
        if isLocal, chosen == .youTube { return .app }
        return chosen
    }

    /// Follows the setting, full screen and the player that is live, and tells the embed which
    /// controls to show — YouTube's own, the system's, or none under the app's.
    private func updateControls() {
        let controls = Self.controls(chosen: .stored, isFullScreen: isFullScreen, isLocal: isLocal)
        guard self.controls != controls else { return }
        self.controls = controls
        #if os(macOS)
        // macOS's player has its own full screen; the app's would stack a second one on it.
        if controls == .system, isFullScreen, !isLocal { toggleFillsWindow() }
        if controls != .system, isSystemFullScreen { exitSystemFullScreen() }
        #endif
        guard isShellLoaded else { return }
        call("setChrome(chrome)", ["chrome": controls.rawValue])
    }

    private func requestSystemFullScreen() {
        guard currentVideo != nil, !isLocal else { return }
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
    /// nothing asks for full screen again until the phone is turned and turned back. Dismissed
    /// on an iPad, where it came from the full-screen button, the window stops being filled too.
    private func setSystemFullScreen(_ active: Bool) {
        guard isSystemFullScreen != active else { return }
        isSystemFullScreen = active
        wantsSystemFullScreen = false
        fullScreenRequest?.cancel()
        fullScreenRequest = nil
        if !active, !isLandscape, isFullScreen {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                isExpanded = wasExpandedBeforeFullScreen
                isFullScreen = false
                matchBarToTabBar()
            }
        }
    }

    // MARK: - The player's settings

    /// The settings menu's Quality. Like YouTube's, it holds for this video only.
    func setQuality(_ quality: String) {
        options.select(quality: quality)
        guard !isLocal else { return }
        call("setQuality(quality)", ["quality": quality])
    }

    /// Captions: a track, a track translated into another language, or none for a nil track.
    func setCaptions(_ track: String?, translation: String? = nil) {
        options.select(caption: track, translation: translation)
        if isLocal {
            local.selectCaption(track)
        } else {
            call("setCaptions(track, translation)",
                 ["track": track ?? NSNull(), "translation": translation ?? NSNull()])
        }
    }

    /// The CC button: off if captions show, otherwise back on in YouTube's choice of language.
    func toggleCaptions() {
        if options.caption != nil {
            setCaptions(nil)
        } else if isLocal {
            if let first = options.captions.first { setCaptions(first.id) }
        } else {
            call("setCaptions('', null)", [:])
        }
    }

    func setAudioTrack(_ track: String) {
        options.select(audioTrack: track)
        if isLocal {
            local.selectAudioTrack(track)
        } else {
            call("setAudioTrack(track)", ["track": track])
        }
    }

    /// The settings menu's speed, which carries on to the next videos.
    func setRate(_ rate: Double) {
        guard rate.isFinite, rate > 0 else { return }
        preferredRate = rate
        rateAppliedPlaybackID = playbackID
        options.select(rate: rate)
        guard !options.isSpeedingUp else { return }
        applyRate(rate)
    }

    /// Touching and holding the right of the video: double speed until the finger lifts.
    func beginSpeedingUp() {
        guard currentVideo != nil, isPlaying, !options.isSpeedingUp else { return }
        options.setSpeedingUp(true)
        applyRate(HoldToSpeedUpPreference.rate)
    }

    func endSpeedingUp() {
        guard options.isSpeedingUp else { return }
        options.setSpeedingUp(false)
        applyRate(options.rate)
    }

    private func applyRate(_ rate: Double) {
        if isLocal {
            local.setRate(rate)
        } else {
            call("setRate(rate)", ["rate": rate])
        }
        refreshNowPlaying()
    }

    /// The player's controls are showing: YouTube's captions move up out of their way.
    func setControlsShown(_ shown: Bool) {
        guard !isLocal, isShellLoaded else { return }
        call("setControlsShown(shown)", ["shown": shown])
    }

    /// The embed's report of what its menus would offer, sent whenever any of it changes.
    private func handleOptionsReport(_ json: String) {
        guard let data = json.data(using: .utf8),
              let report = try? JSONDecoder().decode(EmbedOptionsReport.self, from: data) else { return }
        options.apply(report)
        // A speed chosen for an earlier video carries on into this one, once the player is up.
        if rateAppliedPlaybackID != playbackID, report.rate != nil, report.ad != true {
            rateAppliedPlaybackID = playbackID
            if let rate = report.rate, rate != preferredRate {
                options.select(rate: preferredRate)
                applyRate(preferredRate)
            }
        }
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
    #if os(iOS)
    /// The tab bar's own minimized state, which the bar follows whenever it can be read.
    private lazy var tabBar = TabBarMinimizationWatcher { [weak self] minimized in
        self?.tabBarDidChange(minimized: minimized)
    }
    #endif

    /// Fed by every screen's scroll view. The bar is the same size as the tab bar underneath, so
    /// where the tab bar's state can be read, the bar simply follows it — the tab bar decides
    /// when to minimize and restore on rules of its own, see `TabBarMinimizationWatcher`.
    ///
    /// Otherwise the scroll decides: scrolling down shrinks the bar to its pill, and scrolling
    /// back to the *top* brings it back. Content that fits on screen can't scroll, so it never
    /// changes the bar — however far it is dragged and rubber-banded.
    func scrollDidMove(from previous: CGFloat, to current: CGFloat, canScroll: Bool) {
        guard currentVideo != nil, !isExpanded else { return }
        #if os(iOS)
        if let minimized = tabBar.isMinimized() {
            setBarCompact(minimized)
            return
        }
        #endif
        guard canScroll else {
            scrollRun = 0
            return
        }

        // The top, and only the top, is what restores the bar — once a scroll gets back to it.
        // A screen that merely starts there, like one just opened, leaves the bar as it is: the
        // tab bar stays minimized when you open a screen, so the bar has to as well.
        guard current > Self.topTolerance else {
            scrollRun = 0
            if previous > Self.topTolerance { setBarCompact(false) }
            return
        }

        let delta = current - previous
        guard delta > 0.5 else { return }

        scrollRun = min(Self.compactThreshold, scrollRun + delta)
        if scrollRun >= Self.compactThreshold {
            setBarCompact(true)
        }
    }

    /// A touch on the tab bar's row. The shrunk tab bar grows back when touched, with nothing
    /// scrolled, so the bar grows back with it — the two are meant to be the same size.
    func tabBarWasTouched() {
        guard isBarCompact else { return }
        #if os(iOS)
        // The tab bar reports for itself when it can, and only a touch on its button restores it.
        if tabBar.isMinimized() != nil { return }
        #endif
        scrollRun = 0
        setBarCompact(false)
    }

    #if os(iOS)
    private func tabBarDidChange(minimized: Bool) {
        guard currentVideo != nil, !isExpanded else { return }
        setBarCompact(minimized)
    }
    #endif

    private func setBarCompact(_ compact: Bool) {
        guard isBarCompact != compact else { return }
        // `.snappy` is the system's own preset for chrome that jumps between two states, which
        // is the closest we can get to the curve the tab bar minimizes on: the two don't share
        // an animation, so they are kept in step by starting on the same frame.
        withAnimation(.snappy) {
            isBarCompact = compact
        }
    }

    func collapse() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            isExpanded = false
            matchBarToTabBar()
        }
    }

    /// Docking the player lands it at the tab bar's size: shrunk to its pill if the tab bar was
    /// minimized while the player was open. Called inside the docking animation, so the player
    /// shrinks on its way down rather than once it gets there.
    private func matchBarToTabBar() {
        #if os(iOS)
        guard !isExpanded, let minimized = tabBar.isMinimized() else { return }
        isBarCompact = minimized
        #endif
    }

    // MARK: - Events from the web player

    func handle(_ event: PlayerEvent) {
        // The shell handshake remains useful even if its first video was replaced while loading.
        // Every other event must belong to the current playback, including reopens of the same ID.
        if event.type != "ready" {
            guard currentVideo != nil, event.videoID == currentVideo?.id,
                  event.playbackID == playbackID else { return }
        }
        // The embed keeps reporting for a moment after a downloaded video takes over, and its
        // position would fight the file's for the scrubber. Only the handshake is still worth
        // hearing: it says the shell is up and ready for the next streamed video.
        if isLocal || usesNativeCarPlayPlayback {
            if event.type == "ready" {
                isShellLoaded = true
                isLoadingShell = false
                watchdog?.cancel()
            }
            return
        }

        if let duration = event.duration, duration.isFinite, duration > 0, progress.duration != duration {
            progress.duration = duration
            // The scrubber on the lock screen has nothing to draw until this arrives.
            refreshNowPlaying()
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

        case "fullScreenRequest":
            // YouTube's own full-screen button, under YouTube's controls.
            toggleFullScreen()

        case "state":
            // YT.PlayerState: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued
            guard let state = event.state else { return }
            setPlaying(state == 1)
            setBuffering(state == 3)
            // Replaying the same video reloads nothing, so there is no `ready` to wait for; the
            // moment it starts is the other chance to hand it over.
            if state == 1 {
                finishReturnToEmbed()
                playbackDidEnd = false
                startFullScreenRequest()
            }
            if state == 0 {
                finishPlayback()
                advanceAfterEnd()
            }

        case "time":
            if let time = event.time {
                updatePlaybackProgress(elapsed: time, duration: event.duration ?? 0)
            }

        case "options":
            if let json = event.payload { handleOptionsReport(json) }

        case "switched":
            // One of YouTube's suggestions at the end, picked in the embed: it becomes the video
            // the app is playing, with its details, its history entry and its own controls.
            guard let videoID = event.payload, videoID != currentVideo?.id else { return }
            Task { await open(videoId: videoID) }

        default:
            break
        }
    }

    /// The embed repeats its state with every position report, and assigning an unchanged
    /// `@Published` value still redraws every view watching the player — several times a second.
    private func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        #if os(iOS)
        if !playing, !isLocal { embedPausedAt = .now }
        #endif
        isPlaying = playing
        if !playing { savePlaybackPosition() }
        // The embed pausing or resuming on its own — an ad break, a tap on its own controls —
        // has to reach the lock screen too, or its button ends up showing the opposite.
        refreshNowPlaying()
    }

    private func setBuffering(_ buffering: Bool) {
        if isBuffering != buffering { isBuffering = buffering }
    }

    private func updatePlaybackProgress(elapsed: Double, duration: Double) {
        guard elapsed.isFinite, elapsed >= 0, !playbackDidEnd else { return }
        if duration.isFinite, duration > 0, progress.duration != duration {
            progress.duration = duration
            refreshNowPlaying()
        }
        if let target = pendingSeekTime {
            // Startup and seek reports can still describe the old position. Do not let them
            // replace the saved checkpoint before the player has actually reached the target.
            if isRestoringPosition, progress.duration > 0, target >= progress.duration {
                seek(to: 0)
                return
            }
            // The file player already suppresses reports until its exact seek completes.
            guard isLocal || abs(elapsed - target) < 2 else { return }
            pendingSeekTime = nil
            isRestoringPosition = false
        }
        if abs(elapsed - progress.currentTime) > 0.05 { progress.currentTime = elapsed }
        savePlaybackPosition(flush: false)
    }

    func savePlaybackPosition(flush: Bool = true) {
        if let videoID = currentVideo?.id, !playbackDidEnd {
            let position = PlaybackPosition(seconds: progress.currentTime, duration: progress.duration)
            // Closing an idle player must not overwrite a newer checkpoint received from
            // another device. Only actual progress or an explicit seek creates a fresh edit.
            if position != lastRecordedPosition {
                PlaybackPositionStore.shared.record(videoID: videoID, seconds: position.seconds,
                                                    duration: position.duration)
                lastRecordedPosition = position
            }
        }
        if flush { PlaybackPositionStore.shared.flush() }
    }

    private func finishPlayback() {
        guard !playbackDidEnd else { return }
        playbackDidEnd = true
        pendingSeekTime = nil
        if let videoID = currentVideo?.id { PlaybackPositionStore.shared.markFinished(videoID: videoID) }
    }

    // MARK: - Web view plumbing

    private func evaluate(_ javaScript: String) {
        // Without a web view there is no page to tell, and making one here would undo the point
        // of making it late — a pause with nothing ever played is all that would reach this.
        guard hasWebView else { return }
        webView.evaluateJavaScript(javaScript, completionHandler: nil)
    }

    /// Calls into the page with its arguments passed as values rather than spliced into the
    /// script, so a caption track's id can't break out of a string literal.
    private func call(_ javaScript: String, _ arguments: [String: Any]) {
        guard hasWebView else { return }
        webView.callAsyncJavaScript(javaScript, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    private func loadShell(initialVideoId: String) {
        isShellLoaded = false
        let html = PlayerShell.render(
            videoID: initialVideoId, startTime: progress.currentTime, playbackID: playbackID ?? "",
            autoplay: embedStartsPlaying, muted: embedStartsMuted, controls: controls.rawValue
        )

        // The base URL matches the iframe's host, exactly as in the version that played fine.
        webView.loadHTMLString(html, baseURL: PlayerShell.baseURL)
    }

}
