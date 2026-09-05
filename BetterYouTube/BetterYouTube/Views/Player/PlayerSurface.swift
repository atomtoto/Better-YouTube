import SwiftUI
import WebKit

/// Hosts the app's single, long-lived player web view. It is deliberately the *same* instance
/// everywhere: reparenting a `WKWebView` keeps its JavaScript context — and therefore playback —
/// alive, which is what makes the mini player possible.
struct PlayerSurface: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
