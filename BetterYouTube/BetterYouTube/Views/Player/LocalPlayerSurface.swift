import AVFoundation
import AVKit
import SwiftUI

/// The picture of a downloaded file, or of a stream AVPlayer plays: a bare `AVPlayerLayer`. The
/// controls over it are the app's own — the same `PlayerControlsOverlay` a streamed video gets —
/// so this only draws the video and owns AVKit's Picture in Picture controller, which is Apple's
/// way of offering Picture in Picture under custom controls.
///
/// The same AVPlayer stays attached while SwiftUI moves the surface into and out of the mini
/// player.
#if os(macOS)
import AppKit

struct LocalPlayerSurface: NSViewRepresentable {
    let playback: LocalPlayback

    func makeCoordinator() -> Coordinator { Coordinator(playback: playback) }

    func makeNSView(context: Context) -> LocalPlayerLayerView {
        let view = LocalPlayerLayerView()
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: LocalPlayerLayerView, context: Context) {
        if view.playerLayer.player !== playback.player { view.playerLayer.player = playback.player }
    }

    static func dismantleNSView(_ view: LocalPlayerLayerView, coordinator: Coordinator) {
        coordinator.detach()
        view.playerLayer.player = nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
        let playback: LocalPlayback
        private var pictureInPicture: AVPictureInPictureController?

        init(playback: LocalPlayback) { self.playback = playback }

        func attach(_ view: LocalPlayerLayerView) {
            view.playerLayer.player = playback.player
            if AVPictureInPictureController.isPictureInPictureSupported() {
                pictureInPicture = AVPictureInPictureController(playerLayer: view.playerLayer)
                pictureInPicture?.delegate = self
            }
            playback.onPictureInPictureRequest = { [weak self] in
                guard let pictureInPicture = self?.pictureInPicture,
                      pictureInPicture.isPictureInPicturePossible else { return false }
                pictureInPicture.startPictureInPicture()
                return true
            }
        }

        func detach() {
            playback.onPictureInPictureRequest = nil
            pictureInPicture?.delegate = nil
            pictureInPicture = nil
        }

        func pictureInPictureController(_ controller: AVPictureInPictureController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            NSApp.activate()
            PlayerManager.shared.expand()
            completionHandler(true)
        }

        func pictureInPictureController(_ controller: AVPictureInPictureController,
            failedToStartPictureInPictureWithError error: Error) {
            PlayerManager.shared.pictureInPictureError = error.localizedDescription
        }
    }
}

final class LocalPlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Without this the layer animates to every new size the morph passes through.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

#else
import UIKit

struct LocalPlayerSurface: UIViewRepresentable {
    let playback: LocalPlayback

    func makeCoordinator() -> Coordinator { Coordinator(playback: playback) }

    func makeUIView(context: Context) -> LocalPlayerLayerView {
        let view = LocalPlayerLayerView()
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: LocalPlayerLayerView, context: Context) {}

