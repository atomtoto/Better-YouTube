import Foundation
import UIKit
import WebKit

/// Why the home feed couldn't be read.
enum YouTubeFeedIssue: LocalizedError, Equatable {
    /// No youtube.com session on the device yet.
    case notSignedIn
    /// YouTube is asking for consent before it will show anything.
    case consentNeeded
    /// The page loaded and held no videos — a signed-out session, or markup that moved.
    case nothingFound
    case loadFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to youtube.com from Settings to see your own home feed."
        case .consentNeeded:
            return "YouTube is asking for consent. Open the sign-in screen in Settings once more and accept it there."
        case .nothingFound:
            return "YouTube's home page came back without any videos. The session may have expired — sign in again from Settings."
        case .loadFailed(let message):
            return message
        case .timedOut:
            return "YouTube's home page didn't finish loading."
        }
    }
}

/// The signed-in youtube.com session the real home feed is read from.
///
/// This is deliberately apart from `GoogleAuthService`. That one holds an OAuth token scoped to
/// the YouTube Data API and nothing else; this one holds youtube.com's own web cookies, in a
/// `WKWebsiteDataStore` of its own, because the personalized home feed exists nowhere else — the
/// Data API retired `activities?home=true` in 2016 and `search.list?relatedToVideoId` in 2023, and
/// YouTube's private endpoints answer a signed-out caller with an empty shell.
///
/// Nothing here reads or copies a cookie value: the store is handed to a web view, which uses it
/// the way a browser would. The app only ever learns *whether* a session cookie exists.
///
/// It stays dormant until you sign in from Settings — no session, no third segment on Home.
@MainActor
final class YouTubeWebSession: ObservableObject {
    static let shared = YouTubeWebSession()

    /// How the feed is drawn once it has been read.
    enum FeedRendering: String, CaseIterable, Identifiable {
        /// Take the ordering from YouTube, draw the cards here. The default.
        case nativeCards
        /// Show YouTube's own page and catch the taps.
        case youTubePage

        var id: String { rawValue }

        var title: String {
            switch self {
            case .nativeCards: return "Native cards"
            case .youTubePage: return "YouTube's page"
            }
        }
    }

    @Published private(set) var isSignedIn = false
    @Published var rendering: FeedRendering {
        didSet { UserDefaults.standard.set(rendering.rawValue, forKey: Self.renderingKey) }
    }

    static let homeURL = URL(string: "https://m.youtube.com/")!

    /// A full mobile Safari string. `WKWebView` otherwise sends a user agent that omits
    /// `Version/… Safari/…`, which is exactly how Google recognises an embedded web view and
    /// refuses to let you sign in. It is the one thing here that misrepresents anything, and it
    /// only makes the sign-in page treat this like the browser it is.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// Cookies that only exist once youtube.com has a signed-in session.
    private static let sessionCookies: Set<String> = ["LOGIN_INFO", "SID", "__Secure-1PSID", "__Secure-3PSID"]
    private static let renderingKey = "youtube_web_feed_rendering"
    /// A store of the app's own, so the player's web view keeps the default one and never sees
    /// these cookies. Any fixed UUID does, as long as it isn't all zeros.
    private static let storeIdentifier = UUID(uuidString: "3B4B6E1C-9E1E-4E7A-9C2D-6D5F1A7C8B20")!

    private let dataStore: WKWebsiteDataStore

    private init() {
        rendering = UserDefaults.standard.string(forKey: Self.renderingKey)
            .flatMap(FeedRendering.init(rawValue:)) ?? .nativeCards
        dataStore = WKWebsiteDataStore(forIdentifier: Self.storeIdentifier)
        Task { await refresh() }
    }

    /// A web view configuration on the shared session. Scripts are left to the caller: the feed
    /// page wants its taps intercepted and the reader doesn't.
    func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.allowsInlineMediaPlayback = true
        return configuration
    }

    /// Asks the cookie jar whether a session is there. Called after the sign-in sheet closes.
    func refresh() async {
        let cookies = await dataStore.httpCookieStore.allCookies()
        isSignedIn = cookies.contains { cookie in
            cookie.domain.contains("youtube.com") && Self.sessionCookies.contains(cookie.name)
        }
    }

    /// Forgets the session entirely — cookies, storage, caches.
    func signOut() async {
        await dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
        isSignedIn = false
    }

    /// The video id in a YouTube URL, if it is a watch link.
    static func videoId(in url: URL) -> String? {
        if url.host?.contains("youtu.be") == true {
            let id = url.lastPathComponent
            return isVideoId(id) ? id : nil
        }
        guard url.path.contains("/watch"),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let id = items.first(where: { $0.name == "v" })?.value,
              isVideoId(id) else { return nil }
        return id
    }

    private static func isVideoId(_ candidate: String) -> Bool {
        candidate.count == 11 && candidate.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }

    /// The key window, for the reader below to hang its web view on.
    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

