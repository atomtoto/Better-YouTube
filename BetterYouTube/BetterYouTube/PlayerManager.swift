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
    private var usesNativeCarPlayPlayback: Bool { isAudioOnly || isCarPlayVideoPlayback }
    private var audioStreamTask: Task<Void, Never>?
    private var audioShouldPlay = true
    private let resolveAudio: @Sendable (String) async throws -> URL
    private let resolveVideo: @Sendable (String) async throws -> URL
    private let downloadedMediaURL: @MainActor (String) -> URL?

    /// Made on first use rather than at launch. Creating it — and the web content process
    /// behind it — was the largest single cost of starting the app, paid even when nothing
    /// was ever played. The container asks for it once there is something to show.
    private(set) lazy var webView: WKWebView = makeWebView()
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
    /// Set when the app went to the background before that sound was resolved: it takes over as
    /// soon as it arrives.
    private var backgroundAudioRequested = false
    /// The file player is carrying a streamed video's sound while the app is away, and the embed
    /// takes the video back when the app returns.
    private var isBackgroundAudio = false
    /// Whether the embed asks to start playing as it loads. Off only when a paused video comes
    /// back from the background.
    private var embedStartsPlaying = true
    #if os(iOS)
    /// From the moment the app leaves the screen until it is back.
    private var isInBackground = false
    /// Picture in Picture the app started by itself on the way out, put back when it returns.
    private var startedPictureInPictureOnLeaving = false
    /// Whether the embed's video is in its Picture in Picture window, as WebKit reports it.
    private var isEmbedInPictureInPicture = false
    /// Keeps the app running while the sound moves from the embed to the file player.
    private var handoffTask: UIBackgroundTaskIdentifier = .invalid
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
        }

        local.onPlayingChanged = { [weak self] playing in
            guard let self, self.isLocal else { return }
            self.setPlaying(playing)
            if playing { self.setBuffering(false) }
            #if os(iOS)
            // The sound is really coming out: the app can be left to iOS's audio rules now.
            if playing, self.local.player.timeControlStatus == .playing { self.endHandoffTask() }
            #endif
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
        }
    }

    // MARK: - Playback

    /// Starts a video and expands the player. `upNext` becomes the auto-play queue.
    ///
    /// `startTime` is a moment asked for explicitly — a shared link's `t=`, a timestamp tapped
    /// in a description — and wins over the position saved for the video.
    func play(_ video: Video, upNext queue: [Video] = [], audioOnly: Bool = false,
              carPlayVideo: Bool = false, startTime: TimeInterval? = nil) {
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
        guard connected, let video = currentVideo else { return }
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
    /// once. A sound-only stream is what YouTube still offers every video — the muxed ones are
    /// gone for most — and it is all a locked phone needs.
    private func resolveBackgroundAudio(for videoID: String) {
        backgroundAudioTask?.cancel()
        backgroundAudioTask = Task { [weak self] in
            guard let resolveAudio = self?.resolveAudio,
                  let url = try? await resolveAudio(videoID),
                  !Task.isCancelled, let self,
                  self.currentVideo?.id == videoID, !self.isLocal else { return }
            self.backgroundAudioTask = nil
            self.backgroundAudioURL = url
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
        local.load(url: url)
        local.setRate(preferredRate)
        local.seek(to: position)
        if audioShouldPlay { local.play() }
        refreshNowPlaying()
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

        if !isShellLoaded {
            guard !isLoadingShell else { return }
            isLoadingShell = true
            loadedVideoId = desired
            loadedPlaybackID = playbackID
            loadShell(initialVideoId: desired)
            embedStartsPlaying = true
            startWatchdog()
        } else if loadedVideoId != desired || loadedPlaybackID != playbackID {
            loadedVideoId = desired
            loadedPlaybackID = playbackID
            evaluate("setVideo('\(desired)', \(progress.currentTime), '\(playbackID)', \(embedStartsPlaying))")
            embedStartsPlaying = true
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
        cancelSleepTimer()
        savePlaybackPosition()
        audioStreamTask?.cancel()
        audioStreamTask = nil
        isAudioOnly = false
        isCarPlayVideoPlayback = false
        carPlayPrefersVideo = false
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
    }

    #if os(iOS)

    /// The first sign of leaving: the Home Screen, the lock, the app switcher — or only Control
    /// Centre pulled down over the app. With Settings → Playback → Picture in Picture on, a
    /// streamed video moves to its Picture in Picture window now, while WebKit still can; a
    /// downloaded one is moved by AVKit itself, on the way to the Home Screen only.
    private func appWillResignActive() {
        savePlaybackPosition()
        guard currentVideo != nil, isPlaying, !isLocal, !usesNativeCarPlayPlayback,
              AutoPictureInPicturePreference.isEnabled, !isEmbedInPictureInPicture else { return }
        startedPictureInPictureOnLeaving = true
        requestPictureInPicture(reportsFailure: false)
    }

    /// Gone from the screen. Picture in Picture carries on by itself; otherwise the sound goes on
    /// in the background if Settings allow it, and stops if they don't.
    private func appDidEnterBackground() {
        isInBackground = true
        savePlaybackPosition()
        guard currentVideo != nil, isPlaying, !usesNativeCarPlayPlayback,
              !local.isInPictureInPicture, !isEmbedInPictureInPicture else { return }
        guard BackgroundPlaybackPreference.isEnabled else {
            pause()
            return
        }
        NowPlaying.shared.begin()
        // A file keeps playing without its picture — see `LocalPlayerSurface`.
        guard !isLocal else { return }
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
        local.stop()
        source = .embed
        pendingSeekTime = position
        isRestoringPosition = false
        rateAppliedPlaybackID = nil
        embedStartsPlaying = shouldPlay
        setPlaying(shouldPlay)
        setBuffering(shouldPlay)
        desiredVideoId = video.id
        loadedVideoId = nil
        sync()
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
        isEmbedInPictureInPicture = active
        if !active { startedPictureInPictureOnLeaving = false }
    }

    private func beginHandoffTask() {
        guard handoffTask == .invalid else { return }
        handoffTask = UIApplication.shared.beginBackgroundTask(withName: "Background playback") { [weak self] in
            MainActor.assumeIsolated { self?.endHandoffTask() }
        }
    }

    private func endHandoffTask() {
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
        let html = Self.shellHTML
            .replacingOccurrences(of: "__VIDEO_ID__", with: initialVideoId)
            .replacingOccurrences(of: "__START_SECONDS__", with: String(progress.currentTime))
            .replacingOccurrences(of: "__PLAYBACK_ID__", with: playbackID ?? "")
            .replacingOccurrences(of: "__AUTOPLAY__", with: String(embedStartsPlaying))
            .replacingOccurrences(of: "__CHROME__", with: controls.rawValue)

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
      <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
      <style>
        html, body { margin: 0; padding: 0; background: #000; height: 100%; overflow: hidden; }
        #frame { position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: 0; }
      </style>
    </head>
    <body>
      <iframe id="frame"
        allow="accelerometer; autoplay; encrypted-media; fullscreen; gyroscope; picture-in-picture"
        allowfullscreen>
      </iframe>
      <script>
        var frame = document.getElementById('frame');
        var handshake;
        // The ID of the video this page is playing. Never an element: the full-screen code
        // keeps its video element in `fullScreenVideo`, and sharing one variable between the
        // two used to stamp a DOM node onto outgoing reports as their `videoID`.
        var watchedVideo;
        var fullScreenVideo;
        var reportedVideoID;
        var playbackID;
        var pendingStartSeconds = 0;
        var playing = false;
        // Set once the video has reached its end, which is when YouTube's own suggestions are up
        // and one of them can be picked.
        var reachedEnd = false;
        // Whether the video starts as it loads. Off only for a paused video coming back from
        // the background.
        var startsPlaying = true;
        var lastReport = '';
        var chapterCache = null;
        var controlsShown = false;
        // Whose controls are over the video: 'app', the app's own, drawn over this page with
        // YouTube's hidden underneath; 'youTube', YouTube's own, left showing; 'system', WebKit's
        // own on the video element, as in Safari — a Mac's.
        var chrome = '__CHROME__';
        // Whether YouTube's layer is showing for an ad or its end screen.
        var youTubeLayerShown = false;

        function post(message) {
          message.videoID = reportedVideoID || watchedVideo;
          message.playbackID = playbackID;
          try { window.webkit.messageHandlers.player.postMessage(message); } catch (e) {}
        }

        function send(message) {
          try { frame.contentWindow.postMessage(JSON.stringify(message), '*'); } catch (e) {}
        }

        function command(func, args) {
          send({ event: 'command', func: func, args: args || [] });
        }

        function setVideo(id, seconds, sessionID, autoplay) {
          clearInterval(handshake);
          startsPlaying = autoplay !== false;
          watchedVideo = id;
          fullScreenVideo = null;
          reportedVideoID = null;
          playbackID = sessionID;
          pendingStartSeconds = seconds || 0;
          playing = false;
          reachedEnd = false;
          lastReport = '';
          chapterCache = null;
          // A fresh iframe gives each playback its own message source. Reports still in flight
          // from the previous video cannot overwrite this video's checkpoint.
          var nextFrame = frame.cloneNode(false);
          installHandshake(nextFrame);
          nextFrame.src = 'https://www.youtube-nocookie.com/embed/' + id +
            '?enablejsapi=1&playsinline=1&rel=1&modestbranding=1&controls=1&start=' +
            Math.floor(pendingStartSeconds);
          frame.replaceWith(nextFrame);
          frame = nextFrame;
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
          if (fullScreenVideo === video) { return; }
          fullScreenVideo = video;
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
          var enter = video && originalFullScreen(video, 'webkitEnterFullscreen');
          if (enter) {
            watch(video);
            if (video.webkitDisplayingFullscreen) { return; }
            try { enter.call(video); return; } catch (e) {}
          }
          // An embed we can't see into will never hand over its video element, so there is
          // nothing to wait for. One we can see into is still booting, and the app asks again
          // in a moment.
          if (mayFallBack || !embedDocument()) { enterElementFullScreen(); }
        }

        function exitFullScreen() {
          var video = fullScreenVideo || videoElement();
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

        // The embed's own player object. This page is loaded with the embed's origin as its base
        // URL, so the player inside the iframe can be reached directly — and with it everything
        // YouTube's gear menu offers that the postMessage protocol doesn't: quality, caption
        // tracks and their translations, audio tracks, and the chapters of the progress bar.
        function moviePlayer() {
          var doc = embedDocument();
          return doc ? doc.getElementById('movie_player') : null;
        }

        // YouTube's own controls stay under the app's, hidden — except while they are the only way
        // to do something: skipping an ad, or picking one of YouTube's suggestions at the end — or
        // when they are the ones chosen. Captions move up out of the way of the app's controls
        // while those are showing. Under the system's controls, the clicks go through YouTube's
        // layer to the video element, whose controls they are.
        var embedStyle =
          'html:not(.by-youtube-layer) #player-controls,' +
          'html:not(.by-youtube-layer) #bottom-sheet-wrapper,' +
          'html:not(.by-youtube-layer) .ytp-chrome-top,' +
          'html:not(.by-youtube-layer) .ytp-chrome-bottom,' +
          'html:not(.by-youtube-layer) .ytp-gradient-top,' +
          'html:not(.by-youtube-layer) .ytp-gradient-bottom,' +
          'html:not(.by-youtube-layer) .ytp-pause-overlay,' +
          'html:not(.by-youtube-layer) .ytp-large-play-button,' +
          'html:not(.by-youtube-layer) .ytp-spinner,' +
          'html:not(.by-youtube-layer) .ytp-watermark { display: none !important; }' +
          '.ytp-caption-window-container { transition: transform 0.2s ease; }' +
          'html.by-controls-shown:not(.by-youtube-layer) .ytp-caption-window-container {' +
          ' transform: translateY(-44px); }' +
          'html.by-native-controls #movie_player * { pointer-events: none !important; }' +
          'html.by-native-controls #movie_player video { pointer-events: auto !important; }';

        function prepareEmbed(doc, showsYouTubeLayer) {
          youTubeLayerShown = showsYouTubeLayer;
          if (!doc.getElementById('by-style')) {
            var style = doc.createElement('style');
            style.id = 'by-style';
            style.textContent = embedStyle;
            (doc.head || doc.documentElement).appendChild(style);
          }
          routeFullScreenToApp(doc);
          // An ad or the end screen gets YouTube's layer whoever's controls are chosen: it is the
          // only way to skip the ad or pick a suggestion.
          var native = chrome === 'system' && !showsYouTubeLayer;
          doc.documentElement.classList.toggle('by-youtube-layer', showsYouTubeLayer || chrome === 'youTube');
          doc.documentElement.classList.toggle('by-native-controls', native);
          doc.documentElement.classList.toggle('by-controls-shown', controlsShown);
          var video = doc.querySelector('video');
          if (video) { setNativeControls(video, native); }
        }

        function setChrome(value) {
          chrome = value;
          var doc = embedDocument();
          if (doc && doc.documentElement) { prepareEmbed(doc, youTubeLayerShown); }
        }

        // WebKit's controls on YouTube's video element. Their clicks stop at the video: YouTube
        // listens for clicks on its player too, and would undo every play or pause.
        function setNativeControls(video, on) {
          if (video.controls !== on) { video.controls = on; }
          if (!on || video.byNativeControls) { return; }
          video.byNativeControls = true;
          ['click', 'dblclick', 'mousedown', 'mouseup', 'pointerdown', 'pointerup', 'contextmenu']
            .forEach(function (type) {
              video.addEventListener(type, function (event) {
                if (video.controls) { event.stopPropagation(); }
              });
            });
        }

        // YouTube's own full-screen button, its double click and its F key ask for full screen
        // here. With YouTube's controls chosen, the app's full screen is what they get — the phone
        // turning, the Mac's window going full screen — rather than a second one of WebKit's.
        // The originals stay at hand for the app's own requests: see `enterFullScreen`.
        var fullScreenMethods = {
          Element: ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen'],
          HTMLVideoElement: ['webkitEnterFullscreen', 'webkitEnterFullScreen']
        };

        function routeFullScreenToApp(doc) {
          var win = doc.defaultView;
          if (!win || win.byOriginalFullScreen) { return; }
          win.byOriginalFullScreen = {};
          Object.keys(fullScreenMethods).forEach(function (type) {
            var prototype = win[type] && win[type].prototype;
            if (!prototype) { return; }
            fullScreenMethods[type].forEach(function (name) {
              var original = prototype[name];
              if (typeof original !== 'function') { return; }
              win.byOriginalFullScreen[name] = original;
              prototype[name] = function () {
                if (chrome !== 'youTube') { return original.apply(this, arguments); }
                post({ type: 'fullScreenRequest' });
                return win.Promise ? win.Promise.resolve() : undefined;
              };
            });
          });
        }

        function originalFullScreen(video, name) {
          var win = video.ownerDocument && video.ownerDocument.defaultView;
          var original = win && win.byOriginalFullScreen && win.byOriginalFullScreen[name];
          if (original) { return original; }
          return typeof video[name] === 'function' ? video[name] : null;
        }

        function setControlsShown(shown) {
          controlsShown = shown;
          var doc = embedDocument();
          if (doc) { doc.documentElement.classList.toggle('by-controls-shown', shown); }
        }

        function textOf(value) {
          if (!value) { return ''; }
          if (value.simpleText) { return value.simpleText; }
          if (value.runs) { return value.runs.map(function (run) { return run.text; }).join(''); }
          return '';
        }

        function findKey(node, key, depth) {
          if (!node || typeof node !== 'object' || depth > 24) { return null; }
          if (Array.isArray(node)) {
            for (var i = 0; i < node.length; i++) {
              var inItem = findKey(node[i], key, depth + 1);
              if (inItem) { return inItem; }
            }
            return null;
          }
          if (node[key]) { return node[key]; }
          for (var name in node) {
            var found = findKey(node[name], key, depth + 1);
            if (found) { return found; }
          }
          return null;
        }

        // The chapters YouTube's progress bar is split into, from the same response it draws them
        // from: the ones written in the description first, then YouTube's automatic ones.
        function chapters(player) {
          if (chapterCache && chapterCache.video === watchedVideo) { return chapterCache.list; }
          var response = null;
          try { response = player.getWatchNextResponse && player.getWatchNextResponse(); } catch (e) {}
          if (!response) { return []; }
          var markers = findKey(response, 'markersMap', 0) || [];
          var rank = function (marker) {
            return marker.key === 'DESCRIPTION_CHAPTERS' ? 0 : (marker.key === 'AUTO_CHAPTERS' ? 1 : 2);
          };
          var lists = markers.filter(function (marker) {
            return marker && marker.value && Array.isArray(marker.value.chapters);
          }).sort(function (a, b) { return rank(a) - rank(b); });
          var list = [];
          if (lists.length) {
            list = lists[0].value.chapters.map(function (chapter) {
              return chapter.chapterRenderer;
            }).filter(Boolean).map(function (chapter) {
              return { title: textOf(chapter.title), start: (chapter.timeRangeStartMillis || 0) / 1000,
                thumbnail: chapterThumbnail(chapter.thumbnail) };
            });
          }
          chapterCache = { video: watchedVideo, list: list };
          return list;
        }

        // The smallest of a chapter's pictures that is still sharp in a list row.
        function chapterThumbnail(thumbnail) {
          var sizes = (thumbnail && thumbnail.thumbnails) || [];
          var sharp = sizes.filter(function (size) { return size.width >= 300; })
            .sort(function (a, b) { return a.width - b.width; })[0];
          var picked = sharp || sizes[sizes.length - 1];
          return picked && picked.url ? picked.url : undefined;
        }

        function captionID(track) {
          if (!track) { return null; }
          return track.vss_id || track.vssId || ((track.kind === 'asr' ? 'a.' : '.') + track.languageCode);
        }

        // The caption tracks on offer. YouTube lists them once its captions module is loaded;
        // before that, the audio track carries the same list.
        function captionTracks(player) {
          var list = [];
          try { list = player.getOption('captions', 'tracklist') || []; } catch (e) {}
          if (list.length) { return list; }
          var audio = null;
          try { audio = player.getAudioTrack(); } catch (e) {}
          for (var name in audio || {}) {
            var value = audio[name];
            if (Array.isArray(value) && value.length && value[0] && value[0].languageCode) {
              return value.map(function (track) {
                return { languageCode: track.languageCode, languageName: track.languageName,
                  displayName: track.displayName || track.languageName, kind: track.kind,
                  name: track.name, vss_id: track.vssId, is_translateable: track.isTranslateable };
              });
            }
          }
          return [];
        }

        function currentCaption(player) {
          try {
            var track = player.getOption('captions', 'track');
            return track && track.languageCode ? track : null;
          } catch (e) { return null; }
        }

        // What describes an audio track sits under a property whose name YouTube's build minifies,
        // so it is found by its shape: a name to show and an id to choose it by.
        function audioInfo(track) {
          for (var name in track || {}) {
            var value = track[name];
            if (value && typeof value === 'object' && typeof value.name === 'string' &&
                typeof value.id === 'string') { return value; }
          }
          return null;
        }

        function collectOptions(player) {
          var report = {};
          try {
            report.qualities = (player.getAvailableQualityData() || []).filter(function (quality) {
              return quality.isPlayable !== false && quality.quality !== 'auto';
            }).map(function (quality) { return { id: quality.quality, title: quality.qualityLabel }; });
          } catch (e) {}
          try { report.quality = player.getPreferredQuality(); } catch (e) {}
          try { report.qualityLabel = player.getPlaybackQualityLabel(); } catch (e) {}
          var tracks = captionTracks(player);
          report.captions = tracks.map(function (track) {
            return { id: captionID(track), title: track.displayName || track.languageName || track.languageCode };
          });
          var caption = currentCaption(player);
          report.caption = captionID(caption);
          report.translation = caption && caption.translationLanguage ? caption.translationLanguage.languageCode : null;
          try {
            report.translations = (player.getOption('captions', 'translationLanguages') || []).map(function (language) {
              return { id: language.languageCode, title: language.languageName };
            });
          } catch (e) { report.translations = []; }
          try {
            report.audioTracks = (player.getAvailableAudioTracks() || []).map(audioInfo).filter(Boolean)
              .map(function (info) { return { id: info.id, title: info.name }; });
            var audio = audioInfo(player.getAudioTrack());
            report.audioTrack = audio ? audio.id : null;
          } catch (e) {}
          try { report.rates = player.getAvailablePlaybackRates(); } catch (e) {}
          try { report.rate = player.getPlaybackRate(); } catch (e) {}
          report.chapters = chapters(player);
          report.ad = player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting');
          report.ended = player.classList.contains('ended-mode');
          return report;
        }

        // Reports what the menus would offer whenever any of it changes — and keeps YouTube's own
        // layer hidden or shown, which can change with the video, an ad, or the end.
        function reportOptions() {
          if (!watchedVideo) { return; }
          var player = moviePlayer();
          if (!player || typeof player.getAvailableQualityData !== 'function') { return; }
          var report = collectOptions(player);
          prepareEmbed(player.ownerDocument, !!(report.ad || report.ended));
          var text = JSON.stringify(report);
          if (text === lastReport) { return; }
          lastReport = text;
          post({ type: 'options', payload: text });
        }

        setInterval(reportOptions, 500);

        function setQuality(quality) {
          var player = moviePlayer();
          if (!player || !player.setPlaybackQualityRange) { return; }
          try { player.setPlaybackQualityRange(quality, quality); } catch (e) {}
          reportOptions();
        }

        // A caption track by id, translated or not; no id at all turns captions off, and an empty
        // one turns them on in whatever language YouTube would pick itself.
        function setCaptions(id, translation) {
          var player = moviePlayer();
          if (!player) { return; }
          if (id === null && !translation) {
            try { player.setOption('captions', 'track', {}); } catch (e) {}
            reportOptions();
            return;
          }
          try { player.loadModule('captions'); } catch (e) {}
          var apply = function () {
            var tracks = captionTracks(player);
            var current = currentCaption(player);
            var track = tracks.filter(function (candidate) { return captionID(candidate) === id; })[0];
            if (!track && translation) {
              track = current || tracks.filter(function (candidate) {
                return candidate.is_translateable || candidate.isTranslateable;
              })[0];
            }
            if (!track && id === '') {
              if (current) { return true; }
              var language = (navigator.language || 'en').split('-')[0];
              track = tracks.filter(function (candidate) { return candidate.languageCode.split('-')[0] === language; })[0] || tracks[0];
            }
            if (!track) { return false; }
            var choice = Object.assign({}, track);
            delete choice.translationLanguage;
            if (translation) {
              var names = [];
              try { names = player.getOption('captions', 'translationLanguages') || []; } catch (e) {}
              var named = names.filter(function (language) { return language.languageCode === translation; })[0];
              choice.translationLanguage = { languageCode: translation, languageName: named ? named.languageName : translation };
            }
            try { player.setOption('captions', 'track', choice); } catch (e) { return false; }
            return true;
          };
          // The module loads asynchronously, and until it has, a choice may not take.
          if (!apply()) { setTimeout(apply, 400); }
          setTimeout(reportOptions, 450);
        }

        function setAudioTrack(id) {
          var player = moviePlayer();
          if (!player) { return; }
          try {
            var track = (player.getAvailableAudioTracks() || []).filter(function (candidate) {
              var info = audioInfo(candidate);
              return info && info.id === id;
            })[0];
            if (track) { player.setAudioTrack(track); }
          } catch (e) {}
          reportOptions();
        }

        function setRate(rate) {
          var player = moviePlayer();
          if (player && player.setPlaybackRate) {
            try { player.setPlaybackRate(rate); } catch (e) { command('setPlaybackRate', [rate]); }
          } else {
            command('setPlaybackRate', [rate]);
          }
          reportOptions();
        }

        // The embed only starts reporting state once we introduce ourselves; it can miss the
        // first few messages while it boots, so repeat briefly.
        function installHandshake(loadedFrame) {
          loadedFrame.addEventListener('load', function () {
            if (loadedFrame !== frame || !watchedVideo) { return; }
            var doc = embedDocument();
            if (doc) { prepareEmbed(doc, false); }
            clearInterval(handshake);
            var attempts = 0;
            handshake = setInterval(function () {
              send({ event: 'listening', id: 'frame', channel: 'widget' });
              if (attempts === 2 && startsPlaying) { command('playVideo'); }
              if (++attempts > 20) { clearInterval(handshake); }
            }, 250);
            post({ type: 'ready' });
          });
        }

        window.addEventListener('message', function (event) {
          if (!watchedVideo || event.source !== frame.contentWindow) { return; }
          var data;
          try { data = JSON.parse(event.data); } catch (e) { return; }
          if (!data) { return; }

          if (data.event === 'onStateChange') {
            playing = data.info === 1;
            if (data.info === 0) { reachedEnd = true; }
            post({ type: 'state', state: data.info });
          } else if (data.event === 'onError') {
            post({ type: 'error', state: data.info });
          } else if (data.event === 'infoDelivery' && data.info) {
            var info = data.info;
            if (info.videoData && info.videoData.video_id) {
              var shownVideo = info.videoData.video_id;
              // Only YouTube's end screen can put another video in the embed: tell the app, which
              // takes it over as the video playing.
              if (reachedEnd && reportedVideoID && shownVideo !== reportedVideoID) {
                reachedEnd = false;
                post({ type: 'switched', payload: shownVideo });
              }
              reportedVideoID = shownVideo;
            }
            if (pendingStartSeconds > 0 && info.duration > 0 &&
                (!reportedVideoID || reportedVideoID === watchedVideo)) {
              command('seekTo', [pendingStartSeconds < info.duration ? pendingStartSeconds : 0, true]);
              pendingStartSeconds = 0;
            }
            if (typeof info.playerState === 'number') {
              if (info.playerState === 0) { reachedEnd = true; }
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
        // Not playing from this moment, before the embed confirms it.
        function pauseVideo() { playing = false; command('pauseVideo'); }

        // Puts the video back in the page from its Picture in Picture window.
        function exitPictureInPicture() {
          var video = videoElement();
          if (!video) { return; }
          try {
            if (video.webkitPresentationMode === 'picture-in-picture') {
              video.webkitSetPresentationMode('inline');
            } else if (document.pictureInPictureElement || (embedDocument() || {}).pictureInPictureElement) {
              (embedDocument() || document).exitPictureInPicture();
            }
          } catch (e) {}
        }
        function seekTo(seconds) { command('seekTo', [seconds, true]); }
        function stopVideo() {
          clearInterval(handshake);
          watchedVideo = null;
          fullScreenVideo = null;
          playing = false;
          frame.src = 'about:blank';
        }

        setVideo('__VIDEO_ID__', __START_SECONDS__, '__PLAYBACK_ID__', __AUTOPLAY__);
      </script>
    </body>
    </html>
    """
}