    static func dismantleUIView(_ view: LocalPlayerLayerView, coordinator: Coordinator) {
        coordinator.detach()
        view.playerLayer.player = nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency AVPictureInPictureControllerDelegate,
        @preconcurrency AVPlayerViewControllerDelegate {
        let playback: LocalPlayback
        private weak var view: LocalPlayerLayerView?
        private var pictureInPicture: AVPictureInPictureController?
        /// iOS's own full-screen player, for when Settings asks for it rather than the app's.
        private var fullScreenController: LocalFullScreenPlayerController?
        private var isInPictureInPicture = false {
            didSet { playback.isInPictureInPicture = isInPictureInPicture }
        }
        /// Picture in Picture AVKit started on its own as the app was left, put back on return.
        private var startedPictureInPictureOnLeaving = false
        private var isDetachedForBackground = false

        init(playback: LocalPlayback) { self.playback = playback }

        func attach(_ view: LocalPlayerLayerView) {
            self.view = view
            view.playerLayer.player = playback.player
            if AVPictureInPictureController.isPictureInPictureSupported() {
                pictureInPicture = AVPictureInPictureController(playerLayer: view.playerLayer)
                pictureInPicture?.canStartPictureInPictureAutomaticallyFromInline = AutoPictureInPicturePreference.isEnabled
                pictureInPicture?.delegate = self
            }
            playback.onPictureInPictureRequest = { [weak self] in
                guard let pictureInPicture = self?.pictureInPicture,
                      pictureInPicture.isPictureInPicturePossible else { return false }
                pictureInPicture.startPictureInPicture()
                return true
            }
            playback.onFullScreenRequest = { [weak self] active in
                if active { self?.presentFullScreen() } else { self?.dismissFullScreen() }
            }
            view.onWindow = { [weak self] in
                guard let self, self.playback.wantsFullScreen else { return }
                self.presentFullScreen()
            }
            NotificationCenter.default.addObserver(self, selector: #selector(willResignActive),
                name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(background),
                name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(foreground),
                name: UIApplication.willEnterForegroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(didBecomeActive),
                name: UIApplication.didBecomeActiveNotification, object: nil)
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            playback.onPictureInPictureRequest = nil
            playback.onFullScreenRequest = nil
            pictureInPicture?.delegate = nil
            pictureInPicture = nil
            playback.isInPictureInPicture = false
            fullScreenController?.onDismiss = nil
            fullScreenController?.player = nil
            fullScreenController = nil
            view?.onWindow = nil
            view = nil
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        /// A layer still showing the video is what makes iOS pause it in the background, so the
        /// player is taken off it there — unless Picture in Picture is the one showing it.
        @objc private func background() {
            guard !isInPictureInPicture else { return }
            isDetachedForBackground = true
            view?.playerLayer.player = nil
        }

        @objc private func foreground() {
            guard isDetachedForBackground else { return }
            isDetachedForBackground = false
            if fullScreenController == nil { view?.playerLayer.player = playback.player }
        }

        /// Settings → Playback → Picture in Picture decides whether AVKit moves a playing video
        /// to its window on the way to the Home Screen. Read at the last moment, so a change in
        /// Settings counts without the surface being rebuilt.
        @objc private func willResignActive() {
            let automatic = AutoPictureInPicturePreference.isEnabled
            pictureInPicture?.canStartPictureInPictureAutomaticallyFromInline = automatic
            fullScreenController?.canStartPictureInPictureAutomaticallyFromInline = automatic
        }

        /// Back in the app: Picture in Picture AVKit started on the way out goes back into the
        /// player, as in the YouTube app.
        @objc private func didBecomeActive() {
            guard startedPictureInPictureOnLeaving else { return }
            startedPictureInPictureOnLeaving = false
            if pictureInPicture?.isPictureInPictureActive == true {
                pictureInPicture?.stopPictureInPicture()
            }
        }

        // MARK: Picture in Picture

        func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
            pictureInPictureWillStart()
        }

        func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
            pictureInPictureDidStop()
        }

        func pictureInPictureWillStart() {
            isInPictureInPicture = true
            // Started by AVKit as the app was left, rather than from the player's button.
            startedPictureInPictureOnLeaving = UIApplication.shared.applicationState != .active
        }

        func pictureInPictureDidStop() {
            isInPictureInPicture = false
            startedPictureInPictureOnLeaving = false
            if UIApplication.shared.applicationState == .background { background() }
        }

        func pictureInPictureController(_ controller: AVPictureInPictureController,
            failedToStartPictureInPictureWithError error: Error) {
            isInPictureInPicture = false
            PlayerManager.shared.pictureInPictureError = error.localizedDescription
            if UIApplication.shared.applicationState == .background { background() }
        }

        func pictureInPictureController(_ controller: AVPictureInPictureController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            foreground()
            PlayerManager.shared.expand()
            completionHandler(true)
        }

        // MARK: iOS's full-screen player

        /// AVPlayerViewController presented over the app is Apple's supported full-screen shape.
        /// It takes the player while it is up, and gives it back however it is closed.
        private func presentFullScreen() {
            guard fullScreenController == nil,
                  let view, let window = view.window,
                  var presenter = window.rootViewController else { return }
            while let presented = presenter.presentedViewController { presenter = presented }

            let fullScreen = LocalFullScreenPlayerController()
            fullScreen.player = playback.player
            fullScreen.allowsPictureInPicturePlayback = true
            fullScreen.canStartPictureInPictureAutomaticallyFromInline = AutoPictureInPicturePreference.isEnabled
            // PlayerManager owns the lock-screen metadata and remote commands.
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
            view.playerLayer.player = nil
            presenter.present(fullScreen, animated: true) { [weak self] in
                self?.playback.onFullScreenChanged?(true)
            }
        }

        private func dismissFullScreen() {
            fullScreenController?.dismiss(animated: true)
        }

        private func finishFullScreen() {
            fullScreenController?.delegate = nil
            fullScreenController?.player = nil
            fullScreenController = nil
            if UIApplication.shared.applicationState != .background {
                view?.playerLayer.player = playback.player
            }
            playback.onFullScreenChanged?(false)
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

final class LocalPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    /// Full screen can be asked for before the view is in a window — a downloaded video started
    /// with the phone already on its side — and can only be presented once it is.
    var onWindow: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onWindow?() }
    }

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Restores the inline picture whether the user taps Done, rotates back, or the presentation
/// is otherwise closed.
@MainActor
private final class LocalFullScreenPlayerController: AVPlayerViewController {
    var onDismiss: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDismiss?()
    }
}
#endif
