import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var videos: [Video] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let service: YouTubeAPIService

    init(service: YouTubeAPIService = .shared) {
        self.service = service
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            videos = try await service.trendingVideos()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