// MARK: - Reading the feed

/// Reads the *order* of YouTube's home page, and nothing else.
///
/// The web view loads m.youtube.com as the signed-in session, and one line of JavaScript collects
/// the video ids out of the `watch?v=` links. Titles, channels, thumbnails and durations are then
/// fetched through the Data API like everywhere else in the app — so what YouTube contributes is
/// the ranking, which is the part no endpoint will sell, and everything on screen still comes from
/// the official API. It also makes the reader hard to break: a URL shape survives redesigns that a
/// class name does not.
@MainActor
final class YouTubeFeedReader {
    static let shared = YouTubeFeedReader()

    private var webView: WKWebView?
    private let bridge = FeedReaderNavigationBridge()
    fileprivate var loadContinuation: CheckedContinuation<Void, Error>?

    private init() {}

    /// The ids on the home page, in YouTube's order.
    func harvest() async throws -> [String] {
        guard YouTubeWebSession.shared.isSignedIn else { throw YouTubeFeedIssue.notSignedIn }

        let webView = attachedWebView()
        defer { webView.removeFromSuperview() }

        try await waitForLoad(YouTubeWebSession.homeURL, in: webView)

        if webView.url?.host?.contains("consent.") == true {
            throw YouTubeFeedIssue.consentNeeded
        }

        // The feed hydrates after the load event, so give it a moment — and a few more if the
        // first look comes back empty.
        for attempt in 0..<4 {
            try? await Task.sleep(nanoseconds: attempt == 0 ? 900_000_000 : 700_000_000)
            if let ids = try? await videoIds(in: webView), !ids.isEmpty { return ids }
        }
        throw YouTubeFeedIssue.nothingFound
    }

    private func videoIds(in webView: WKWebView) async throws -> [String] {
        let result = try await webView.evaluateJavaScript(Self.harvestScript)
        guard let joined = result as? String, !joined.isEmpty else { return [] }
        return joined.split(separator: ",").map(String.init)
    }

    /// A web view that isn't really on screen doesn't lay out, and a feed only renders what it
    /// believes is visible — the same lesson `PlayerHostView` learned about the player. So this
    /// one goes into the window at full size, behind everything, fully transparent and deaf to
    /// touches, and comes straight back out when the harvest is done.
    private func attachedWebView() -> WKWebView {
        let webView = self.webView ?? makeWebView()
        self.webView = webView

        if let window = YouTubeWebSession.keyWindow, webView.superview !== window {
            webView.removeFromSuperview()
            webView.frame = window.bounds
            window.insertSubview(webView, at: 0)
        }
        return webView
    }

    private func makeWebView() -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: YouTubeWebSession.shared.configuration())
        webView.customUserAgent = YouTubeWebSession.userAgent
        webView.navigationDelegate = bridge
        webView.isUserInteractionEnabled = false
        webView.alpha = 0
        return webView
    }

    private func waitForLoad(_ url: URL, in webView: WKWebView) async throws {
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            YouTubeFeedReader.shared.finishLoad(with: YouTubeFeedIssue.timedOut)
        }
        defer { watchdog.cancel() }

        // Nobody should be waiting, but a cancelled harvest could have left someone behind.
        finishLoad(with: CancellationError())

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    /// Resumes whoever is waiting on the page, once.
    fileprivate func finishLoad(with error: Error?) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    /// Every `watch?v=` link on the page, deduplicated, in document order.
    private static let harvestScript = """
    (function () {
      var ids = [];
      var seen = {};
      var links = document.querySelectorAll('a[href*="watch?v="]');
      for (var i = 0; i < links.length; i++) {
        var match = (links[i].getAttribute('href') || '').match(/[?&]v=([A-Za-z0-9_-]{11})/);
        if (!match || seen[match[1]]) { continue; }
        seen[match[1]] = true;
        ids.push(match[1]);
      }
      return ids.join(',');
    })()
    """
}

/// Page-level load results, which never reach an `evaluateJavaScript` call. Kept off the main
/// actor and forwarded, the way `PlayerNavigationBridge` does it for the player.
private final class FeedReaderNavigationBridge: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in YouTubeFeedReader.shared.finishLoad(with: nil) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            YouTubeFeedReader.shared.finishLoad(with: YouTubeFeedIssue.loadFailed(message))
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in
            YouTubeFeedReader.shared.finishLoad(with: YouTubeFeedIssue.loadFailed(message))
        }
    }
}
