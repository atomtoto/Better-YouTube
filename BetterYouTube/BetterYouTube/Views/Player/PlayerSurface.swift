import SwiftUI
import WebKit

/// Hosts the app's single, long-lived player web view. It is deliberately the *same* instance
/// everywhere: reparenting a `WKWebView` keeps its JavaScript context — and therefore playback —
/// alive, which is what makes the mini player possible.
struct PlayerSurface: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // YouTube's embed refuses to start in a zero-sized, window-less player, so the manager
        // waits for this before loading anything.
        guard uiView.window != nil, uiView.bounds.width > 1, uiView.bounds.height > 1 else { return }
        PlayerManager.shared.surfaceDidAppear()
    }
}
