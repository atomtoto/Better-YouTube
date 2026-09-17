import AVFoundation
import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Keeps playback running when the app goes away, and puts it on the lock screen while it is.
///
/// Two halves. The audio session, claimed as `.playback`, is what lets iOS go on feeding the
/// player once the app is backgrounded or the screen locks — together with the `audio` entry in
/// `UIBackgroundModes`, without which the system stops the sound the moment the app leaves the
/// foreground. And the Now Playing centre, which is what makes that state legible: the title on
/// the lock screen, the artwork, the scrubber, and the buttons on headphones and in Control
/// Centre, all of which come back here to drive the same player the app's own transport does.
///
/// Only the first half is iOS's. macOS has no audio session to claim — an app that is open keeps
/// its sound — but it has the same Now Playing centre, which is what fills the media widget in
/// Control Centre and answers the keyboard's play/pause key. So the second half runs on both, and
/// with one addition: macOS wants the play state said outright, where iOS reads it off the rate.
///
/// The video itself keeps playing in YouTube's embed, ads and view count included. What changes
/// is only that the app stops throwing playback away when it loses the screen.
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    private var hasWiredCommands = false
    #if os(iOS)
    private var isSessionActive = false
    #endif
    /// The artwork already fetched, so a pause and a resume don't re-download it.
    private var artworkVideoId: String?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    private init() {}

    /// Claims the audio session. Called when a video starts, not at launch: until something is
    /// playing there is no reason to interrupt whatever else the phone is doing.
    func begin() {
        wireCommandsIfNeeded()
        #if os(iOS)
        guard !isSessionActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            isSessionActive = true
        } catch {
            // Nothing to do but carry on: playback still works in the foreground, and saying so
            // in the UI would be noise about a thing the listener can't act on.
            isSessionActive = false
        }
        #endif
    }

    /// Hands the audio session back when playback stops for good.
    func end() {
        artworkTask?.cancel()
        artworkVideoId = nil
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif

        #if os(iOS)
        guard isSessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isSessionActive = false
        #endif
    }

    /// Publishes what is playing. Called when the video, the play state, the duration or the
    /// position *jumps* — never on the position ticking, which the system extrapolates from the
    /// playback rate on its own.
    func update(video: Video?, isPlaying: Bool, elapsed: Double, duration: Double) {
        guard let video else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            #if os(macOS)
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            #endif
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: video.title,
            MPMediaItemPropertyArtist: video.channelTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork, artworkVideoId == video.id {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        // iOS infers this from the playback rate above; macOS shows nothing at all in Control
        // Centre until it is told, so it is said here as well.
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
        loadArtworkIfNeeded(for: video)
    }

    // MARK: - Artwork

    private func loadArtworkIfNeeded(for video: Video) {
        guard artworkVideoId != video.id, let url = video.thumbnailURL else { return }
        artworkVideoId = video.id
        artwork = nil

        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = PlatformImage(data: data),
                  !Task.isCancelled,
                  let self,
                  self.artworkVideoId == video.id else { return }

            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.artwork = artwork
            // Slot it into what is already published rather than rebuilding the lot: the
            // position in there is newer than anything this task knows.
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
        }
    }

    // MARK: - The lock screen's buttons

    private func wireCommandsIfNeeded() {
        guard !hasWiredCommands else { return }
        hasWiredCommands = true

        let commands = MPRemoteCommandCenter.shared()

        // These arrive on the main thread but through a closure that carries no isolation of its
        // own, so each one says as much rather than hopping — a lock-screen button that answered
        // an actor hop later would have missed its moment.
        commands.playCommand.addTarget { _ in
            MainActor.assumeIsolated {
                PlayerManager.shared.resume()
                return .success
            }
        }
        commands.pauseCommand.addTarget { _ in
            MainActor.assumeIsolated {
                PlayerManager.shared.pause()
                return .success
            }
        }
        commands.togglePlayPauseCommand.addTarget { _ in
            MainActor.assumeIsolated {
                PlayerManager.shared.togglePlayPause()
                return .success
            }
        }
        commands.nextTrackCommand.addTarget { _ in
            MainActor.assumeIsolated {
                let player = PlayerManager.shared
                guard !player.upNext.isEmpty else { return MPRemoteCommandHandlerStatus.noSuchContent }
                player.playNext()
                return MPRemoteCommandHandlerStatus.success
            }
        }
        commands.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return MainActor.assumeIsolated {
                PlayerManager.shared.seek(to: event.positionTime)
                return .success
            }
        }
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.addTarget { event in
            guard let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            return MainActor.assumeIsolated {
                let player = PlayerManager.shared
                player.seek(to: player.progress.currentTime + event.interval)
                return .success
            }
        }
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.addTarget { event in
            guard let event = event as? MPSkipIntervalCommandEvent else { return .commandFailed }
            return MainActor.assumeIsolated {
                let player = PlayerManager.shared
                player.seek(to: player.progress.currentTime - event.interval)
                return .success
            }
        }
    }
}
