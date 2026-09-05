import Foundation

@MainActor
final class PlaylistViewModel: ObservableObject {
    @Published private(set) var videos: [Video] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let playlistId: String
    private let service: YouTubeAPIService

    init(playlistId: String, service: YouTubeAPIService = .shared) {
        self.playlistId = playlistId
        self.service = service
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            videos = try await service.videos(inPlaylist: playlistId, maxResults: 50)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
