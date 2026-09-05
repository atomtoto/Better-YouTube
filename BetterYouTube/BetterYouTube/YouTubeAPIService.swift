import Foundation

enum APIError: LocalizedError {
    case missingCredentials
    case notSignedIn
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
/// through the channel's uploads playlist rather than a search query.
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw APIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else { throw APIError.http(-1) }

        guard (200..<300).contains(http.statusCode) else {
            if let body = try? decoder.decode(YTErrorResponse.self, from: data) {
                throw APIError.server(body.error.message)
            }
            throw APIError.http(http.statusCode)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// Fills in duration/stats for videos that came from a cheap endpoint (1 quota unit per 50).
    private func enrich(_ videos: [Video]) async -> [Video] {
        guard !videos.isEmpty else { return [] }
        let ids = videos.prefix(50).map(\.id)
        do {
            let response: YTListResponse<YTResourceItem> = try await request(
                path: "videos",
                query: [
                    "part": "snippet,statistics,contentDetails",
                    "id": ids.joined(separator: ",")
                ]
            )
            let detailed = Dictionary(
                response.items.map { ($0.id, Video(resource: $0)) },
                uniquingKeysWith: { first, _ in first }
            )
            return videos.map { detailed[$0.id] ?? $0 }
        } catch {
            return videos
        }
    }

    // MARK: - Public content

    func trendingVideos(regionCode: String? = nil, maxResults: Int = 25) async throws -> [Video] {
        let region = regionCode ?? Locale.current.region?.identifier ?? "US"
        let response: YTListResponse<YTResourceItem> = try await request(
            path: "videos",
            query: [
                "part": "snippet,statistics,contentDetails",
                "chart": "mostPopular",
                "regionCode": region,
                "maxResults": "\(maxResults)"
            ]
        )
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

    func mySubscriptions(maxResults: Int = 50) async throws -> [Channel] {
        let response: YTListResponse<YTSubscriptionItem> = try await request(
            path: "subscriptions",
            query: [
                "part": "snippet",
                "mine": "true",
                "order": "alphabetical",
                "maxResults": "\(maxResults)"
            ],
            requiresAuth: true
        )
        return response.items.compactMap(Channel.init(subscription:))
    }

    func myPlaylists(maxResults: Int = 50) async throws -> [Playlist] {
        let response: YTListResponse<YTResourceItem> = try await request(
            path: "playlists",
            query: [
                "part": "snippet,contentDetails",
                "mine": "true",
                "maxResults": "\(maxResults)"
            ],
            requiresAuth: true
        )
        return response.items.map(Playlist.init(resource:))
    }

    func likedVideos(maxResults: Int = 50) async throws -> [Video] {
        let response: YTListResponse<YTResourceItem> = try await request(
            path: "videos",
            query: [
                "part": "snippet,statistics,contentDetails",
                "myRating": "like",
                "maxResults": "\(maxResults)"
            ],
            requiresAuth: true
        )
        return response.items.map(Video.init(resource:))
    }

    /// Latest uploads across the channels the user follows, newest first.
    func subscriptionFeed(channelLimit: Int = 25, perChannel: Int = 3) async throws -> [Video] {
        let channels = try await mySubscriptions(maxResults: channelLimit)
        return try await videos(fromChannels: channels.map(\.id), perChannel: perChannel)
    }

    /// Recent uploads across an arbitrary set of channels, newest first.
    ///
    /// Costs one `channels.list` call for the whole set plus one `playlistItems.list` per channel
    /// (1 unit each) — the same feed via `search.list` would cost 100 units per channel.
    func videos(fromChannels channelIds: [String], perChannel: Int = 4, limit: Int = 40) async throws -> [Video] {
        let ids = Array(Set(channelIds.filter { !$0.isEmpty })).prefix(50)
        guard !ids.isEmpty else { return [] }

        let response: YTListResponse<YTResourceItem> = try await request(
            path: "channels",
            query: ["part": "contentDetails", "id": ids.joined(separator: ",")]
        )
        let playlistIds = response.items.compactMap { item -> String? in
            guard let uploads = item.contentDetails?.relatedPlaylists?.uploads else { return nil }
            uploadsPlaylistCache[item.id] = uploads
            return uploads
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

    /// Channel avatars for feed rows — one batched call for up to 50 channels.
    func channelAvatars(ids: [String]) async -> [String: URL] {
        let unique = Array(Set(ids.filter { !$0.isEmpty })).prefix(50)
        guard !unique.isEmpty else { return [:] }

        let response: YTListResponse<YTResourceItem>? = try? await request(
            path: "channels",
            query: ["part": "snippet", "id": unique.joined(separator: ",")]
        )
        guard let items = response?.items else { return [:] }

        return Dictionary(
            items.compactMap { item -> (String, URL)? in
                guard let url = item.snippet?.thumbnails?.bestURL else { return nil }
                return (item.id, url)
            },
            uniquingKeysWith: { first, _ in first }
        )
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
