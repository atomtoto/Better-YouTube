import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var trending: [Video] = []
    @Published private(set) var subscriptionFeed: [Video] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let service: YouTubeAPIService

    init(service: YouTubeAPIService = .shared) {
        self.service = service
    }

    var featured: Video? { trending.first }
    var trendingRest: [Video] { Array(trending.dropFirst()) }

    func load(isSignedIn: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        do {
            trending = try await service.trendingVideos()
        } catch {
            errorMessage = error.localizedDescription
        }

        if isSignedIn {
            subscriptionFeed = (try? await service.subscriptionFeed()) ?? []
        } else {
            subscriptionFeed = []
        }

        isLoading = false
    }
}
