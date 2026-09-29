import Foundation

enum WatchSearchEntry: Identifiable {
    case video(WatchVideo)
    case channel(WatchChannel)

    var id: String {
        switch self {
        case .video(let video): "video-\(video.id)"
        case .channel(let channel): "channel-\(channel.id)"
        }
    }
}

enum WatchCatalogueError: LocalizedError {
    case noKey
    case response(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noKey: "Ajoute une clé API YouTube dans les réglages de l’iPhone, puis ouvre l’app sur la montre."
        case .response(let status): "YouTube a répondu avec le code \(status)."
        case .invalidResponse: "La réponse de YouTube est illisible."
        }
    }
}

actor WatchCatalogue {
    static let shared = WatchCatalogue()

    private struct Thumbnail: Decodable { let url: URL }
    private struct Thumbnails: Decodable {
        let medium: Thumbnail?
        let high: Thumbnail?
        let defaultThumb: Thumbnail?
        enum CodingKeys: String, CodingKey { case medium, high; case defaultThumb = "default" }
        var best: URL? { (high ?? medium ?? defaultThumb)?.url }
    }
    private struct Snippet: Decodable {
        let title: String
        let channelTitle: String?
        let thumbnails: Thumbnails?
    }
    private struct SearchID: Decodable {
        let videoId: String?
        let channelId: String?
    }
    private struct Item: Decodable {
        let id: String?
        let searchID: SearchID?
        let snippet: Snippet
        enum CodingKeys: String, CodingKey { case id, snippet }

        // `id` is a string in videos.list and an object in search.list.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decode(String.self, forKey: .id)
            searchID = try? container.decode(SearchID.self, forKey: .id)
            snippet = try container.decode(Snippet.self, forKey: .snippet)
        }
        var video: WatchVideo? {
            guard let identifier = id ?? searchID?.videoId else { return nil }
            return WatchVideo(id: identifier, title: snippet.title,
                              channel: snippet.channelTitle ?? "YouTube",
                              thumbnailURL: snippet.thumbnails?.best)
        }
        var searchEntry: WatchSearchEntry? {
            if let id = searchID?.channelId {
                return .channel(WatchChannel(id: id, title: snippet.title,
                                             thumbnailURL: snippet.thumbnails?.best))
            }
            return video.map(WatchSearchEntry.video)
        }
    }
    private struct Response: Decodable { let items: [Item] }
    private struct ChannelDetailsResponse: Decodable {
        struct ChannelItem: Decodable {
            struct Details: Decodable {
                struct Related: Decodable { let uploads: String? }
                let relatedPlaylists: Related?
            }
            let contentDetails: Details?
        }
        let items: [ChannelItem]
    }
    private struct PlaylistResponse: Decodable {
        struct PlaylistItem: Decodable {
            struct Details: Decodable { let videoId: String? }
            let snippet: Snippet
            let contentDetails: Details?
            var video: WatchVideo? {
                guard let id = contentDetails?.videoId else { return nil }
                return WatchVideo(id: id, title: snippet.title,
                                  channel: snippet.channelTitle ?? "YouTube",
                                  thumbnailURL: snippet.thumbnails?.best)
            }
        }
        let items: [PlaylistItem]
        let nextPageToken: String?
    }

    func trending(apiKey: String) async throws -> [WatchVideo] {
        let region = Locale.current.region?.identifier ?? "FR"
        return try await fetch(path: "videos", query: ["part": "snippet", "chart": "mostPopular",
                                                       "regionCode": region, "maxResults": "20"], apiKey: apiKey)
    }

    func search(_ term: String, apiKey: String) async throws -> [WatchSearchEntry] {
        let result: Response = try await request(path: "search",
            query: ["part": "snippet", "type": "video,channel", "q": term, "maxResults": "20"],
            apiKey: apiKey)
        return result.items.compactMap(\.searchEntry)
    }

    func channelVideos(_ id: String, apiKey: String) async throws -> [WatchVideo] {
        let details: ChannelDetailsResponse = try await request(path: "channels",
            query: ["part": "contentDetails", "id": id], apiKey: apiKey)
        guard let uploads = details.items.first?.contentDetails?.relatedPlaylists?.uploads else { return [] }
        return try await playlistVideos(uploads, apiKey: apiKey)
    }

    func playlistVideos(_ id: String, apiKey: String) async throws -> [WatchVideo] {
        var videos: [WatchVideo] = []
        var nextPage: String?
        repeat {
            var query = ["part": "snippet,contentDetails", "playlistId": id, "maxResults": "50"]
            if let nextPage { query["pageToken"] = nextPage }
            let result: PlaylistResponse = try await request(path: "playlistItems", query: query,
                                                             apiKey: apiKey)
            videos.append(contentsOf: result.items.compactMap(\.video))
            nextPage = result.nextPageToken
        } while nextPage != nil && videos.count < 200
        return videos
    }

    private func fetch(path: String, query: [String: String], apiKey: String) async throws -> [WatchVideo] {
        let result: Response = try await request(path: path, query: query, apiKey: apiKey)
        return result.items.compactMap(\.video)
    }

    private func request<Result: Decodable>(path: String, query: [String: String], apiKey: String) async throws -> Result {
        guard !apiKey.isEmpty else { throw WatchCatalogueError.noKey }
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/\(path)")!
        components.queryItems = (query.merging(["key": apiKey]) { _, new in new })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard let response = response as? HTTPURLResponse else { throw WatchCatalogueError.invalidResponse }
        guard response.statusCode == 200 else { throw WatchCatalogueError.response(response.statusCode) }
        guard let decoded = try? JSONDecoder().decode(Result.self, from: data) else {
            throw WatchCatalogueError.invalidResponse
        }
        return decoded
    }
}
