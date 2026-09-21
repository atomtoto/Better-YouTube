import SwiftUI
import WebKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Hosts the app's single, long-lived player web view. It is deliberately the *same* instance
/// everywhere: reparenting a `WKWebView` keeps its JavaScript context — and therefore playback —
/// alive, which is what makes the mini player possible.
///
/// The two platforms differ only in which representable protocol they spell it with; the host
/// view below is where the interesting part lives, and it is the same idea on both.
#if os(macOS)
struct PlayerSurface: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> PlayerHostView {
        PlayerHostView(webView: webView)
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        nsView.adopt(webView)
    }
}
#else
struct PlayerSurface: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> PlayerHostView {
        PlayerHostView(webView: webView)
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        uiView.adopt(webView)
    }
}
#endif

/// A plain container for the shared web view.
///
/// It exists to report when the player is *actually* on screen. The representable's update method
/// runs immediately after the view is made, while it still has no window and a zero size, and
/// SwiftUI does not call it again just because layout happened — so relying on it meant the load
/// never fired and the player stayed black. Laying out and moving to a window do run at the right
/// moment, on both platforms.
#if os(macOS)

final class PlayerHostView: NSView {
    private weak var webView: WKWebView?

    init(webView: WKWebView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        adopt(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Moves the shared web view into this host. Re-parenting is what lets the same instance —
    /// still playing — travel between the mini and full-screen players.
    func adopt(_ webView: WKWebView) {
        self.webView = webView
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        addSubview(webView)
        needsLayout = true
    }

    /// AppKit views are bottom-left origin by default, which would leave the web view upside
    /// down relative to everything SwiftUI lays out around it.
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        webView?.frame = bounds
        notifyIfOnScreen()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        notifyIfOnScreen()
    }

    private func notifyIfOnScreen() {
        guard window != nil, bounds.width > 1, bounds.height > 1 else { return }
        PlayerManager.shared.surfaceDidAppear()
    }
}

#else

final class PlayerHostView: UIView {
    private weak var webView: WKWebView?

    init(webView: WKWebView) {
        super.init(frame: .zero)
        backgroundColor = .black
        adopt(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Moves the shared web view into this host. Re-parenting is what lets the same instance —
    /// still playing — travel between the mini and full-screen players.
    func adopt(_ webView: WKWebView) {
        self.webView = webView
        guard webView.superview !== self else { return }
        addSubview(webView)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView?.frame = bounds
        notifyIfOnScreen()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        notifyIfOnScreen()
    }

    private func notifyIfOnScreen() {
        guard window != nil, bounds.width > 1, bounds.height > 1 else { return }
        PlayerManager.shared.surfaceDidAppear()
    }
}

#endif
