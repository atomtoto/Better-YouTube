import AVFoundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Draws the downloaded-file player, in the same slot the embed's web view occupies.
///
/// It is the counterpart of `PlayerSurface`, and deliberately as thin: `PlayerContainerView` moves
/// one video rectangle between the docked bar and full screen, and neither surface should know
/// anything about that. What this one adds is the layer, and — on iOS — the background dance below.
#if os(macOS)
struct LocalPlayerSurface: NSViewRepresentable {
    let playback: LocalPlayback

    func makeNSView(context: Context) -> LocalPlayerHostView {
        LocalPlayerHostView(player: playback.player)
    }

    func updateNSView(_ nsView: LocalPlayerHostView, context: Context) {
        nsView.adopt(playback.player)
    }
}
#else
struct LocalPlayerSurface: UIViewRepresentable {
    let playback: LocalPlayback

    func makeUIView(context: Context) -> LocalPlayerHostView {
        LocalPlayerHostView(player: playback.player)
    }

    func updateUIView(_ uiView: LocalPlayerHostView, context: Context) {
        uiView.adopt(playback.player)
    }
}
#endif

#if os(macOS)

/// A view whose backing layer *is* the player layer.
///
/// No background dance here, and that is the whole difference from iOS. macOS never takes the
/// video away from a layer that has scrolled out of sight or whose app is behind another one — a
/// Mac app that is open is running — so the player simply stays where it is put.
final class LocalPlayerHostView: NSView {
    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer?.videoGravity = .resizeAspect
        adopt(player)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `layerClass` is a UIKit idea; AppKit asks the view to make its own backing layer.
    override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    override var isFlipped: Bool { true }

    func adopt(_ player: AVPlayer) {
        guard playerLayer?.player !== player else { return }
        playerLayer?.player = player
    }
}

#else

/// A view whose layer *is* the player layer.
///
/// The background handling is the part worth knowing about. iOS stops video the moment the layer
/// showing it leaves the screen — which is what backgrounding the app does — even with an audio
/// session that would happily carry on. Letting go of the player while the app is away and taking
/// it back on return is the documented way round that, and it is what keeps a downloaded video
/// playing with the screen locked, exactly as the embed does.
final class LocalPlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    /// Held onto while the layer isn't allowed to have it.
    private var detachedPlayer: AVPlayer?
    private var observers: [NSObjectProtocol] = []

    init(player: AVPlayer) {
        super.init(frame: .zero)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        adopt(player)
        observeAppState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func adopt(_ player: AVPlayer) {
        // While the app is in the background the layer is meant to be empty; remember the player
        // so coming back puts the right one back rather than a stale one.
        if detachedPlayer != nil {
            detachedPlayer = player
            return
        }
        guard playerLayer.player !== player else { return }
        playerLayer.player = player
    }

    private func observeAppState() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let player = self.playerLayer.player else { return }
            self.detachedPlayer = player
            self.playerLayer.player = nil
        })

        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let player = self.detachedPlayer else { return }
            self.detachedPlayer = nil
            self.playerLayer.player = player
        })
    }
}

#endif
