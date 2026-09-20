import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

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
    /// Another page is being read on the one web view there is.
    case busy

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
            return "YouTube's page didn't finish loading."
        case .busy:
            return "Still reading the last page from YouTube. Try again in a moment."
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

    /// YouTube's own pages, in the edition that suits the screen they will be shown on.
    ///
    /// The phone reads `m.youtube.com` and the Mac reads `www.youtube.com`, for the same reason a
    /// browser would: on a Mac window the mobile site is a narrow column of enormous cards, and
    /// the desktop site holds several times as many videos in a first screenful — which the feed
    /// reader below also benefits from, since how much of a feed exists at all is decided by the
    /// height of the viewport. Nothing that reads these pages depends on which one it got: the
    /// harvest looks for `watch?v=` links, and the ad filter names both editions' renderers.
    #if os(macOS)
    nonisolated static let homeURL = URL(string: "https://www.youtube.com/")!
    /// The account's own notification inbox — the bell's actual output, which the Data API has
    /// no endpoint for.
    nonisolated static let notificationsURL = URL(string: "https://www.youtube.com/feed/notifications")!
    #else
    nonisolated static let homeURL = URL(string: "https://m.youtube.com/")!
    nonisolated static let notificationsURL = URL(string: "https://m.youtube.com/feed/notifications")!
    #endif

    /// A full Safari string, matching the edition above. `WKWebView` otherwise sends a user agent
    /// that omits `Version/… Safari/…`, which is exactly how Google recognises an embedded web
    /// view and refuses to let you sign in. It is the one thing here that misrepresents anything,
    /// and it only makes the sign-in page treat this like the browser it is.
    #if os(macOS)
    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    #else
    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    #endif

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
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        #endif
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
    private var isHarvesting = false
    private let bridge = FeedReaderNavigationBridge()
    fileprivate var loadContinuation: CheckedContinuation<Void, Error>?

    private init() {}

    /// How many videos a harvest aims for, and how hard it works for them.
    ///
    /// A feed renders what it believes is on screen and loads the rest as you scroll, so the
    /// number of videos this comes back with is decided by the height of the web view and by how
    /// often it is scrolled — not by anything YouTube limits. At a phone-sized viewport the page
    /// only ever held the three cards that fit in it.
    private static let targetCount = 40
    private static let passes = 8
    /// Several screens tall, so the first look already holds a column of videos rather than the
    /// two or three that fit on a phone.
    private static let readerHeight: CGFloat = 2400

    /// The video ids on one of YouTube's own pages, in the order it puts them in — the home feed
    /// by default, or the notification inbox.
    func harvest(from url: URL = YouTubeWebSession.homeURL) async throws -> [String] {
        await YouTubeWebSession.shared.refresh()
        guard YouTubeWebSession.shared.isSignedIn else { throw YouTubeFeedIssue.notSignedIn }
        // One web view, one page at a time: the home feed and the inbox would otherwise take
        // each other's load out from under them.
        guard !isHarvesting else { throw YouTubeFeedIssue.busy }
        isHarvesting = true
        defer { isHarvesting = false }

        let webView = attachedWebView()
        defer { webView.removeFromSuperview() }

        let isNotifications = url.path == "/feed/notifications"
        // The desktop bell exposes the inbox as a panel, whereas the mobile feed route may
        // render no notification links at all. Use the same signed-in cookie store.
        webView.customUserAgent = isNotifications
            ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            : YouTubeWebSession.userAgent
        let destination = isNotifications ? URL(string: "https://www.youtube.com/")! : url
        try await waitForLoad(destination, in: webView)

        if webView.url?.host?.contains("consent.") == true {
            throw YouTubeFeedIssue.consentNeeded
        }

        var ids: [String] = []
        var seen = Set<String>()
        // Passes that add nothing: two in a row and the page has no more to give.
        var barren = 0
        var openedBell = false
        var recognizedInbox = false

        for pass in 0..<Self.passes {
            // The feed hydrates after the load event, and again after every scroll.
            try await Task.sleep(nanoseconds: pass == 0 ? 1_200_000_000 : 700_000_000)

            let found: [String]
            if isNotifications {
                let result = try await webView.evaluateJavaScript(Self.notificationScript) as? [String: Any] ?? [:]
                recognizedInbox = recognizedInbox || (result["recognized"] as? Bool == true)
                found = result["ids"] as? [String] ?? []
                if !recognizedInbox, !openedBell {
                    openedBell = (try await webView.evaluateJavaScript(Self.openBellScript) as? Bool) == true
                }
            } else {
                found = try await videoIds(in: webView)
            }
            let before = ids.count
            for id in found where seen.insert(id).inserted { ids.append(id) }

            if ids.count >= Self.targetCount { break }
            barren = ids.count == before ? barren + 1 : 0
            if barren >= 2, !ids.isEmpty { break }

            _ = try? await webView.evaluateJavaScript(isNotifications ? Self.notificationScrollScript : Self.scrollScript)
        }

        if isNotifications, ids.isEmpty {
            if recognizedInbox { return [] }
            throw YouTubeFeedIssue.loadFailed("YouTube's notification panel could not be read. Open youtube.com from Settings, check that the bell opens your notifications, then retry.")
        }
        guard !ids.isEmpty else { throw YouTubeFeedIssue.nothingFound }
        return Array(ids.prefix(Self.targetCount))
    }

    private func videoIds(in webView: WKWebView) async throws -> [String] {
        let result = try await webView.evaluateJavaScript(Self.harvestScript)
        guard let joined = result as? String, !joined.isEmpty else { return [] }
        return joined.split(separator: ",").map(String.init)
    }

    /// A web view that isn't really on screen doesn't lay out, and a feed only renders what it
    /// believes is visible — the same lesson `PlayerHostView` learned about the player. So this
    /// one goes into the window behind everything, fully transparent and deaf to touches, and
    /// comes straight back out when the harvest is done.
    ///
    /// It is deliberately far taller than the screen: the viewport is what decides how much of
    /// the feed exists at all, and at the window's own height only three cards ever did.
    private func attachedWebView() -> WKWebView {
        let webView = self.webView ?? makeWebView()
        self.webView = webView

        #if os(macOS)
        guard let host = Platform.keyWindow?.contentView else { return webView }
        #else
        guard let host = Platform.keyWindow else { return webView }
        #endif

        if webView.superview !== host {
            webView.removeFromSuperview()
            webView.frame = CGRect(
                x: 0,
                y: 0,
                width: host.bounds.width,
                height: Self.readerHeight
            )
            #if os(macOS)
            host.addSubview(webView, positioned: .below, relativeTo: nil)
            #else
            host.insertSubview(webView, at: 0)
            #endif
        }
        return webView
    }

    private func makeWebView() -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: YouTubeWebSession.shared.configuration())
        webView.customUserAgent = YouTubeWebSession.userAgent
        webView.navigationDelegate = bridge
        // Invisible and deaf to input: it is behind the whole app and only there to lay out.
        #if os(macOS)
        webView.alphaValue = 0
        #else
        webView.isUserInteractionEnabled = false
        webView.alpha = 0
        #endif
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

    /// Every `watch?v=` link on the page that isn't an advert, deduplicated, in document order.
    ///
    /// A promoted video carries an ordinary watch link, so nothing about the link itself tells it
    /// apart — what does is the element it sits in. YouTube wraps its ad slots in custom elements
    /// named for what they are (`ytm-promoted-video-renderer`, `ytd-ad-slot-renderer`,
    /// `ytm-promoted-sparkles-web-renderer`), and element names are the durable part of that
    /// page: class names are minified and churn, tag names carry meaning and survive redesigns.
    /// So the walk up from each link looks at tag, id and the `data-is-ad` marker, and the href
    /// is checked against Google's ad redirectors on the way past.
    ///
    /// The pattern anchors "ad" to a whole word between separators, or it would throw away every
    /// "badge", "download" and "upload" on the page.
    private static let harvestScript = """
    (function () {
      var AD = /(^|[-_])ad(s|slot)?([-_]|$)|promoted|sparkles|advertiser/i;

      function isSponsored(node) {
        for (var el = node; el && el !== document.body; el = el.parentElement) {
          if (AD.test(el.tagName || '')) { return true; }
          if (el.id && AD.test(el.id)) { return true; }
          if (el.hasAttribute && el.hasAttribute('data-is-ad')) { return true; }
        }
        return false;
      }

      var ids = [];
      var seen = {};
      var links = document.querySelectorAll('a[href*="watch?v="]');
      for (var i = 0; i < links.length; i++) {
        var href = links[i].getAttribute('href') || '';
        if (/\\/aclk\\?|\\/pagead\\/|doubleclick|googleadservices/i.test(href)) { continue; }
        if (isSponsored(links[i])) { continue; }
        var match = href.match(/[?&]v=([A-Za-z0-9_-]{11})/);
        if (!match || seen[match[1]]) { continue; }
        seen[match[1]] = true;
        ids.push(match[1]);
      }
      return ids.join(',');
    })()
    """

    /// Asks for the next screenful. `true` at the end because `evaluateJavaScript` refuses to
    /// bring back an undefined result.
    private static let scrollScript = """
    window.scrollTo(0, document.documentElement.scrollHeight); true
    """

    // Only inspect notification renderers: home recommendations are not notifications.
    private static let notificationScript = """
    (() => {
      const ids = new Set();
      const nodes = document.querySelectorAll('ytd-notification-renderer, ytm-notification-renderer, ytm-notification-item-renderer');
      const visited = new WeakSet();
      let recognized = nodes.length > 0 || !!document.querySelector('ytd-notification-section-renderer, ytm-notification-section-renderer');
      function walk(value, notification = false) {
        if (!value || typeof value !== 'object' || visited.has(value)) return;
        visited.add(value);
        for (const [key, child] of Object.entries(value)) {
          const inside = notification || /notificationRenderer|notificationItemRenderer/.test(key);
          if (/notificationSectionRenderer/.test(key)) recognized = true;
          if (inside && key === 'videoId' && typeof child === 'string' && /^[A-Za-z0-9_-]{11}$/.test(child)) ids.add(child);
          walk(child, inside);
        }
      }
      for (const node of nodes) {
        walk(node.data || node.__data?.data, true);
        for (const link of node.querySelectorAll('a[href]')) {
          const url = new URL(link.href, location.origin);
          const id = url.searchParams.get('v') || url.pathname.match(/^\\/shorts\\/([A-Za-z0-9_-]{11})/)?.[1];
          if (id && /^[A-Za-z0-9_-]{11}$/.test(id)) ids.add(id);
        }
      }
      walk(window.ytInitialData);
      return {ids: [...ids], recognized};
    })()
    """

    private static let openBellScript = """
    (() => {
      const bell = document.querySelector('ytd-notification-topbar-button-renderer button, ytm-notification-topbar-button-renderer button, button[aria-label="Notifications"]');
      if (!bell) return false;
      bell.click(); return true;
    })()
    """

    private static let notificationScrollScript = """
    (() => {
      const panel = document.querySelector('ytd-multi-page-menu-renderer #sections, ytd-notification-section-renderer, ytm-notification-section-renderer');
      if (panel) panel.scrollTop = panel.scrollHeight;
      window.scrollTo(0, document.documentElement.scrollHeight);
      return true;
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
