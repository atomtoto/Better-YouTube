import Foundation

@MainActor
final class VideoDetailViewModel: ObservableObject {
    @Published private(set) var video: Video
    @Published private(set) var comments: [VideoComment] = []
    @Published private(set) var isLoadingComments = false
    @Published var errorMessage: String?
    @Published var commentsError: String?

    private let service: YouTubeAPIService
    private let library: LibraryStore

    init(video: Video, service: YouTubeAPIService = .shared, library: LibraryStore? = nil) {
        self.video = video
        self.service = service
        self.library = library ?? .shared
    }

    func onAppear() {
        library.recordWatch(video)
        Task { await refreshDetails() }
        Task { await loadComments() }
    }

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
