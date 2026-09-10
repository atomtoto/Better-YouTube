import Foundation

/// Backs the details shown under the expanded player: the enriched video plus its comments.
@MainActor
final class VideoDetailViewModel: ObservableObject {
    @Published private(set) var video: Video
    @Published private(set) var comments: [VideoComment] = []
    @Published private(set) var isLoadingComments = false
    @Published var errorMessage: String?
    @Published var commentsError: String?
    /// The account's own rating for this video, as YouTube holds it. `.unspecified` until it
    /// has been read back — the like button only fills in once it is known.
    @Published private(set) var rating: VideoRating = .unspecified
    /// Set while a like is in flight, so the button can't be tapped into a queue of writes.
    @Published private(set) var isRating = false
    /// Why a like didn't take — most often "sign in with Google", which is the whole answer.
    @Published var ratingError: String?

    private let service: YouTubeAPIService

    init(video: Video, service: YouTubeAPIService = .shared) {
        self.video = video
        self.service = service
    }

    var isLiked: Bool { rating == .like }

    func loadAll() async {
        async let details: Void = refreshDetails()
        async let comments: Void = loadComments()
        async let ratingState: Void = loadRating()
        _ = await (details, comments, ratingState)
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

    /// Likes the video on YouTube, or takes the like back — a real `videos.rate` write, so it
    /// shows up in Liked videos in the YouTube app too. 50 quota units a tap.
    ///
    /// The button and the count move first and are put back if YouTube refuses, because the
    /// write takes a round trip and a like that lags behind the thumb feels broken.
    func toggleLike() async {
        guard !isRating else { return }
        let previous = rating
        let target: VideoRating = isLiked ? .none : .like

        isRating = true
        ratingError = nil
        rating = target
        adjustLikeCount(by: target == .like ? 1 : -1)

        do {
            try await service.rate(videoId: video.id, rating: target)
        } catch {
            rating = previous
            adjustLikeCount(by: target == .like ? -1 : 1)
            ratingError = error.localizedDescription
        }
        isRating = false
    }

    /// Nudges the displayed count so the number agrees with the button. YouTube's own figure is
    /// cached and lags a tap by minutes, so waiting for it would look like nothing happened.
    private func adjustLikeCount(by delta: Int) {
        guard let count = video.likeCount else { return }
        video.likeCount = max(0, count + delta)
    }

    /// Feed and playlist entries arrive without statistics; fetch the full record.
    func refreshDetails() async {
        do {
            if let updated = try await service.video(id: video.id) {
                video = updated
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
}
