import AVFoundation
import AVKit
import Combine
import Foundation

/// Plays a downloaded file.
///
/// The app has two players, and which one runs is decided per video rather than per screen: a
/// video with a file in the Downloads folder plays through this, and everything else through
/// YouTube's embed. `PlayerManager` owns both and presents one face to the rest of the app, so
/// nothing above it — the mini bar, the lock screen, the up-next queue — knows or cares which is
/// playing. That is what makes a downloaded video playable from wherever it happens to be listed.
///
/// This one reports the same four things the embed's JavaScript bridge does: position, duration,
/// whether it is playing, and whether it is stalled — so `PlayerManager` can treat them alike.
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

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var currentURL: URL?

    init() {
        // The app's own transport and the lock screen drive playback; nothing should autoplay the
        // next thing behind their back.
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false

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

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: - Transport

    /// Points the player at a file. Re-loading the file already playing is a no-op, so replaying a
    /// video from a list doesn't restart what is already on screen.
    func load(url: URL) {
        guard currentURL != url else { return }
        currentURL = url

        let item = AVPlayerItem(url: url)
        observe(item)
        player.replaceCurrentItem(with: item)
    }

    func play() {
        player.play()
        onPlayingChanged?(true)
    }

    func pause() {
        player.pause()
        onPlayingChanged?(false)
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // Exact, because this is also what the lock screen's scrubber and a 15-second skip land
        // on, and snapping to the nearest keyframe makes both feel like they missed.
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
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
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onEnded?()
            }
        }

        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.reportProgress(at: self.player.currentTime())
                case .failed:
                    let reason = item.error?.localizedDescription
                        ?? "The downloaded file couldn't be played."
                    self.onFailure?(reason)
                default:
                    break
                }
            }
        }
    }

    private func reportProgress(at time: CMTime) {
        let elapsed = time.seconds.isFinite ? time.seconds : 0
        let total = player.currentItem?.duration.seconds ?? 0
        onProgress?(elapsed, total.isFinite ? total : 0)
    }
}
