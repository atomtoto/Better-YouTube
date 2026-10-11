import Foundation

@MainActor
final class ChannelViewModel: ObservableObject {
    @Published private(set) var channel: Channel?
    @Published private(set) var videos: [Video] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published var errorMessage: String?
    @Published private(set) var loadMoreError: String?
    /// Whether the signed-in account follows this channel.
    enum Subscription: Equatable {
        /// Not read yet — or signed out, with no account to follow it from.
        case unknown
        case notSubscribed
        /// Subscribed, under the subscription resource's own ID, which is what unsubscribing takes.
        case subscribed(id: String)
    }

    @Published private(set) var subscription: Subscription = .unknown
    @Published private(set) var isChangingSubscription = false
    @Published var subscriptionError: String?

    /// The channel's public playlists, read the first time they are shown.
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var hasLoadedPlaylists = false
    @Published private(set) var isLoadingPlaylists = false
    @Published private(set) var playlistsError: String?

    private let channelId: String
    private let service: YouTubeAPIService
    private var nextPageToken: String?
    private var playlistsPageToken: String?

    var canLoadMorePlaylists: Bool { playlistsPageToken != nil }

    var canLoadMore: Bool { nextPageToken != nil }

    init(channelId: String, service: YouTubeAPIService = .shared) {
        self.channelId = channelId
        self.service = service
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        loadMoreError = nil
        do {
            async let channelResult = service.channel(id: channelId)
            async let videosResult = service.videos(byChannel: channelId, pageToken: nil)
            channel = try await channelResult
            let page = try await videosResult
            videos = page.items
            nextPageToken = page.nextPageToken
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// The next page of uploads. A channel page used to end after its 25 latest videos.
    func loadMore() async {
        guard let token = nextPageToken, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        loadMoreError = nil
        do {
            let page = try await service.videos(byChannel: channelId, pageToken: token)
            let known = Set(videos.map(\.id))
            videos += page.items.filter { !known.contains($0.id) }
            nextPageToken = page.nextPageToken
        } catch {
            loadMoreError = error.localizedDescription
        }
        isLoadingMore = false
    }

    // MARK: - Playlists

    /// The first page of playlists, or the next one. 1 unit a page.
    func loadPlaylists() async {
        guard !isLoadingPlaylists, !hasLoadedPlaylists || playlistsPageToken != nil else { return }
        isLoadingPlaylists = true
        playlistsError = nil
        do {
            let page = try await service.playlists(ofChannel: channelId, pageToken: playlistsPageToken)
            let known = Set(playlists.map(\.id))
            playlists += page.items.filter { !known.contains($0.id) }
            playlistsPageToken = page.nextPageToken
            hasLoadedPlaylists = true
        } catch {
            playlistsError = error.localizedDescription
        }
        isLoadingPlaylists = false
    }

    // MARK: - Subscribing

    /// Reads whether the account follows this channel. 1 unit, and only when signed in.
    func loadSubscription(isSignedIn: Bool) async {
        guard isSignedIn else {
            subscription = .unknown
            return
        }
        do {
            subscription = try await service.subscriptionID(forChannel: channelId)
                .map { .subscribed(id: $0) } ?? .notSubscribed
        } catch {
            subscription = .unknown
        }
    }

    /// Subscribes, or unsubscribes, on the account itself — 50 units either way.
    func toggleSubscription() async {
        guard subscription != .unknown, !isChangingSubscription else { return }
        isChangingSubscription = true
        subscriptionError = nil
        defer { isChangingSubscription = false }
        do {
            switch subscription {
            case .subscribed(let id):
                try await service.unsubscribe(subscriptionID: id)
                subscription = .notSubscribed
                channel?.subscriberCount = channel?.subscriberCount.map { max(0, $0 - 1) }
            case .notSubscribed:
                let created = try await service.subscribe(toChannel: channelId)
                subscription = .subscribed(id: created)
                channel?.subscriberCount = channel?.subscriberCount.map { $0 + 1 }
            case .unknown:
                break
            }
        } catch {
            subscriptionError = error.localizedDescription
        }
    }
}
