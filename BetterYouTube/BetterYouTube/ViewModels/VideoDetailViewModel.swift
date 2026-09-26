import Foundation

/// Backs the details shown under the expanded player: the enriched video plus its comments.
@MainActor
final class VideoDetailViewModel: ObservableObject {
    @Published private(set) var video: Video
    @Published private(set) var channel: Channel?
    @Published private(set) var channelAvatarURL: URL?
    @Published private(set) var comments: [VideoComment] = []
    @Published private(set) var isLoadingComments = false
    @Published var errorMessage: String?
    @Published var commentsError: String?
    @Published var commentActionError: String?
    @Published private(set) var repliesByParent: [String: [VideoComment]] = [:]
    @Published private(set) var loadingReplies: Set<String> = []
    @Published private(set) var isPostingComment = false
    @Published private(set) var sendingReplyTo: Set<String> = []
    @Published private(set) var ratingComments: Set<String> = []
    /// The account's own rating for this video, as YouTube holds it. `.unspecified` until it
    /// has been read back — the like button only fills in once it is known.
    @Published private(set) var rating: VideoRating = .unspecified
    /// Set while a like is in flight, so the button can't be tapped into a queue of writes.
    @Published private(set) var isRating = false
    /// Why a like didn't take — most often "sign in with Google", which is the whole answer.
    @Published var ratingError: String?

    private let service: YouTubeAPIService
    private var loadedReplyParents: Set<String> = []
    /// What this session's likes have added to YouTube's own figure, so a refresh of the
    /// details doesn't quietly undo the tap that was made while it was in flight.
    private var likeCountAdjustment = 0

    init(video: Video, service: YouTubeAPIService = .shared) {
        self.video = video
        self.service = service
        self.channelAvatarURL = ChannelAvatarCache.shared.avatarURL(for: video.channelId)
    }

    var isLiked: Bool { rating == .like }
    var isDisliked: Bool { rating == .dislike }

    func loadAll() async {
        async let details: Void = refreshDetails()
        async let comments: Void = loadComments()
        async let ratingState: Void = loadRating()
        async let channelInfo: Void = loadChannel()
        _ = await (details, comments, ratingState, channelInfo)
        if channel == nil && !video.channelId.isEmpty {
            await loadChannel()
        }
    }

    // MARK: - Channel

    func loadChannel() async {
        let channelId = video.channelId
        guard !channelId.isEmpty else { return }

        if channel != nil && channelAvatarURL != nil { return }

        if channelAvatarURL == nil, let cached = ChannelAvatarCache.shared.avatarURL(for: channelId) {
            channelAvatarURL = cached
        }

        if channel == nil {
            if let fetched = try? await service.channel(id: channelId) {
                channel = fetched
                if let url = fetched.thumbnailURL {
                    channelAvatarURL = url
                    ChannelAvatarCache.shared.setAvatarURL(url, for: channelId)
                }
            }
        }

        if channelAvatarURL == nil {
            if let fetchedURL = await ChannelAvatarCache.shared.fetchAvatar(for: channelId, service: service) {
                channelAvatarURL = fetchedURL
            }
        }
    }

    // MARK: - The like

    /// Reads back what the account has rated this video (1 unit). Signed out there is nothing
    /// to read: the button stays hollow and says so when tapped.
    func loadRating() async {
        guard GoogleAuthService.shared.isSignedIn else {
            rating = .unspecified
            return
        }
        rating = (try? await service.rating(videoId: video.id)) ?? .unspecified
    }

    func toggleLike() async {
        await setRating(isLiked ? .none : .like)
    }

    func toggleDislike() async {
        await setRating(isDisliked ? .none : .dislike)
    }

