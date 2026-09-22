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

    func load(apiSignedIn: Bool, webSignedIn: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        var failures: [String] = []
        var ownedPlaylists: [Playlist] = []

        if apiSignedIn {
            async let accountResult: Result<Channel?, Error> = capture { try await service.myChannel() }
            async let subscriptionsResult: Result<[Channel], Error> = capture { try await service.mySubscriptions() }
            async let playlistsResult: Result<[Playlist], Error> = capture { try await service.myPlaylists() }
            async let likedResult: Result<[Video], Error> = capture { try await service.likedVideos() }

            switch await accountResult { case .success(let value): account = value; case .failure(let error): failures.append(error.localizedDescription) }
            switch await subscriptionsResult { case .success(let value): subscriptions = value; case .failure(let error): failures.append(error.localizedDescription) }
            switch await playlistsResult { case .success(let value): ownedPlaylists = value; case .failure(let error): failures.append(error.localizedDescription) }
            switch await likedResult { case .success(let value): likedVideos = value; case .failure(let error): failures.append(error.localizedDescription) }
        } else {
            account = nil
            subscriptions = []
            likedVideos = []
        }

        var allPlaylists: [Playlist] = []
        if webSignedIn {
            do {
                allPlaylists = try await YouTubeWebPlaylistService.shared.playlists()
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        // Prefer API metadata for owned playlists, while retaining every saved/system playlist
        // only present in YouTube's aggregation page.
        var byID = Dictionary(allPlaylists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for playlist in ownedPlaylists { byID[playlist.id] = playlist }
        var seen = Set<String>()
        playlists = (allPlaylists + ownedPlaylists).compactMap { playlist in
            guard !playlist.isLikedVideos else { return nil }
            guard seen.insert(playlist.id).inserted else { return nil }
            return byID[playlist.id]
        }
        errorMessage = failures.first
        isLoading = false
    }

    private func capture<Value>(
        _ operation: () async throws -> Value
    ) async -> Result<Value, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    func reset() {
        account = nil
        subscriptions = []
        playlists = []
        likedVideos = []
        errorMessage = nil
    }
}
