import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    enum Feed: String, CaseIterable, Identifiable {
        /// YouTube's own home page, read through the web session. Only offered once there is one.
        case youTube
        case forYou
        case subscriptions

        var id: String { rawValue }
        var title: String {
            switch self {
            case .youTube: return "YouTube"
            case .forYou: return "For You"
            case .subscriptions: return "Subscriptions"
            }
        }
    }

    @Published var feed: Feed = .forYou
    @Published private(set) var recommended: [Video] = []
    @Published private(set) var subscriptionVideos: [Video] = []
    @Published private(set) var youTubeVideos: [Video] = []
    @Published private(set) var avatars: [String: URL] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingYouTube = false
    /// Why YouTube's own feed is empty, in words the screen can show.
    @Published private(set) var youTubeIssue: String?
    @Published var errorMessage: String?
    /// Set the first time you choose a segment yourself, so the default below only ever applies
    /// to a screen you haven't touched.
    private(set) var hasPickedFeed = false

    private let service: YouTubeAPIService
    /// When the feed was last filled, and for which sign-in state. Every tab switch re-runs the
    /// view's `.task`, and one refresh reads a hundred channels — so a recent feed is shown
    /// again rather than bought again. Pulling down forces it.
    private var lastLoaded: Date?
    private var lastLoadedSignedIn = false
    private var lastLoadedYouTube: Date?
    private static let reloadInterval: TimeInterval = 15 * 60

    init(service: YouTubeAPIService = .shared) {
        self.service = service
    }

    var videos: [Video] {
        switch feed {
        case .youTube: return youTubeVideos
        case .forYou: return recommended
        case .subscriptions: return subscriptionVideos
        }
    }

    func avatar(for channelId: String) -> URL? { avatars[channelId] }

    /// Choosing a segment by hand, which also settles the default for good.
    func select(_ feed: Feed) {
        hasPickedFeed = true
        self.feed = feed
    }

    /// With a youtube.com session on the device, the real feed is the one to open on — but only
    /// until you pick something else, and never once the session is gone.
    func adoptDefaultFeed(webSignedIn: Bool) {
        if webSignedIn {
            guard !hasPickedFeed else { return }
            feed = .youTube
        } else if feed == .youTube {
            feed = .forYou
            youTubeVideos = []
            lastLoadedYouTube = nil
        }
    }

    // MARK: - YouTube's own feed

    /// Reads the ordering off YouTube's home page and fills it in from the Data API — one
    /// `videos.list` for the lot, so about 1 quota unit a refresh.
    ///
    /// Loaded when its segment is chosen rather than with the rest: it drives a web view, which
    /// is slower than the two API feeds and has no business holding them up.
    func loadYouTubeFeed(force: Bool = false) async {
        guard !isLoadingYouTube else { return }
        if !force,
           let lastLoadedYouTube,
           !youTubeVideos.isEmpty,
           Date().timeIntervalSince(lastLoadedYouTube) < Self.reloadInterval {
            return
        }

        isLoadingYouTube = true
        youTubeIssue = nil

        do {
            let ids = try await YouTubeFeedReader.shared.harvest()
            let videos = try await service.videos(ids: ids)
            youTubeVideos = videos
            youTubeIssue = videos.isEmpty ? YouTubeFeedIssue.nothingFound.localizedDescription : nil
            lastLoadedYouTube = videos.isEmpty ? nil : Date()
            await loadAvatars(for: videos, subscriptions: [])
        } catch {
            youTubeIssue = error.localizedDescription
            lastLoadedYouTube = nil
        }

        isLoadingYouTube = false
    }

    func load(isSignedIn: Bool, library: LibraryStore, force: Bool = false) async {
        guard !isLoading else { return }
        if !force,
           let lastLoaded,
           lastLoadedSignedIn == isSignedIn,
           !videos.isEmpty,
           Date().timeIntervalSince(lastLoaded) < Self.reloadInterval {
            return
        }

        isLoading = true
        errorMessage = nil

        let affinity = Self.channelAffinity(library: library)
        var subscriptions: [Channel] = []

        if isSignedIn {
            do {
                subscriptions = try await service.mySubscriptions()
                // A feed reads a fixed number of channels, so the ones this account actually
                // watches go first. The API hands subscriptions back alphabetically, which for
                // a long list meant the feed was whatever happened to begin with an A.
                let ordered = subscriptions
                    .map(\.id)
                    .sorted { (affinity[$0] ?? 0) > (affinity[$1] ?? 0) }
                subscriptionVideos = try await service.videos(
                    fromChannels: ordered,
                    perChannel: 4,
                    limit: 60
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            subscriptionVideos = []
        }

        await loadRecommendations(library: library, subscriptions: subscriptions, affinity: affinity)
        await loadAvatars(for: recommended + subscriptionVideos, subscriptions: subscriptions)

        lastLoaded = Date()
        lastLoadedSignedIn = isSignedIn
        isLoading = false
    }

    // MARK: - "For You"

    /// The Data API has no personalized feed left to ask for: `activities?home=true` went in
    /// 2016 and `relatedToVideoId` in 2023, and nothing replaced either. What YouTube does still
    /// publish is its most-popular chart, per region and per category — so "For You" weaves that
    /// chart, narrowed to the categories this account watches, together with fresh uploads from
    /// the channels it watches most. The first half is YouTube's own ranking; the second is the
    /// app's, and the feed says so at the bottom of the screen.
    private func loadRecommendations(
        library: LibraryStore,
        subscriptions: [Channel],
        affinity: [String: Double]
    ) async {
        let watched = Set(library.history.map(\.id))
        let history = library.history

        async let youTubeResult = youTubePicks(history: history)
        let fromChannels = await channelPicks(
            affinity: affinity,
            subscriptions: subscriptions,
            watched: watched
        )
        let fromYouTube = await youTubeResult.filter { !watched.contains($0.id) }

        var seen = Set<String>()
        recommended = Self.weave(fromChannels, fromYouTube)
            .filter { seen.insert($0.id).inserted }
    }

    /// YouTube's own ranking, narrowed to what this account watches: one `videos.list` chart
    /// call per top category, 1 unit each. With no history to go on — a fresh install, or one
    /// signed out — it asks for the chart as a whole, which is still YouTube's list rather than
    /// a guess of the app's.
    private func youTubePicks(history: [Video]) async -> [Video] {
        let categories = Self.topCategories(in: history)
        guard !categories.isEmpty else {
            return (try? await service.trendingVideos(maxResults: 20)) ?? []
        }

        var picks: [Video] = []
        for category in categories {
            picks += (try? await service.trendingVideos(categoryId: category, maxResults: 10)) ?? []
        }
        return picks
    }

    /// Fresh uploads from the channels this account spends its time on, newest and closest
    /// first. Watched videos are dropped: a recommendation you have already seen is filler.
    private func channelPicks(
        affinity: [String: Double],
        subscriptions: [Channel],
        watched: Set<String>
    ) async -> [Video] {
        var weights = affinity
        for channel in subscriptions {
            weights[channel.id, default: 0] += 1.0
        }

        let seeds = weights
            .sorted { $0.value > $1.value }
            .prefix(15)
            .map(\.key)
        guard !seeds.isEmpty else { return [] }

        let candidates = (try? await service.videos(fromChannels: Array(seeds), perChannel: 4)) ?? []

        return candidates
            .filter { !watched.contains($0.id) }
            .map { video -> (video: Video, score: Double) in
                let base = weights[video.channelId] ?? 0
                let ageInDays = video.publishedAt.map { max(0, Date().timeIntervalSince($0) / 86_400) } ?? 30
                // Recency decays over roughly a fortnight, so fresh uploads surface first.
                let recency = 1.0 / (1.0 + ageInDays / 14.0)
                return (video, base * 0.6 + recency * 4.0)
            }
            .sorted { $0.score > $1.score }
            .map(\.video)
    }

    /// How much this account cares about each channel, from the signals the app holds: who it
    /// actually watches, what it liked and favourited, what it put aside for later.
    private static func channelAffinity(library: LibraryStore) -> [String: Double] {
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
        return affinity
    }

    /// The categories this account spends its time in, most-watched first. Only the endpoints
    /// that return a full snippet carry a category, so history saved before the app started
    /// keeping one simply doesn't vote.
    private static func topCategories(in history: [Video], limit: Int = 3) -> [String] {
        var counts: [String: Int] = [:]
        for video in history.prefix(60) {
            guard let category = video.categoryId, !category.isEmpty else { continue }
            counts[category, default: 0] += 1
        }
        return counts
            .sorted { first, second in
                first.value == second.value ? first.key < second.key : first.value > second.value
            }
            .prefix(limit)
            .map(\.key)
    }

    /// Two from the first list, then one from the second, until both run dry — so YouTube's
    /// picks are never off the screen, and never the whole of it either.
    private static func weave(_ primary: [Video], _ secondary: [Video], everyNth: Int = 2) -> [Video] {
        var woven: [Video] = []
        var first = primary.makeIterator()
        var second = secondary.makeIterator()
        var takenFromFirst = 0

        while true {
            if takenFromFirst < everyNth, let next = first.next() {
                woven.append(next)
                takenFromFirst += 1
            } else if let next = second.next() {
                woven.append(next)
                takenFromFirst = 0
            } else if let next = first.next() {
                woven.append(next)
            } else {
                return woven
            }
        }
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
