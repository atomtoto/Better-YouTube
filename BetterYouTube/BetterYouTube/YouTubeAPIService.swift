import Foundation

enum APIError: LocalizedError {
    case missingCredentials
    case notSignedIn
    /// The sign-in predates the permission being asked for; only a fresh consent can widen it.
    case insufficientScope
    /// The resource is gone — a playlist deleted from YouTube, say.
    case notFound
    case invalidURL
    case server(String)
    case http(Int)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Add a YouTube Data API key in Settings, or sign in with Google, to load content."
        case .notSignedIn:
            return "Sign in with Google in Settings to see your subscriptions, playlists and likes."
        case .insufficientScope:
            return "This sign-in doesn't allow changes to your YouTube account. Sign in again from Settings to let the app manage its Watch Later playlist."
        case .notFound:
            return "That's no longer on YouTube."
        case .invalidURL:
            return "Could not build the request URL."
        case .server(let message):
            return message
        case .http(let code):
            return "The server responded with status \(code)."
        case .decoding:
            return "Could not read the server's response."
        case .transport(let error):
            return error.localizedDescription
        }
    }
}

/// Stores the user-supplied YouTube Data API v3 key.
final class APIKeyStore: ObservableObject {
    static let shared = APIKeyStore()

    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: Self.storageKey) }
    }

    private static let storageKey = "youtube_api_key"

    private init() {
        self.apiKey = UserDefaults.standard.string(forKey: Self.storageKey) ?? ""
    }

    var hasKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Client for the public YouTube Data API v3 (https://developers.google.com/youtube/v3).
///
/// Quota notes: `search.list` costs 100 units against the default 10,000/day, while
/// `videos.list`, `channels.list` and `playlistItems.list` cost 1. Channel uploads therefore go
/// through the channel's uploads playlist rather than a search query. What each call costs is
/// counted in `QuotaTracker`, which is what Settings shows as the day's remaining quota.
actor YouTubeAPIService {
    static let shared = YouTubeAPIService()

    private let baseURL = URL(string: "https://www.googleapis.com/youtube/v3/")!
    private let session: URLSession
    private let decoder = JSONDecoder()
    private var uploadsPlaylistCache: [String: String] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Request plumbing

    private func request<T: Decodable>(
        path: String,
        query: [String: String],
        requiresAuth: Bool = false
    ) async throws -> T {
        let data = try await perform(makeRequest(path: path, query: query, requiresAuth: requiresAuth))
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// Every item a list endpoint holds, not just the first page.
    ///
    /// `maxResults` tops out at 50 on every endpoint the app uses, so a list longer than that
    /// comes back a page at a time behind a `nextPageToken` — which is why the account's
    /// subscriptions used to stop at 50. One request per page, at the endpoint's usual price.
    private func allPages<Item: Decodable>(
        path: String,
        query: [String: String],
        requiresAuth: Bool = false,
        limit: Int
    ) async throws -> [Item] {
        var items: [Item] = []
        var pageToken: String?

        while items.count < limit {
            var page = query
            page["maxResults"] = "\(min(50, limit - items.count))"
            if let pageToken { page["pageToken"] = pageToken }

            let response: YTListResponse<Item> = try await request(
                path: path,
                query: page,
                requiresAuth: requiresAuth
            )
            items.append(contentsOf: response.items)

            guard let next = response.nextPageToken, !response.items.isEmpty else { break }
            pageToken = next
        }

        return items
    }

    /// A write, with its JSON body. Writes always need OAuth — the API key alone can read the
    /// public catalogue but never touch an account.
    private func send<Body: Encodable, T: Decodable>(
        _ method: String,
        path: String,
        query: [String: String],
        body: Body
    ) async throws -> T {
        var urlRequest = try await makeRequest(path: path, query: query, requiresAuth: true)
        urlRequest.httpMethod = method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let data = try await perform(urlRequest)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// For the writes that answer `204 No Content` — decoding one of those would only ever fail.
    private func sendDiscardingResponse(
        _ method: String,
        path: String,
        query: [String: String]
    ) async throws {
        var urlRequest = try await makeRequest(path: path, query: query, requiresAuth: true)
        urlRequest.httpMethod = method
        _ = try await perform(urlRequest)
    }

    private func makeRequest(
        path: String,
        query: [String: String],
        requiresAuth: Bool
    ) async throws -> URLRequest {
        let token = await GoogleAuthService.shared.accessToken()
        if requiresAuth && token == nil { throw APIError.notSignedIn }

        let key = await MainActor.run { APIKeyStore.shared.apiKey }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if token == nil && key.isEmpty { throw APIError.missingCredentials }

        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.invalidURL
        }
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        if !key.isEmpty {
            items.append(URLQueryItem(name: "key", value: key))
        }
        components.queryItems = items

        guard let url = components.url else { throw APIError.invalidURL }

        var urlRequest = URLRequest(url: url)
        if let token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return urlRequest
    }

    private func perform(_ urlRequest: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw APIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.http(-1) }

        // Charge the call. Every request in this file comes through here, and the API bills a
        // rejected one like any other, so this is the one place the running total can be kept
        // without a caller having to remember to.
        let endpoint = urlRequest.url?.lastPathComponent ?? ""
        let method = urlRequest.httpMethod ?? "GET"
        await QuotaTracker.shared.record(
            units: QuotaTracker.cost(endpoint: endpoint, method: method),
            endpoint: endpoint
        )

        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(YTErrorResponse.self, from: data))?.error.message
            // A 403 for scope is not a failure to retry: the token was granted for less than the
            // app now asks, and only signing in again can widen it. Drop it here so the UI stops
            // claiming to be signed in with permissions it doesn't have.
            if http.statusCode == 403, message?.localizedCaseInsensitiveContains("insufficient") == true {
                await GoogleAuthService.shared.signOutForInsufficientScope()
                throw APIError.insufficientScope
            }
            // Distinct from any other failure: the thing asked for is gone, which callers holding
            // a remembered id need to tell apart from "the request failed".
            if http.statusCode == 404 { throw APIError.notFound }
            if let message { throw APIError.server(message) }
            throw APIError.http(http.statusCode)
        }

        return data
    }

    /// Fills in duration, stats and category for videos that came from a cheap endpoint.
    /// One `videos.list` per 50 — 1 quota unit each — so a long list costs a handful of units
    /// rather than leaving everything past the fiftieth without a duration.
    private func enrich(_ videos: [Video]) async -> [Video] {
        guard !videos.isEmpty else { return [] }
        guard let detailed = try? await self.videos(ids: videos.map(\.id)) else { return videos }
        let byId = Dictionary(detailed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return videos.map { byId[$0.id] ?? $0 }
    }

    /// Full details for a list of ids, in the order given. Pages through in batches of 50, one
    /// `videos.list` per batch — 1 quota unit each, so an imported Watch Later of 500 costs 10.
    ///
    /// Ids YouTube doesn't return are dropped: a video deleted or made private since it was saved,
    /// which any old list has plenty of. The caller compares counts to report them.
    func videos(ids: [String]) async throws -> [Video] {
        var found: [String: Video] = [:]

        for batch in stride(from: 0, to: ids.count, by: 50).map({ start in
            Array(ids[start..<min(start + 50, ids.count)])
        }) {
            let response: YTListResponse<YTResourceItem> = try await request(
                path: "videos",
                query: [
                    "part": "snippet,statistics,contentDetails",
                    "id": batch.joined(separator: ",")
                ]
            )
            for item in response.items where found[item.id] == nil {
                found[item.id] = Video(resource: item)
            }
        }

        return ids.compactMap { found[$0] }
    }

    // MARK: - Public content

    /// YouTube's own most-popular chart for a region, optionally narrowed to one of its
    /// categories — the nearest thing the Data API has to a recommendation, and real YouTube
    /// ranking rather than the app's guesswork. 1 unit.
    func trendingVideos(
        regionCode: String? = nil,
        categoryId: String? = nil,
        maxResults: Int = 25
    ) async throws -> [Video] {
        let region = regionCode ?? Locale.current.region?.identifier ?? "US"
        var query = [
            "part": "snippet,statistics,contentDetails",
            "chart": "mostPopular",
            "regionCode": region,
            "maxResults": "\(maxResults)"
        ]
        if let categoryId, !categoryId.isEmpty {
            query["videoCategoryId"] = categoryId
        }
        let response: YTListResponse<YTResourceItem> = try await request(path: "videos", query: query)
        return response.items.map(Video.init(resource:))
    }

    func search(query: String, maxResults: Int = 25) async throws -> [SearchResult] {
        let response: YTListResponse<YTSearchItem> = try await request(
            path: "search",
            query: [
                "part": "snippet",
                "q": query,
                "type": "video,channel",
                "maxResults": "\(maxResults)"
            ]
        )
        let results = response.items.compactMap { item -> SearchResult? in
            switch item.id.kind {
            case "youtube#video":
                return Video(searchItem: item).map(SearchResult.video)
            case "youtube#channel":
                return Channel(searchItem: item).map(SearchResult.channel)
            default:
                return nil
            }
        }

        // Search results carry no duration or view count; backfill them in one extra unit.
        let videos = results.compactMap { result -> Video? in
            if case .video(let video) = result { return video }
            return nil
        }
        let enriched = await enrich(videos)
        let byId = Dictionary(enriched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return results.map { result in
            if case .video(let video) = result, let full = byId[video.id] {
                return .video(full)
            }
            return result
        }
    }

    func video(id: String) async throws -> Video? {
        let response: YTListResponse<YTResourceItem> = try await request(
            path: "videos",
            query: ["part": "snippet,statistics,contentDetails", "id": id]
        )
        return response.items.first.map(Video.init(resource:))
    }

    func channel(id: String) async throws -> Channel? {
        let response: YTListResponse<YTResourceItem> = try await request(
            path: "channels",
            query: ["part": "snippet,statistics", "id": id]
        )
        return response.items.first.map(Channel.init(resource:))
    }

    // MARK: - Likes
    //
    // The real thing: `videos.rate` writes to the account, so the like lands on YouTube itself
    // and turns up in Liked videos everywhere. It needs OAuth, and it costs 50 units — reading
    // the current rating back costs 1.

    /// What the signed-in account has rated this video. 1 unit.
    func rating(videoId: String) async throws -> VideoRating {
        let response: YTListResponse<YTRatingItem> = try await request(
            path: "videos/getRating",
            query: ["id": videoId],
            requiresAuth: true
        )
        guard let raw = response.items.first?.rating else { return .none }
        return VideoRating(rawValue: raw) ?? .unspecified
    }

    /// Likes a video on the account, or clears the rating with `.none`. 50 units.
    func rate(videoId: String, rating: VideoRating) async throws {
        try await sendDiscardingResponse(
            "POST",
            path: "videos/rate",
            query: ["id": videoId, "rating": rating.rawValue]
        )
    }

    func comments(videoId: String, maxResults: Int = 20) async throws -> [VideoComment] {
        let response: YTListResponse<YTCommentThreadItem> = try await request(
            path: "commentThreads",
            query: [
                "part": "snippet",
                "videoId": videoId,
                "maxResults": "\(maxResults)",
                "order": "relevance",
                "textFormat": "plainText"
            ]
        )
        return response.items.map(VideoComment.init(thread:))
    }

    // MARK: - Playlists

    func videos(inPlaylist playlistId: String, maxResults: Int = 25) async throws -> [Video] {
        let response: YTListResponse<YTPlaylistItemResource> = try await request(
            path: "playlistItems",
            query: [
                "part": "snippet,contentDetails",
                "playlistId": playlistId,
                "maxResults": "\(maxResults)"
            ]
        )
        return await enrich(response.items.compactMap(Video.init(playlistItem:)))
    }

    /// Resolves (and caches) a channel's "uploads" playlist — 1 quota unit instead of a 100-unit search.
    func uploadsPlaylistId(for channelId: String) async throws -> String? {
        if let cached = uploadsPlaylistCache[channelId] { return cached }
        let response: YTListResponse<YTResourceItem> = try await request(
            path: "channels",
            query: ["part": "contentDetails", "id": channelId]
        )
        let uploads = response.items.first?.contentDetails?.relatedPlaylists?.uploads
        if let uploads { uploadsPlaylistCache[channelId] = uploads }
        return uploads
    }

    func videos(byChannel channelId: String, maxResults: Int = 25) async throws -> [Video] {
        guard let uploads = try await uploadsPlaylistId(for: channelId) else { return [] }
        return try await videos(inPlaylist: uploads, maxResults: maxResults)
    }

    // MARK: - Signed-in user's library (OAuth required)

    func myChannel() async throws -> Channel? {
        let response: YTListResponse<YTResourceItem> = try await request(
            path: "channels",
            query: ["part": "snippet,statistics", "mine": "true"],
            requiresAuth: true
        )
        return response.items.first.map(Channel.init(resource:))
    }

    /// Every channel the account follows, however many that is — paged, at 1 unit per 50.
    func mySubscriptions(limit: Int = 1000) async throws -> [Channel] {
        let items: [YTSubscriptionItem] = try await allPages(
            path: "subscriptions",
            query: [
                "part": "snippet",
                "mine": "true",
                "order": "alphabetical"
            ],
            requiresAuth: true,
            limit: limit
        )
        return items.compactMap(Channel.init(subscription:))
    }

    func myPlaylists(limit: Int = 200) async throws -> [Playlist] {
        let items: [YTResourceItem] = try await allPages(
            path: "playlists",
            query: [
                "part": "snippet,contentDetails",
                "mine": "true"
            ],
            requiresAuth: true,
            limit: limit
        )
        return items.map(Playlist.init(resource:))
    }

    // MARK: - The app's own playlist (OAuth, read/write)
    //
    // The account's real Watch Later (`WL`) has been closed to the API since 2016 and no scope
    // reopens it, so the app keeps a playlist of its own instead — a normal private playlist,
    // which means it syncs across devices and shows up in the YouTube app like any other.
    //
    // Writes are expensive: `playlists.insert`, `playlistItems.insert` and `playlistItems.delete`
    // are 50 quota units each, against 10,000 a day. Reading the list back is 1.

    /// The playlist's videos *with* their item ids, which is what removing one needs.
    func entries(inPlaylist playlistId: String, limit: Int = 200) async throws -> [PlaylistEntry] {
        let items: [YTPlaylistItemResource] = try await allPages(
            path: "playlistItems",
            query: [
                "part": "snippet,contentDetails",
                "playlistId": playlistId
            ],
            requiresAuth: true,
            limit: limit
        )
        let entries = items.compactMap { item -> PlaylistEntry? in
            guard let video = Video(playlistItem: item) else { return nil }
            return PlaylistEntry(id: item.id, video: video)
        }
        // `videos.list` fills in durations and counts, 50 at a time (1 unit each).
        let enriched = await enrich(entries.map(\.video))
        let byId = Dictionary(enriched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return entries.map { PlaylistEntry(id: $0.id, video: byId[$0.video.id] ?? $0.video) }
    }

    /// Creates the app's playlist and returns its id. 50 quota units, once per account.
    func createPlaylist(title: String, description: String) async throws -> String {
        struct Body: Encodable {
            struct Snippet: Encodable {
                let title: String
                let description: String
            }
            struct Status: Encodable {
                let privacyStatus: String
            }
            let snippet: Snippet
            let status: Status
        }
        struct Created: Decodable {
            let id: String
        }

        let created: Created = try await send(
            "POST",
            path: "playlists",
            query: ["part": "snippet,status"],
            body: Body(
                snippet: .init(title: title, description: description),
                status: .init(privacyStatus: "private")
            )
        )
        return created.id
    }

    /// Adds a video and returns the new item's id — keep it, it is the handle for removing it.
    func addToPlaylist(playlistId: String, videoId: String) async throws -> String {
        struct Body: Encodable {
            struct ResourceId: Encodable {
                let kind = "youtube#video"
                let videoId: String
            }
            struct Snippet: Encodable {
                let playlistId: String
                let resourceId: ResourceId
            }
            let snippet: Snippet
        }

        let item: YTPlaylistItemResource = try await send(
            "POST",
            path: "playlistItems",
            query: ["part": "snippet"],
            body: Body(snippet: .init(playlistId: playlistId, resourceId: .init(videoId: videoId)))
        )
        return item.id
    }

    /// Removes one entry. Takes the *item* id from `entries(inPlaylist:)`, never a video id.
    func removePlaylistItem(id: String) async throws {
        try await sendDiscardingResponse("DELETE", path: "playlistItems", query: ["id": id])
    }

    func likedVideos(limit: Int = 200) async throws -> [Video] {
        let items: [YTResourceItem] = try await allPages(
            path: "videos",
            query: [
                "part": "snippet,statistics,contentDetails",
                "myRating": "like"
            ],
            requiresAuth: true,
            limit: limit
        )
        return items.map(Video.init(resource:))
    }

    /// Latest uploads across the channels the user follows, newest first.
    func subscriptionFeed(channelLimit: Int = 25, perChannel: Int = 3) async throws -> [Video] {
        let channels = try await mySubscriptions(limit: channelLimit)
        return try await videos(fromChannels: channels.map(\.id), perChannel: perChannel)
    }

    /// How many channels one feed reads. Each one costs a `playlistItems.list` of its own, so
    /// this is the knob that decides what a feed refresh costs; the caller puts the channels it
    /// cares about most at the front, because this takes them in order.
    private static let feedChannelLimit = 100

    /// Recent uploads across an arbitrary set of channels, newest first.
    ///
    /// Costs a `channels.list` per 50 channels plus one `playlistItems.list` each (1 unit
    /// apiece) — the same feed via `search.list` would cost 100 units per channel.
    func videos(fromChannels channelIds: [String], perChannel: Int = 4, limit: Int = 40) async throws -> [Video] {
        // Keep the caller's order while dropping duplicates. Running this through a `Set` used
        // to leave the order to the hash seed, so which channels survived the cap changed from
        // one launch to the next.
        var seen = Set<String>()
        let ids = Array(
            channelIds
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .prefix(Self.feedChannelLimit)
        )
        guard !ids.isEmpty else { return [] }

        // `channels.list` takes at most 50 ids per call.
        var playlistIds: [String] = []
        for batch in stride(from: 0, to: ids.count, by: 50).map({ start in
            Array(ids[start..<min(start + 50, ids.count)])
        }) {
            let response: YTListResponse<YTResourceItem> = try await request(
                path: "channels",
                query: ["part": "contentDetails", "id": batch.joined(separator: ",")]
            )
            for item in response.items {
                guard let uploads = item.contentDetails?.relatedPlaylists?.uploads else { continue }
                uploadsPlaylistCache[item.id] = uploads
                playlistIds.append(uploads)
            }
        }

        var videos: [Video] = []
        await withTaskGroup(of: [Video].self) { group in
            for playlistId in playlistIds {
                group.addTask { [weak self] in
                    guard let self else { return [] }
                    return (try? await self.rawPlaylistItems(playlistId: playlistId, maxResults: perChannel)) ?? []
                }
            }
            for await batch in group {
                videos.append(contentsOf: batch)
            }
        }

        let sorted = videos.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        return await enrich(Array(sorted.prefix(limit)))
    }

    /// Channel avatars for feed rows — one batched call per 50 channels, 1 unit each.
    func channelAvatars(ids: [String]) async -> [String: URL] {
        var seen = Set<String>()
        let unique = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !unique.isEmpty else { return [:] }

        var avatars: [String: URL] = [:]
        for batch in stride(from: 0, to: unique.count, by: 50).map({ start in
            Array(unique[start..<min(start + 50, unique.count)])
        }) {
            let response: YTListResponse<YTResourceItem>? = try? await request(
                path: "channels",
                query: ["part": "snippet", "id": batch.joined(separator: ",")]
            )
            for item in response?.items ?? [] {
                guard let url = item.snippet?.thumbnails?.bestURL else { continue }
                avatars[item.id] = url
            }
        }
        return avatars
    }

    /// Playlist items without the enrichment pass, so batched callers enrich once at the end.
    private func rawPlaylistItems(playlistId: String, maxResults: Int) async throws -> [Video] {
        let response: YTListResponse<YTPlaylistItemResource> = try await request(
            path: "playlistItems",
            query: [
                "part": "snippet,contentDetails",
                "playlistId": playlistId,
                "maxResults": "\(maxResults)"
            ]
        )
        return response.items.compactMap(Video.init(playlistItem:))
    }
}
