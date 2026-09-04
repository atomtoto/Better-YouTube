import Foundation

enum APIError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case server(String)
    case http(Int)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a YouTube Data API v3 key in Settings to use Better YouTube."
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

/// Thin client around the public YouTube Data API v3 (https://developers.google.com/youtube/v3).
actor YouTubeAPIService {
    static let shared = YouTubeAPIService()

    private let baseURL = URL(string: "https://www.googleapis.com/youtube/v3/")!
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        let decoder = JSONDecoder()
        self.decoder = decoder
    }

    private var apiKey: String {
        get async { await MainActor.run { APIKeyStore.shared.apiKey } }
    }

    private func request<T: Decodable>(path: String, query: [String: String]) async throws -> T {
        let key = await apiKey
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError.missingAPIKey
        }
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "key", value: key))
        components.queryItems = items

        guard let url = components.url else { throw APIError.invalidURL }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw APIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(-1)
        }

        guard (200..<300).contains(http.statusCode) else {
            if let errorBody = try? decoder.decode(YTErrorResponse.self, from: data) {
                throw APIError.server(errorBody.error.message)
            }
            throw APIError.http(http.statusCode)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    // MARK: - Public endpoints

    func trendingVideos(regionCode: String = "US", maxResults: Int = 25) async throws -> [Video] {
        let response: YTListResponse<YTResourceItem> = try await request(
            path: "videos",
            query: [
                "part": "snippet,statistics,contentDetails",
                "chart": "mostPopular",
                "regionCode": regionCode,
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
        return response.items.compactMap { item -> SearchResult? in
            switch item.id.kind {
            case "youtube#video":
                return Video(searchItem: item).map(SearchResult.video)
            case "youtube#channel":
                return Channel(searchItem: item).map(SearchResult.channel)
            default:
                return nil
            }
        }
    }

    func video(id: String) async throws -> Video? {
        let response: YTListResponse<YTResourceItem> = try await request(
            path: "videos",
            query: [
                "part": "snippet,statistics,contentDetails",
                "id": id
            ]
        )
        return response.items.first.map(Video.init(resource:))
    }

    func channel(id: String) async throws -> Channel? {
        let response: YTListResponse<YTResourceItem> = try await request(
            path: "channels",
            query: [
                "part": "snippet,statistics",
                "id": id
            ]
        )
        return response.items.first.map(Channel.init(resource:))
    }

    func videos(byChannel channelId: String, maxResults: Int = 25) async throws -> [Video] {
        let response: YTListResponse<YTSearchItem> = try await request(
            path: "search",
            query: [
                "part": "snippet",
                "channelId": channelId,
                "type": "video",
                "order": "date",
                "maxResults": "\(maxResults)"
            ]
        )
        return response.items.compactMap(Video.init(searchItem:))
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
}
