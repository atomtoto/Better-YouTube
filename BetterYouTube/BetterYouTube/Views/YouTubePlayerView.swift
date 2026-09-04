import SwiftUI
import WebKit

/// Plays a YouTube video using the official IFrame embed player. Using the embed player (rather
/// than extracting a raw stream URL) keeps playback compliant with YouTube's Terms of Service and
/// resilient to backend changes.
struct YouTubePlayerView: UIViewRepresentable {
    let videoId: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedVideoId != videoId else { return }
        context.coordinator.loadedVideoId = videoId

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
            <style>
                html, body { margin: 0; padding: 0; background: #000; height: 100%; }
                iframe { position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: 0; }
            </style>
        </head>
        <body>
            <iframe
                src="https://www.youtube-nocookie.com/embed/\(videoId)?playsinline=1&rel=0&modestbranding=1"
                frameborder="0"
                allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
                allowfullscreen>
            </iframe>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loadedVideoId: String?
    }
}

#Preview {
    YouTubePlayerView(videoId: "dQw4w9WgXcQ")
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
}
