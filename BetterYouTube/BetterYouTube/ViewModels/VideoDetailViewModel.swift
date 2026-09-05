import Foundation

/// Backs the details shown under the expanded player: the enriched video plus its comments.
@MainActor
final class VideoDetailViewModel: ObservableObject {
    @Published private(set) var video: Video
    @Published private(set) var comments: [VideoComment] = []
    @Published private(set) var isLoadingComments = false
    @Published var errorMessage: String?
    @Published var commentsError: String?

    private let service: YouTubeAPIService

    init(video: Video, service: YouTubeAPIService = .shared) {
        self.video = video
        self.service = service
    }

    func loadAll() async {
        async let details: Void = refreshDetails()
        async let comments: Void = loadComments()
        _ = await (details, comments)
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
