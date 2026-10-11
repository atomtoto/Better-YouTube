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
            return String(localized: "Add a YouTube Data API key in Settings, or sign in with Google, to load content.")
        case .notSignedIn:
            return String(localized: "Sign in with Google in Settings to see your subscriptions, playlists and likes.")
        case .insufficientScope:
            return String(localized: "This sign-in doesn't allow changes to your YouTube account. Sign in again from Settings and allow access to YouTube.")
        case .notFound:
            return String(localized: "That's no longer on YouTube.")
        case .invalidURL:
            return String(localized: "Could not build the request URL.")
        case .server(let message):
            return message
        case .http(let code):
            return String(localized: "The server responded with status \(code).")
        case .decoding:
            return String(localized: "Could not read the server's response.")
        case .transport(let error):
            return error.localizedDescription
        }
    }
}

/// One page of a list endpoint, and the token for the next one — nil once there is no more.
struct Page<Item> {
    let items: [Item]
    let nextPageToken: String?
}

extension Page: Sendable where Item: Sendable {}

/// The two orders YouTube offers for a video's comments.
enum CommentOrder: String, CaseIterable, Identifiable {
    /// YouTube's own "Top comments".
    case relevance
    case time

    var id: String { rawValue }
}

/// Narrows a search the way YouTube's own filter sheet does. Every filter here is a parameter
/// of the same 100-unit `search.list`, so filtering costs nothing extra.
struct SearchFilters: Equatable {
    enum Order: String, CaseIterable, Identifiable {
        case relevance, date, viewCount, rating
        var id: String { rawValue }
    }

    enum Duration: String, CaseIterable, Identifiable {
        case any, short, medium, long
        var id: String { rawValue }
    }

    enum UploadDate: String, CaseIterable, Identifiable {
        case any, today, week, month, year
        var id: String { rawValue }

        /// How far back the window starts, from now.
        var interval: TimeInterval? {
            switch self {
            case .any: return nil
            case .today: return 24 * 60 * 60
            case .week: return 7 * 24 * 60 * 60
            case .month: return 31 * 24 * 60 * 60
            case .year: return 365 * 24 * 60 * 60
            }
        }
    }

    var order: Order = .relevance
    var duration: Duration = .any
    var uploadDate: UploadDate = .any

    var isDefault: Bool { self == SearchFilters() }

    /// Duration and date only apply to videos; YouTube refuses them alongside channels.
    var needsVideoType: Bool { duration != .any || uploadDate != .any }

    func queryItems(now: Date = Date()) -> [String: String] {
        var items: [String: String] = [:]
        if order != .relevance { items["order"] = order.rawValue }
        if duration != .any { items["videoDuration"] = duration.rawValue }
        if let interval = uploadDate.interval {
            let formatter = ISO8601DateFormatter()
            items["publishedAfter"] = formatter.string(from: now.addingTimeInterval(-interval))
        }
        return items
    }
}

