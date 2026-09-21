import AVFoundation
import AVKit
import SwiftUI

#if os(macOS)
import AppKit

struct LocalPlayerSurface: NSViewRepresentable {
    let playback: LocalPlayback

    func makeNSView(context: Context) -> LocalPlayerHostView {
        LocalPlayerHostView(player: playback.player)
    }

    func updateNSView(_ nsView: LocalPlayerHostView, context: Context) {
        nsView.adopt(playback.player)
    }
}

final class LocalPlayerHostView: NSView {
    private let nativePlayer = AVPlayerView()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        nativePlayer.allowsPictureInPicturePlayback = true
        nativePlayer.controlsStyle = .floating
        nativePlayer.autoresizingMask = [.width, .height]
        addSubview(nativePlayer)
        adopt(player)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func adopt(_ player: AVPlayer) {
        guard nativePlayer.player !== player else { return }
        nativePlayer.player = player
    }
}

#else
import UIKit

/// AVKit owns the transport, full-screen presentation and Picture in Picture. The same
/// AVPlayer remains attached while SwiftUI moves the surface into and out of the mini player.
struct LocalPlayerSurface: UIViewControllerRepresentable {
    let playback: LocalPlayback
    var showsControls: Bool

    func makeCoordinator() -> Coordinator { Coordinator(playback: playback) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = playback.player
        controller.showsPlaybackControls = showsControls
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        // PlayerManager owns the lock-screen metadata and remote commands.
        controller.updatesNowPlayingInfoCenter = false
        controller.videoGravity = .resizeAspect
        controller.delegate = context.coordinator
        context.coordinator.attach(controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        // Do not hide the system controls during a full-screen transition or rotation.
        if !context.coordinator.isFullScreen {
            controller.showsPlaybackControls = showsControls
        }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.detach()
        controller.delegate = nil
        controller.player = nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
        let playback: LocalPlayback
        weak var controller: AVPlayerViewController?
        private var fullScreenController: LocalFullScreenPlayerController?
        private var avKitFullScreen = false
        var isFullScreen: Bool { fullScreenController != nil || avKitFullScreen }
        private var isInPictureInPicture = false
        private var isDetachedForBackground = false

        init(playback: LocalPlayback) { self.playback = playback }

        func attach(_ controller: AVPlayerViewController) {
            self.controller = controller
            playback.onFullScreenRequest = { [weak self] active in
                if active { self?.presentFullScreen() } else { self?.dismissFullScreen() }
            }
            NotificationCenter.default.addObserver(self, selector: #selector(background),
                name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(foreground),
                name: UIApplication.willEnterForegroundNotification, object: nil)
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            playback.onFullScreenRequest = nil
            fullScreenController?.onDismiss = nil
            fullScreenController?.player = nil
            fullScreenController = nil
            controller = nil
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func background() {
            guard !isInPictureInPicture else { return }
            isDetachedForBackground = true
            controller?.player = nil
        }

        @objc private func foreground() {
            guard isDetachedForBackground else { return }
            isDetachedForBackground = false
            controller?.player = playback.player
        }

        private func presentFullScreen() {
            guard fullScreenController == nil,
                  let controller,
                  controller.viewIfLoaded?.window != nil,
                  controller.presentedViewController == nil else { return }
            let fullScreen = LocalFullScreenPlayerController()
            fullScreen.player = playback.player
            fullScreen.showsPlaybackControls = true
            fullScreen.allowsPictureInPicturePlayback = true
            fullScreen.canStartPictureInPictureAutomaticallyFromInline = true
            fullScreen.updatesNowPlayingInfoCenter = false
            fullScreen.videoGravity = .resizeAspect
            fullScreen.modalPresentationStyle = .fullScreen
            fullScreen.delegate = self
            fullScreen.onDismiss = { [weak self, weak fullScreen] in
                guard let self, self.fullScreenController === fullScreen else { return }
                guard !self.isInPictureInPicture else { return }
                self.finishFullScreen()
            }
            fullScreenController = fullScreen
            controller.player = nil
            controller.present(fullScreen, animated: true) { [weak self] in
                self?.playback.onFullScreenChanged?(true)
            }
        }

        private func dismissFullScreen() {
            guard let fullScreenController else { return }
            fullScreenController.dismiss(animated: true)
        }

        private func finishFullScreen() {
            fullScreenController?.delegate = nil
            fullScreenController?.player = nil
            fullScreenController = nil
            if UIApplication.shared.applicationState != .background {
                controller?.player = playback.player
            }
            controller?.showsPlaybackControls = PlayerManager.shared.isExpanded
            playback.onFullScreenChanged?(false)
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            guard playerViewController === controller else { return }
            avKitFullScreen = true
            playback.onFullScreenChanged?(true)
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                if context.isCancelled {
                    self?.avKitFullScreen = false
                    self?.playback.onFullScreenChanged?(false)
                }
            }
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
            guard playerViewController === controller else { return }
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard !context.isCancelled else { return }
                self?.avKitFullScreen = false
                self?.playback.onFullScreenChanged?(false)
                playerViewController.showsPlaybackControls = PlayerManager.shared.isExpanded
            }
        }

        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            isInPictureInPicture = true
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            isInPictureInPicture = false
            if fullScreenController != nil,
               fullScreenController?.viewIfLoaded?.window == nil,
               !playback.wantsFullScreen {
                finishFullScreen()
            }
            if UIApplication.shared.applicationState == .background { background() }
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
            failedToStartPictureInPictureWithError error: Error) {
            isInPictureInPicture = false
            PlayerManager.shared.pictureInPictureError = error.localizedDescription
            if UIApplication.shared.applicationState == .background { background() }
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            foreground()
            PlayerManager.shared.expand()
            completionHandler(true)
        }
    }
}

/// AVPlayerViewController has no public programmatic "enter full screen" method on iOS. Presenting
/// a second controller is Apple's supported full-screen shape; this hook restores the inline
/// controller whether the user taps Done, rotates back, or the presentation is otherwise closed.
@MainActor
private final class LocalFullScreenPlayerController: AVPlayerViewController {
    var onDismiss: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDismiss?()
    }
}
#endif
