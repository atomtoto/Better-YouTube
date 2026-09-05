import Foundation

/// Loads the signed-in account's library: subscriptions, playlists and liked videos.
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var account: Channel?
    @Published private(set) var subscriptions: [Channel] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var likedVideos: [Video] = []
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
            async let accountResult = service.myChannel()
            async let subscriptionsResult = service.mySubscriptions()
            async let playlistsResult = service.myPlaylists()
            async let likedResult = service.likedVideos()

            account = try await accountResult
            subscriptions = try await subscriptionsResult
            playlists = try await playlistsResult
            likedVideos = try await likedResult
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func reset() {
        account = nil
        subscriptions = []
        playlists = []
        likedVideos = []
        errorMessage = nil
    }
}
