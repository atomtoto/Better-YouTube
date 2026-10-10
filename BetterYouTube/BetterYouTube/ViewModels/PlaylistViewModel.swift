import Foundation

@MainActor
final class PlaylistViewModel: ObservableObject {
    /// The playlist as last known: what the list it was picked from said, or — for one opened
    /// from a link, which arrives as a bare ID — what the Data API says once asked.
    @Published private(set) var playlist: Playlist
    @Published private(set) var videos: [Video] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    /// Why the next page didn't arrive. Kept apart from `errorMessage`, which replaces the list.
    @Published private(set) var loadMoreError: String?

    /// The Data API's handle on the next page; nil when the list is complete.
    private var nextPageToken: String?
    private let service: YouTubeAPIService

    var canLoadMore: Bool { nextPageToken != nil }

    init(playlist: Playlist, service: YouTubeAPIService = .shared) {
        self.playlist = playlist
        self.service = service
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        loadMoreError = nil
        if playlist.title.isEmpty, let details = try? await service.playlist(id: playlist.id) {
            playlist = details
        }
        do {
            if YouTubeWebSession.shared.isSignedIn {
                // The website hands back the whole list, saved and private playlists included.
                videos = try await YouTubeWebPlaylistService.shared.videos(inPlaylist: playlist.id)
                nextPageToken = nil
            } else {
                try await loadFirstPage()
            }
        } catch {
            // Public playlists remain readable with the stable API if the website changes.
            do {
                try await loadFirstPage()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    /// The next fifty, when the list goes on. It used to stop at the first fifty, with nothing
    /// to say that there were more.
    func loadMore() async {
        guard let token = nextPageToken, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        loadMoreError = nil
        do {
            let page = try await service.videos(inPlaylist: playlist.id, pageToken: token)
            let known = Set(videos.map(\.id))
            videos += page.items.filter { !known.contains($0.id) }
            nextPageToken = page.nextPageToken
        } catch {
            loadMoreError = error.localizedDescription
        }
        isLoadingMore = false
    }

    private func loadFirstPage() async throws {
        let page = try await service.videos(inPlaylist: playlist.id, pageToken: nil)
        videos = page.items
        nextPageToken = page.nextPageToken
    }
}
