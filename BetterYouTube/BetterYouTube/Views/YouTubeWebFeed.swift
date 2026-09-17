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
                .inlineNavigationBar()
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
private struct YouTubeWebPage {
    /// Whether a tap on a video should open the app's player instead of YouTube's.
    let interceptsVideoTaps: Bool

    /// Explicitly on the main actor: `makeUIView`/`makeNSView` are isolated by the representable
    /// protocol itself, and lifting the body out of them into a shared method left it nowhere.
    @MainActor
    fileprivate func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = YouTubeWebSession.shared.configuration()

        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Coordinator.withoutWebAuthn,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )

        if interceptsVideoTaps {
            configuration.userContentController.add(coordinator, name: Coordinator.handler)
            for script in [Coordinator.tapScript, Coordinator.hideAdsScript] {
                configuration.userContentController.addUserScript(
                    WKUserScript(
                        source: script,
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: false
                    )
                )
            }
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = YouTubeWebSession.userAgent
        webView.navigationDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: YouTubeWebSession.homeURL))
        return webView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(interceptsVideoTaps: interceptsVideoTaps)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let handler = "youTubeVideoTap"
        private let interceptsVideoTaps: Bool

        init(interceptsVideoTaps: Bool) {
            self.interceptsVideoTaps = interceptsVideoTaps
        }

        /// Takes WebAuthn off the page, so signing in offers a password rather than a passkey.
        ///
        /// `WKWebView` has no passkey support: only Safari and `ASWebAuthenticationSession` can
        /// complete one. But the interfaces a page tests for are present, so Google offers a
        /// passkey, the request goes nowhere, and sign-in dead-ends with no way back. Hiding
        /// them makes the page's own feature detection true, and Google falls straight through
        /// to the password it can actually accept.
        static let withoutWebAuthn = """
        (function () {
          try { delete window.PublicKeyCredential; } catch (e) {}
          try {
            Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true });
          } catch (e) {}
          try {
            Object.defineProperty(navigator, 'credentials', { value: undefined, configurable: true });
          } catch (e) {}
        })();
        """

        /// Takes the promoted cards out of the feed, so this rendering shows what the native one
        /// shows. The same slots the reader skips when it harvests ids, named rather than
        /// guessed: YouTube's ad renderers are custom elements, and a stylesheet can address
        /// them directly. A rule that matches nothing costs nothing, so retired names can stay.
        static let hideAdsScript = """
        (function () {
          var css = [
            'ytm-promoted-video-renderer',
            'ytm-compact-promoted-video-renderer',
            'ytm-promoted-sparkles-web-renderer',
            'ytm-promoted-sparkles-text-search-renderer',
            'ytm-companion-slot-renderer',
            'ytm-action-companion-ad-renderer',
            'ytm-ad-slot-renderer',
            'ytd-promoted-video-renderer',
            'ytd-promoted-sparkles-web-renderer',
            'ytd-ad-slot-renderer',
            'ytd-display-ad-renderer',
            'ytd-in-feed-ad-layout-renderer',
            '[data-is-ad]',
            '#player-ads',
            '#masthead-ad'
          ].join(',') + '{display:none !important;}';

          var style = document.createElement('style');
          style.textContent = css;
          (document.head || document.documentElement).appendChild(style);
        })();
        """

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

// The page above is the whole of it; all either platform adds is the protocol it is handed to
// SwiftUI through.
#if os(macOS)
extension YouTubeWebPage: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
#else
extension YouTubeWebPage: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
#endif
