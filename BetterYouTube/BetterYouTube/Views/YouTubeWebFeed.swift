import SwiftUI
import WebKit

/// Where you sign in to youtube.com, on the session `YouTubeWebSession` keeps.
///
/// It is YouTube's own sign-in, in a web view, exactly as a browser would show it — the app never
/// sees what you type and never reads a cookie back out of the store.
struct YouTubeSignInView: View {
    @EnvironmentObject private var session: YouTubeWebSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            YouTubeWebPage(interceptsVideoTaps: false)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("youtube.com")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            Task {
                                await session.refresh()
                                dismiss()
                            }
                        }
                    }
                }
        }
    }
}

/// YouTube's own home page, shown in place of the app's cards when Settings asks for it.
///
/// Taps on a video are caught and handed to the app's player, so the mini player, the history and
/// the landscape full screen all keep working. Everything else navigates as YouTube intends.
struct YouTubeWebFeedView: View {
    var body: some View {
        YouTubeWebPage(interceptsVideoTaps: true)
    }
}

/// The web view behind both of the above.
private struct YouTubeWebPage: UIViewRepresentable {
    /// Whether a tap on a video should open the app's player instead of YouTube's.
    let interceptsVideoTaps: Bool

    func makeUIView(context: Context) -> WKWebView {
        let configuration = YouTubeWebSession.shared.configuration()

        if interceptsVideoTaps {
            configuration.userContentController.add(context.coordinator, name: Coordinator.handler)
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: Coordinator.tapScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = YouTubeWebSession.userAgent
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: YouTubeWebSession.homeURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(interceptsVideoTaps: interceptsVideoTaps)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let handler = "youTubeVideoTap"
        private let interceptsVideoTaps: Bool

        init(interceptsVideoTaps: Bool) {
            self.interceptsVideoTaps = interceptsVideoTaps
        }

        /// The mobile site routes in JavaScript, so most taps never become a navigation the
        /// delegate below would see. This catches the click first — capture phase, before
        /// YouTube's own handlers — and hands the id over.
        static let tapScript = """
        document.addEventListener('click', function (event) {
          var target = event.target;
          var link = target && target.closest ? target.closest('a[href*="watch?v="]') : null;
          if (!link) { return; }
          var match = (link.getAttribute('href') || '').match(/[?&]v=([A-Za-z0-9_-]{11})/);
          if (!match) { return; }
          event.preventDefault();
          event.stopPropagation();
          try { window.webkit.messageHandlers.youTubeVideoTap.postMessage(match[1]); } catch (e) {}
        }, true);
        """

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let videoId = message.body as? String else { return }
            Task { @MainActor in await PlayerManager.shared.open(videoId: videoId) }
        }

        /// The belt to the script's braces: a watch link that does become a real navigation —
        /// a long-press "open", a redirect — is turned into the app's player just the same.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard interceptsVideoTaps,
                  navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url,
                  let videoId = YouTubeWebSession.videoId(in: url) else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            Task { @MainActor in await PlayerManager.shared.open(videoId: videoId) }
        }
    }
}
