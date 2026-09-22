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

    func setLiked(_ liked: Bool, commentID: String, videoID: String) async throws {
        guard Self.isCommentID(commentID), YouTubeWebSession.videoId(in: Self.pageURL(videoID: videoID, commentID: commentID)) != nil else {
            throw YouTubeFeedIssue.loadFailed("YouTube returned an invalid comment reference.")
        }

        while busy { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        busy = true
        defer { busy = false }

        let session = YouTubeWebSession.shared
        let generation = session.feedGeneration
        try await reader.withPlaylistPage(Self.pageURL(videoID: videoID, commentID: commentID)) { webView in
            guard session.isSignedIn, session.feedGeneration == generation else { throw CancellationError() }
            do {
                _ = try await webView.callAsyncJavaScript(
                    Self.actionScript,
                    arguments: ["commentID": commentID, "shouldLike": liked],
                    in: nil,
                    contentWorld: .page
                )
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
    const desired = Boolean(shouldLike);
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

    function label(button) {
        return String(button.getAttribute('aria-label') || button.title || '').trim();
    }
    const button = Array.from(comment.querySelectorAll('button,[role="button"],tp-yt-paper-button'))
        .find(candidate => {
            const value = label(candidate).toLowerCase();
            return (value.startsWith('like') || value.startsWith('unlike')) && !value.includes('dislike');
        });
    if (!button) throw new Error('YouTube changed its comment controls. Update the app and retry.');

    const currentLabel = label(button).toLowerCase();
    const selected = button.getAttribute('aria-pressed') === 'true' || currentLabel.startsWith('unlike');
    if (selected !== desired) {
        button.click();
        await sleep(900);
    }
    return true;
    """#
}
