import SwiftUI
import WebKit

/// Hosts the app's single, long-lived player web view. It is deliberately the *same* instance
/// everywhere: reparenting a `WKWebView` keeps its JavaScript context — and therefore playback —
/// alive, which is what makes the mini player possible.
struct PlayerSurface: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> PlayerHostView {
        PlayerHostView(webView: webView)
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        uiView.adopt(webView)
    }
}

/// A plain container for the shared web view.
///
/// It exists to report when the player is *actually* on screen. `updateUIView` runs immediately
/// after `makeUIView`, while the view still has no window and a zero size, and SwiftUI does not
/// call it again just because layout happened — so relying on it meant the load never fired and
/// the player stayed black. `layoutSubviews` and `didMoveToWindow` do run at the right moment.
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
