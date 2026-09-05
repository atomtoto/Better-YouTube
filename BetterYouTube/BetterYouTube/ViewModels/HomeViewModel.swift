import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    enum Feed: String, CaseIterable, Identifiable {
        case forYou
        case subscriptions

        var id: String { rawValue }
        var title: String {
            switch self {
            case .forYou: return "For You"
            case .subscriptions: return "Subscriptions"
            }
        }
    }

    @Published var feed: Feed = .forYou
    @Published private(set) var recommended: [Video] = []
    @Published private(set) var subscriptionVideos: [Video] = []
    @Published private(set) var avatars: [String: URL] = [:]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let service: YouTubeAPIService

    init(service: YouTubeAPIService = .shared) {
        self.service = service
    }

    var videos: [Video] {
        feed == .forYou ? recommended : subscriptionVideos
    }

    func avatar(for channelId: String) -> URL? { avatars[channelId] }

    func load(isSignedIn: Bool, library: LibraryStore) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        var subscriptions: [Channel] = []
        if isSignedIn {
            do {
                subscriptions = try await service.mySubscriptions()
                subscriptionVideos = try await service.videos(
                    fromChannels: subscriptions.map(\.id),
                    perChannel: 4
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            subscriptionVideos = []
        }

        await loadRecommendations(library: library, subscriptions: subscriptions)
        await loadAvatars(for: recommended + subscriptionVideos, subscriptions: subscriptions)

        isLoading = false
    }

    // MARK: - "For You"

    /// The Data API exposes no personalized feed (`activities?home=true` and `relatedToVideoId`
    /// were both retired), so recommendations are assembled here from the signals the app has:
    /// who you actually watch, what you liked and favorited, and who you subscribe to.
    private func loadRecommendations(library: LibraryStore, subscriptions: [Channel]) async {
        var affinity: [String: Double] = [:]

        // Recently watched channels count most, with the newest watches weighted highest.
        for (index, video) in library.history.prefix(60).enumerated() where !video.channelId.isEmpty {
            affinity[video.channelId, default: 0] += 3.0 * (1.0 - Double(index) / 80.0)
        }
        for video in library.favorites where !video.channelId.isEmpty {
            affinity[video.channelId, default: 0] += 2.5
        }
        for video in library.watchLater where !video.channelId.isEmpty {
            affinity[video.channelId, default: 0] += 1.5
        }
        for channel in subscriptions {
            affinity[channel.id, default: 0] += 1.0
        }

        let seeds = affinity
            .sorted { $0.value > $1.value }
            .prefix(15)
            .map(\.key)

        guard !seeds.isEmpty else {
            recommended = []
            return
        }

        let candidates = (try? await service.videos(fromChannels: Array(seeds), perChannel: 4)) ?? []
        let watched = Set(library.history.map(\.id))

        recommended = candidates
            .filter { !watched.contains($0.id) }
            .map { video -> (video: Video, score: Double) in
                let base = affinity[video.channelId] ?? 0
                let ageInDays = video.publishedAt.map { max(0, Date().timeIntervalSince($0) / 86_400) } ?? 30
                // Recency decays over roughly a fortnight, so fresh uploads surface first.
                let recency = 1.0 / (1.0 + ageInDays / 14.0)
                return (video, base * 0.6 + recency * 4.0)
            }
            .sorted { $0.score > $1.score }
            .map(\.video)
    }

    private func loadAvatars(for videos: [Video], subscriptions: [Channel]) async {
        var known = avatars
        for channel in subscriptions where channel.thumbnailURL != nil {
            known[channel.id] = channel.thumbnailURL
        }

        let missing = Set(videos.map(\.channelId))
            .subtracting(known.keys)
            .filter { !$0.isEmpty }

        if !missing.isEmpty {
            let fetched = await service.channelAvatars(ids: Array(missing))
            known.merge(fetched) { _, new in new }
        }
        avatars = known
    }
}
