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

    var isFavorite: Bool { library.isFavorite(video) }
    var isInWatchLater: Bool { library.isInWatchLater(video) }

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

    func toggleFavorite() {
        library.toggleFavorite(video)
        objectWillChange.send()
    }

    func toggleWatchLater() {
        library.toggleWatchLater(video)
        objectWillChange.send()
    }
}
