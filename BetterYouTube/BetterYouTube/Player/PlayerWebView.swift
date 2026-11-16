import WebKit
#if os(iOS)
import UIKit
#endif

/// The player's web view. It never sees the screen's safe area: the player places it, and full
/// screen with the video zoomed to fill, a web view that knew it lay under the notch moved its
/// picture aside by the notch's width.
final class PlayerWebView: WKWebView {
    #if os(iOS)
    override var safeAreaInsets: UIEdgeInsets { .zero }
    #endif
}

/// Surfaces page-level load failures, which never reach the JavaScript bridge.
@MainActor
final class PlayerNavigationBridge: NSObject, WKNavigationDelegate {
    private weak var owner: PlayerManager?

    init(owner: PlayerManager) {
        self.owner = owner
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak owner] in owner?.handleLoadFailure(message) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak owner] in owner?.handleLoadFailure(message) }
    }
}

/// Bridges `window.webkit.messageHandlers.player` into its owning `PlayerManager`.
@MainActor
final class PlayerScriptBridge: NSObject, WKScriptMessageHandler {
    private weak var owner: PlayerManager?

    init(owner: PlayerManager) {
        self.owner = owner
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        handleMessage(body, frame: message.frameInfo)
    }

    func handleMessage(_ body: [String: Any], frame: WKFrameInfo? = nil) {
        guard let type = body["type"] as? String else { return }
        if type == "pipFrame" {
            owner?.pictureInPictureFrame = frame
            return
        }
        if type == "pip" {
            #if os(iOS)
            let active = body["active"] as? Bool ?? false
            Task { @MainActor [weak owner] in owner?.embedPictureInPictureDidChange(active) }
            #endif
            return
        }

        let event = PlayerEvent(
            type: type,
            time: body["time"] as? Double,
            duration: body["duration"] as? Double,
            state: body["state"] as? Int,
            videoID: body["videoID"] as? String,
            playbackID: body["playbackID"] as? String,
            payload: body["payload"] as? String
        )
        Task { @MainActor [weak owner] in
            owner?.handle(event)
        }
    }
}