/// Stores the user-supplied YouTube Data API v3 key.
@MainActor
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

    /// What a request is made with: the signed-in account's access token, if there is one, and
    /// the API key, which may be empty.
    struct Credentials: Sendable {
        var accessToken: String?
        var apiKey: String
    }

    /// The account and key the app is set up with.
    static let currentCredentials: @Sendable () async -> Credentials = {
        let token = await GoogleAuthService.shared.accessToken()
        let key = await MainActor.run { APIKeyStore.shared.apiKey }
        return Credentials(accessToken: token, apiKey: key)
    }

    private let baseURL = URL(string: "https://www.googleapis.com/youtube/v3/")!
    private let session: URLSession
    private let decoder = JSONDecoder()
    private var uploadsPlaylistCache: [String: String] = [:]
    private let credentials: @Sendable () async -> Credentials
    private let recordSpend: @Sendable (_ units: Int, _ endpoint: String) async -> Void

    /// The network, the credentials and the quota count are the shared ones unless handed in —
    /// which is what lets the tests run every request against canned responses, without a key
    /// of their own or a charge to the real day's count.
    init(
        session: URLSession = .shared,
        credentials: @escaping @Sendable () async -> Credentials = YouTubeAPIService.currentCredentials,
        recordSpend: @escaping @Sendable (_ units: Int, _ endpoint: String) async -> Void = { @MainActor units, endpoint in
            QuotaTracker.shared.record(units: units, endpoint: endpoint)
        }
    ) {
        self.session = session
        self.credentials = credentials
        self.recordSpend = recordSpend
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
        let credentials = await credentials()
        let token = credentials.accessToken
        if requiresAuth && token == nil { throw APIError.notSignedIn }

        let key = credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
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
        // Only where the account is actually the point — or where there is no API key to read
        // the public catalogue with.
        //
        // This used to go out on every request, and that was the bug behind a session that kept
        // evaporating: Google validates a token's scope against the endpoint it arrives at, so a
        // perfectly public call carrying a Bearer token can be refused 403 for lack of a
        // permission the call never needed. Comments and search are the ones that bite, and they
        // run on every video opened.
        if let token, requiresAuth || key.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return urlRequest
    }

    private func perform(_ urlRequest: URLRequest, isRetry: Bool = false) async throws -> Data {
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
        await recordSpend(QuotaTracker.cost(endpoint: endpoint, method: method), endpoint)

        guard (200..<300).contains(http.statusCode) else {
            let failure = try? decoder.decode(YTErrorResponse.self, from: data)
            let message = failure?.error.message
            let reasons = failure?.reasons ?? []

            // Google stopped honouring the access token before it was due to expire — a password
            // change, a grant revoked, a clock that drifted. Refreshing and going round once more
            // is what the situation calls for; treating it as a dead session, which is what
            // happened before, signed the account out over something a retry fixes.
            if http.statusCode == 401,
               !isRetry,
               urlRequest.value(forHTTPHeaderField: "Authorization") != nil,
               let token = await GoogleAuthService.shared.refreshedAccessToken() {
                var retried = urlRequest
                retried.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return try await perform(retried, isRetry: true)
            }

            // A 403 for scope is not a failure to retry: the token was granted for less than the
            // app now asks, and only signing in again can widen it. Drop it here so the UI stops
            // claiming to be signed in with permissions it doesn't have.
            //
            // Matched on the machine-readable reason rather than the prose. Google answers 403
            // to plenty besides scope — quota spent, comments disabled, a video that can't be
            // rated — and matching the word "insufficient" anywhere in a message signed the
            // account out of the app over any of them that happened to use it.
            if http.statusCode == 403, reasons.contains("insufficientPermissions")
                || (reasons.isEmpty
                    && message?.localizedCaseInsensitiveContains("insufficient authentication scopes") == true) {
                // Only a grant that really is too narrow is worth dropping the session over. If
                // the token already holds what the app asks for, signing out and back in lands
                // in exactly the same place — which is the loop this used to put people in, on
                // every video they opened. Surface it as the ordinary failure it is instead.
                if await GoogleAuthService.shared.holdsRequestedScope {
                    throw APIError.server(
                        message ?? String(localized: "Google refused “\(endpoint)” for lack of permission.")
                    )
                }
                await GoogleAuthService.shared.signOutForInsufficientScope(endpoint: endpoint)
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
        try await search(query: query, maxResults: maxResults, pageToken: nil).items
    }

    /// One page of search results — 100 units, whichever page it is, which is why further pages
    /// are only ever fetched when asked for.
    func search(
        query: String,
        filters: SearchFilters = SearchFilters(),
        maxResults: Int = 25,
        pageToken: String?
    ) async throws -> Page<SearchResult> {
        var parameters = [
            "part": "snippet",
            "q": query,
            "type": filters.needsVideoType ? "video" : "video,channel",
            "maxResults": "\(maxResults)"
        ]
        parameters.merge(filters.queryItems()) { _, filter in filter }
        if let pageToken { parameters["pageToken"] = pageToken }
        let response: YTListResponse<YTSearchItem> = try await request(path: "search", query: parameters)
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

        let items = results.map { result in
            if case .video(let video) = result, let full = byId[video.id] {
                return SearchResult.video(full)
            }
            return result
        }
        return Page(items: items, nextPageToken: response.nextPageToken)
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

    /// The channel behind an `@handle`, for a pasted or opened channel link. 1 unit.
    func channel(handle: String) async throws -> Channel? {
        let response: YTListResponse<YTResourceItem> = try await request(
            path: "channels",
            query: ["part": "snippet,statistics", "forHandle": handle]
        )
        return response.items.first.map(Channel.init(resource:))
    }

    /// A playlist's title, owner and size, for one opened from a link rather than from a list
    /// that already carried them. 1 unit.
    func playlist(id: String) async throws -> Playlist? {
        let response: YTListResponse<YTResourceItem> = try await request(
            path: "playlists",
            query: ["part": "snippet,contentDetails", "id": id]
        )
        return response.items.first.map(Playlist.init(resource:))
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
        try await comments(videoId: videoId, order: .relevance, maxResults: maxResults, pageToken: nil).items
    }

    /// One page of a video's top-level comments, in YouTube's order or newest first. 1 unit.
    func comments(
        videoId: String,
        order: CommentOrder,
        maxResults: Int = 20,
        pageToken: String?
    ) async throws -> Page<VideoComment> {
        // viewerRating belongs to the account: a key-only request always reads it as "none".
        let hasAccount = await GoogleAuthService.shared.isSignedIn
        var query = [
            "part": "snippet",
            "videoId": videoId,
            "maxResults": "\(maxResults)",
            "order": order.rawValue,
            "textFormat": "plainText"
        ]
        if let pageToken { query["pageToken"] = pageToken }
        let response: YTListResponse<YTCommentThreadItem> = try await request(
            path: "commentThreads",
            query: query,
            requiresAuth: hasAccount
        )
        return Page(items: response.items.map(VideoComment.init(thread:)), nextPageToken: response.nextPageToken)
    }

    /// Publishes a new top-level comment. YouTube returns the created thread, including the
    /// server-authored id and timestamp, so the UI can insert the canonical value immediately.
    func addComment(videoId: String, text: String) async throws -> VideoComment {
        struct Body: Encodable {
            struct Snippet: Encodable {
                struct TopLevelComment: Encodable {
                    struct CommentSnippet: Encodable { let textOriginal: String }
                    let snippet: CommentSnippet
                }
                let videoId: String
                let topLevelComment: TopLevelComment
            }
            let snippet: Snippet
        }

        let thread: YTCommentThreadItem = try await send(
            "POST",
            path: "commentThreads",
            query: ["part": "snippet"],
            body: Body(
                snippet: .init(
                    videoId: videoId,
                    topLevelComment: .init(snippet: .init(textOriginal: text))
                )
            )
        )
        return VideoComment(thread: thread)
    }

    /// Replies to a top-level comment. The parent id is the comment resource id, not the thread
    /// id; `VideoComment` intentionally keeps that distinction when mapping API responses.
    func reply(to parentId: String, text: String) async throws -> VideoComment {
        struct Body: Encodable {
            struct Snippet: Encodable {
                let parentId: String
                let textOriginal: String
            }
            let snippet: Snippet
        }

        let item: YTCommentItem = try await send(
            "POST",
            path: "comments",
            query: ["part": "snippet"],
            body: Body(snippet: .init(parentId: parentId, textOriginal: text))
        )
        return VideoComment(item: item)
    }

    /// Fetches the replies separately: `commentThreads.list` includes at most a small preview,
    /// while `comments.list` returns the complete conversation page for an expanded thread.
    func replies(to parentId: String, limit: Int = 200) async throws -> [VideoComment] {
        let items: [YTCommentItem] = try await allPages(
            path: "comments",
            query: [
                "part": "snippet",
                "parentId": parentId,
                "textFormat": "plainText"
            ],
            limit: limit
        )
        return items.map { VideoComment(item: $0) }
    }

    // MARK: - Playlists

    func videos(inPlaylist playlistId: String, maxResults: Int = 25) async throws -> [Video] {
        try await videos(inPlaylist: playlistId, maxResults: maxResults, pageToken: nil).items
    }

    /// One page of a playlist, enriched with durations and counts. 2 units: the page, and the
    /// `videos.list` that fills it in.
    func videos(inPlaylist playlistId: String, maxResults: Int = 50, pageToken: String?) async throws -> Page<Video> {
        var query = [
            "part": "snippet,contentDetails",
            "playlistId": playlistId,
            "maxResults": "\(maxResults)"
        ]
        if let pageToken { query["pageToken"] = pageToken }
        let response: YTListResponse<YTPlaylistItemResource> = try await request(path: "playlistItems", query: query)
        let videos = await enrich(response.items.compactMap(Video.init(playlistItem:)))
        return Page(items: videos, nextPageToken: response.nextPageToken)
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
        try await videos(byChannel: channelId, maxResults: maxResults, pageToken: nil).items
    }

    /// One page of a channel's uploads, newest first, read through its uploads playlist.
    func videos(byChannel channelId: String, maxResults: Int = 30, pageToken: String?) async throws -> Page<Video> {
        guard let uploads = try await uploadsPlaylistId(for: channelId) else { return Page(items: [], nextPageToken: nil) }
        return try await videos(inPlaylist: uploads, maxResults: maxResults, pageToken: pageToken)
    }

    /// One page of the playlists a channel has made public, newest first. 1 unit.
    func playlists(ofChannel channelId: String, maxResults: Int = 25, pageToken: String?) async throws -> Page<Playlist> {
        var query = [
            "part": "snippet,contentDetails",
            "channelId": channelId,
            "maxResults": "\(maxResults)"
        ]
        if let pageToken { query["pageToken"] = pageToken }
        let response: YTListResponse<YTResourceItem> = try await request(path: "playlists", query: query)
        return Page(items: response.items.map(Playlist.init(resource:)), nextPageToken: response.nextPageToken)
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

    /// The account's subscription to a channel, if it has one — the resource ID unsubscribing
    /// takes. 1 unit.
    func subscriptionID(forChannel channelId: String) async throws -> String? {
        let response: YTListResponse<YTSubscriptionItem> = try await request(
            path: "subscriptions",
            query: ["part": "id", "mine": "true", "forChannelId": channelId],
            requiresAuth: true
        )
        return response.items.first?.id
    }

    /// Subscribes the account to a channel and returns the new subscription's ID. 50 units.
    func subscribe(toChannel channelId: String) async throws -> String {
        struct Body: Encodable {
            struct Snippet: Encodable {
                struct ResourceId: Encodable {
                    let kind = "youtube#channel"
                    let channelId: String
                }
                let resourceId: ResourceId
            }
            let snippet: Snippet
        }
        struct Created: Decodable {
            let id: String
        }

        let created: Created = try await send(
            "POST",
            path: "subscriptions",
            query: ["part": "snippet"],
            body: Body(snippet: .init(resourceId: .init(channelId: channelId)))
        )
        return created.id
    }

    /// Ends a subscription, by the subscription's ID rather than the channel's. 50 units.
    func unsubscribe(subscriptionID: String) async throws {
        try await sendDiscardingResponse("DELETE", path: "subscriptions", query: ["id": subscriptionID])
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

    // MARK: - Custom playlists (OAuth, read/write)
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

    /// Finds playlist item ids for a specific video in a playlist.
    func playlistItemIds(playlistId: String, videoId: String) async throws -> [String] {
        let response: YTListResponse<YTPlaylistItemResource> = try await request(
            path: "playlistItems",
            query: [
                "part": "id",
                "playlistId": playlistId,
                "videoId": videoId,
                "maxResults": "50"
            ],
            requiresAuth: true
        )
        return response.items.map(\.id)
    }

    /// Removes a video from a playlist by deleting its playlist items.
    func removeFromPlaylist(playlistId: String, videoId: String) async throws {
        let itemIds = try await playlistItemIds(playlistId: playlistId, videoId: videoId)
        for itemId in itemIds {
            try await removePlaylistItem(id: itemId)
        }
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

    /// How many channels one feed reads. Each one costs a `playlistItems.list` of its own, so
    /// this is the knob that decides what a feed refresh costs; the caller puts the channels it
    /// cares about most at the front, because this takes them in order.
    private static let feedChannelLimit = 100

    /// Recent uploads across an arbitrary set of channels, newest first.
    ///
    /// Costs a `channels.list` per 50 channels plus one `playlistItems.list` each (1 unit
    /// apiece) — the same feed via `search.list` would cost 100 units per channel. `enriched`
    /// adds a `videos.list` per 50 results for durations and counts; a caller that only needs
    /// titles and dates, like the new-upload check, can skip it.
    func videos(
        fromChannels channelIds: [String],
        perChannel: Int = 4,
        limit: Int = 40,
        enriched: Bool = true
    ) async throws -> [Video] {
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
        let newest = Array(sorted.prefix(limit))
        return enriched ? await enrich(newest) : newest
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

/// YouTube's oEmbed endpoint: a video's title, channel name and thumbnail, public and keyless.
///
/// What opening a link falls back on before any credentials are set up — or once the day's
/// quota is spent, since this costs none. It knows nothing the Data API doesn't, and lacks the
/// channel's ID, counts and duration, so it is only ever the second choice.
enum YouTubeOEmbed {
    private struct Response: Decodable {
        let title: String
        let authorName: String?
        let thumbnailURL: URL?

        enum CodingKeys: String, CodingKey {
            case title
            case authorName = "author_name"
            case thumbnailURL = "thumbnail_url"
        }
    }

    static func video(id: String, session: URLSession = .shared) async -> Video? {
        var components = URLComponents(string: "https://www.youtube.com/oembed")
        components?.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(id)"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return Video(
            id: id,
            title: decoded.title,
            channelId: "",
            channelTitle: decoded.authorName ?? "",
            description: "",
            thumbnailURL: decoded.thumbnailURL ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"),
            publishedAt: nil
        )
    }
}