    /// Keep the two rating buttons and the public like count in sync through one write path.
    private func setRating(_ target: VideoRating) async {
        guard !isRating else { return }
        let previous = rating
        let likeDelta = (target == .like ? 1 : 0) - (previous == .like ? 1 : 0)

        isRating = true
        ratingError = nil
        rating = target
        adjustLikeCount(by: likeDelta)

        do {
            try await service.rate(videoId: video.id, rating: target)
        } catch {
            rating = previous
            adjustLikeCount(by: -likeDelta)
            ratingError = error.localizedDescription
        }
        isRating = false
    }

    /// Nudges the displayed count so the number agrees with the button. YouTube's own figure is
    /// cached and lags a tap by minutes, so waiting for it would look like nothing happened.
    private func adjustLikeCount(by delta: Int) {
        likeCountAdjustment += delta
        guard let count = video.likeCount else { return }
        video.likeCount = max(0, count + delta)
    }

    /// Feed and playlist entries arrive without statistics; fetch the full record.
    func refreshDetails() async {
        do {
            guard var updated = try await service.video(id: video.id) else { return }
            // This lands a moment after the screen opens, which is long enough for a like to
            // have been tapped; YouTube's count won't carry it for minutes yet, so re-apply it.
            updated.likeCount = updated.likeCount.map { max(0, $0 + likeCountAdjustment) }
            video = updated
            if channelAvatarURL == nil {
                channelAvatarURL = ChannelAvatarCache.shared.avatarURL(for: updated.channelId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadComments() async {
        guard !isLoadingComments else { return }
        isLoadingComments = true
        commentsError = nil
        do {
            comments = try await service.comments(videoId: video.id)
        } catch {
            commentsError = error.localizedDescription
        }
        isLoadingComments = false
    }

    // MARK: - Comment conversations

    // MARK: - Comment actions

    func toggleCommentLike(_ comment: VideoComment) async {
        guard let index = comments.firstIndex(where: { $0.id == comment.id }),
              !ratingComments.contains(comment.id) else { return }

        let isLiked = comments[index].isLiked
        let likeCount = comments[index].likeCount
        ratingComments.insert(comment.id)
        commentActionError = nil
        defer { ratingComments.remove(comment.id) }
        // Optimistic update
        comments[index].isLiked = !isLiked
        comments[index].likeCount = max(0, likeCount + (isLiked ? -1 : 1))

        do {
            let actual = try await YouTubeWebCommentService.shared.toggleLike(commentID: comment.id, videoID: video.id)
            comments[index].isLiked = actual
            comments[index].likeCount = max(0, likeCount + (actual ? 1 : 0) - (isLiked ? 1 : 0))
        } catch {
            // Revert on failure
            comments[index].isLiked = isLiked
            comments[index].likeCount = likeCount
            commentActionError = error.localizedDescription
        }
    }

    func addComment(_ rawText: String) async -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isPostingComment else { return false }
        isPostingComment = true
        commentActionError = nil
        defer { isPostingComment = false }

        do {
            let comment = try await service.addComment(videoId: video.id, text: text)
            comments.insert(comment, at: 0)
            return true
        } catch {
            commentActionError = error.localizedDescription
            return false
        }
    }

    func loadReplies(to parentId: String) async {
        guard !loadedReplyParents.contains(parentId), !loadingReplies.contains(parentId) else { return }
        loadingReplies.insert(parentId)
        commentActionError = nil
        defer { loadingReplies.remove(parentId) }

        do {
            repliesByParent[parentId] = try await service.replies(to: parentId)
            loadedReplyParents.insert(parentId)
        } catch {
            commentActionError = error.localizedDescription
        }
    }

    func reply(_ rawText: String, to parentId: String) async -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sendingReplyTo.contains(parentId) else { return false }
        sendingReplyTo.insert(parentId)
        commentActionError = nil
        defer { sendingReplyTo.remove(parentId) }

        do {
            let reply = try await service.reply(to: parentId, text: text)
            repliesByParent[parentId, default: []].append(reply)
            return true
        } catch {
            commentActionError = error.localizedDescription
            return false
        }
    }
}
