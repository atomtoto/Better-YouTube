import Foundation
import WebKit

/// Rates comments through the signed-in youtube.com page. The public YouTube Data API can list,
/// create and delete comments, but it has no comment-rating endpoint.
@MainActor
final class YouTubeWebCommentService {
    static let shared = YouTubeWebCommentService()

    private let reader = YouTubeFeedReader.comments
    private var busy = false

    private init() {}

    /// Toggles the page's actual rating; the Data API does not expose the viewer's comment rating.
    func toggleLike(commentID: String, videoID: String) async throws -> Bool {
        guard Self.isCommentID(commentID), YouTubeWebSession.videoId(in: Self.pageURL(videoID: videoID, commentID: commentID)) != nil else {
            throw YouTubeFeedIssue.loadFailed("YouTube returned an invalid comment reference.")
        }

        while busy { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        busy = true
        defer { busy = false }

        let session = YouTubeWebSession.shared
        let generation = session.feedGeneration
        return try await reader.withPlaylistPage(Self.pageURL(videoID: videoID, commentID: commentID)) { webView in
            guard session.isSignedIn, session.feedGeneration == generation else { throw CancellationError() }
            do {
                let result = try await webView.callAsyncJavaScript(
                    Self.actionScript,
                    arguments: ["commentID": commentID],
                    in: nil,
                    contentWorld: .page
                )
                guard let isLiked = result as? Bool else {
                    throw YouTubeFeedIssue.loadFailed("YouTube did not confirm the comment rating.")
                }
                return isLiked
            } catch {
                guard session.isSignedIn, session.feedGeneration == generation else { throw CancellationError() }
                if let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String {
                    throw YouTubeFeedIssue.loadFailed(message)
                }
                throw error
            }
        }
    }

    nonisolated static func pageURL(videoID: String, commentID: String) -> URL {
        var components = URLComponents(string: "https://www.youtube.com/watch")!
        components.queryItems = [
            URLQueryItem(name: "v", value: videoID),
            URLQueryItem(name: "lc", value: commentID),
            URLQueryItem(name: "hl", value: "en")
        ]
        return components.url!
    }

    private nonisolated static func isCommentID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256 && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }

    /// `lc` asks YouTube to render the requested conversation. The page has used several comment
    /// component shapes over time, so identification reads both attributes and the component's
    /// data model; button lookup uses its accessible label instead of a transient CSS class.
    private static let actionScript = #"""
    const wanted = String(commentID);
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

    function containsID(value, depth = 0, seen = new WeakSet()) {
        if (value === wanted) return true;
        if (!value || typeof value !== 'object' || depth > 7 || seen.has(value)) return false;
        seen.add(value);
        for (const [key, child] of Object.entries(value)) {
            if ((key === 'commentId' || key === 'commentID') && child === wanted) return true;
            if (containsID(child, depth + 1, seen)) return true;
        }
        return false;
    }

    function targetComment() {
        const selectors = 'ytd-comment-thread-renderer,ytd-comment-view-model,ytm-comment-thread-renderer';
        return Array.from(document.querySelectorAll(selectors)).find(element => {
            if (element.getAttribute('comment-id') === wanted || element.id === wanted) return true;
            return containsID(element.data) || containsID(element.__data?.data);
        });
    }

    let comment = null;
    for (let attempt = 0; attempt < 30 && !comment; attempt++) {
        comment = targetComment();
        if (comment) break;
        window.scrollTo(0, Math.max(document.body.scrollHeight, document.documentElement.scrollHeight));
        await sleep(300);
    }
    if (!comment) throw new Error('YouTube could not find this comment on its page. Refresh the comments and retry.');

    function label(element) {
        return String(element.getAttribute('aria-label') || element.getAttribute('title') || '').trim().toLowerCase();
    }
    function isLikeLabel(value) {
        return /^(like|unlike)(\b|\s|$)/.test(value) && !value.includes('dislike');
    }
    const controls = comment.querySelector('#action-buttons, #toolbar, ytd-comment-action-buttons-renderer, ytm-comment-action-buttons-renderer') || comment;
    const candidates = Array.from(controls.querySelectorAll('button,[role="button"],tp-yt-paper-button,yt-icon-button,ytd-toggle-button-renderer,yt-button-shape'));
    const control = candidates.find(candidate => {
        if (isLikeLabel(label(candidate))) return true;
        const tooltip = candidate.querySelector('#tooltip,yt-formatted-string[aria-label],yt-formatted-string[role="tooltip"]');
        return tooltip && isLikeLabel(label(tooltip) || tooltip.textContent.trim().toLowerCase());
    }) || controls.querySelector('#like-button');
    const button = control?.matches('button,[role="button"],tp-yt-paper-button')
        ? control : control?.querySelector('button,[role="button"],tp-yt-paper-button');
    if (!button) throw new Error('YouTube changed its comment controls. Update the app and retry.');

    function selected() {
        const pressed = [button, control].map(element => element.getAttribute('aria-pressed')).find(value => value !== null);
        if (pressed !== undefined) return pressed === 'true';
        if (control.hasAttribute('is-toggled')) return control.getAttribute('is-toggled') !== 'false';
        const tooltip = control.querySelector('#tooltip,yt-formatted-string[aria-label],yt-formatted-string[role="tooltip"]');
        return [label(button), label(control), tooltip && (label(tooltip) || tooltip.textContent.trim().toLowerCase())]
            .some(value => value && value.startsWith('unlike'));
    }
    const wasLiked = selected();
    button.click();
    await sleep(600);
    return !wasLiked;
    """#
}
