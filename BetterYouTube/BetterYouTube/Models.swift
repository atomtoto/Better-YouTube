import Foundation

// MARK: - Domain models

struct Video: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let title: String
    let channelId: String
    let channelTitle: String
    let description: String
    let thumbnailURL: URL?
    let publishedAt: Date?
    var viewCount: Int?
    var likeCount: Int?
    var duration: String?

    var watchURL: URL? { URL(string: "https://www.youtube.com/watch?v=\(id)") }

    static func == (lhs: Video, rhs: Video) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct Channel: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let title: String
    let description: String
    let thumbnailURL: URL?
    var subscriberCount: Int?
    var videoCount: Int?
}

struct Playlist: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let title: String
    let description: String
    let thumbnailURL: URL?
    var itemCount: Int?
    var channelTitle: String?
}

struct VideoComment: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let authorName: String
    let authorAvatarURL: URL?
    let text: String
    let likeCount: Int
    let publishedAt: Date?
}

/// Search results can contain either a video or a channel.
enum SearchResult: Identifiable, Hashable {
    case video(Video)
    case channel(Channel)

    var id: String {
        switch self {
        case .video(let v): return "video-\(v.id)"
        case .channel(let c): return "channel-\(c.id)"
        }
    }
}

// MARK: - YouTube Data API v3 response models

struct YTListResponse<Item: Decodable>: Decodable {
    let items: [Item]
    let nextPageToken: String?
}

struct YTThumbnail: Decodable {
    let url: URL
}

struct YTThumbnails: Decodable {
    let defaultThumb: YTThumbnail?
    let medium: YTThumbnail?
    let high: YTThumbnail?
    let standard: YTThumbnail?
    let maxres: YTThumbnail?

    enum CodingKeys: String, CodingKey {
        case defaultThumb = "default"
        case medium, high, standard, maxres
    }

    var bestURL: URL? {
        (maxres ?? standard ?? high ?? medium ?? defaultThumb)?.url
    }
}

/// `id` is a nested object on `search.list` items and on playlist-item resource references.
struct YTResourceId: Decodable {
    let kind: String?
    let videoId: String?
    let channelId: String?
    let playlistId: String?
}

struct YTSnippet: Decodable {
    let title: String?
    let description: String?
    let channelId: String?
    let channelTitle: String?
    let thumbnails: YTThumbnails?
    let publishedAt: String?
    let resourceId: YTResourceId?
    let videoOwnerChannelId: String?
    let videoOwnerChannelTitle: String?
}

struct YTStatistics: Decodable {
    let viewCount: String?
    let likeCount: String?
    let subscriberCount: String?
    let videoCount: String?
}

struct YTRelatedPlaylists: Decodable {
    let uploads: String?
}

struct YTContentDetails: Decodable {
    let duration: String?
    let relatedPlaylists: YTRelatedPlaylists?
    let itemCount: Int?
    let videoId: String?
}

/// `videos.list`, `channels.list` and `playlists.list` items expose `id` as a plain string.
struct YTResourceItem: Decodable {
    let id: String
    let snippet: YTSnippet?
    let statistics: YTStatistics?
    let contentDetails: YTContentDetails?
}

struct YTSearchItem: Decodable {
    let id: YTResourceId
    let snippet: YTSnippet?
}

struct YTPlaylistItemResource: Decodable {
    let id: String
    let snippet: YTSnippet?
    let contentDetails: YTContentDetails?
}

struct YTSubscriptionItem: Decodable {
    let id: String
    let snippet: YTSnippet?
}

struct YTCommentThreadItem: Decodable {
    let id: String
    let snippet: YTCommentThreadSnippet
}

struct YTCommentThreadSnippet: Decodable {
    let topLevelComment: YTCommentItem
}

struct YTCommentItem: Decodable {
    let snippet: YTCommentSnippet
}

struct YTCommentSnippet: Decodable {
    let authorDisplayName: String
    let authorProfileImageUrl: URL?
    let textDisplay: String
    let likeCount: Int
    let publishedAt: String?
}

struct YTErrorResponse: Decodable {
    struct YTError: Decodable {
        let message: String
    }
    let error: YTError
}

// MARK: - Mapping

enum YTDateParser {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain = ISO8601DateFormatter()

    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        return fractional.date(from: string) ?? plain.date(from: string)
    }
}

extension Video {
    init(resource: YTResourceItem) {
        self.id = resource.id
        self.title = resource.snippet?.title ?? ""
        self.channelId = resource.snippet?.channelId ?? ""
        self.channelTitle = resource.snippet?.channelTitle ?? ""
        self.description = resource.snippet?.description ?? ""
        self.thumbnailURL = resource.snippet?.thumbnails?.bestURL
        self.publishedAt = YTDateParser.parse(resource.snippet?.publishedAt)
        self.viewCount = resource.statistics?.viewCount.flatMap { Int($0) }
        self.likeCount = resource.statistics?.likeCount.flatMap { Int($0) }
        self.duration = resource.contentDetails?.duration.map(ISO8601DurationFormatter.humanReadable)
    }

    init?(searchItem: YTSearchItem) {
        guard let videoId = searchItem.id.videoId else { return nil }
        self.id = videoId
        self.title = searchItem.snippet?.title ?? ""
        self.channelId = searchItem.snippet?.channelId ?? ""
        self.channelTitle = searchItem.snippet?.channelTitle ?? ""
        self.description = searchItem.snippet?.description ?? ""
        self.thumbnailURL = searchItem.snippet?.thumbnails?.bestURL
        self.publishedAt = YTDateParser.parse(searchItem.snippet?.publishedAt)
    }

    init?(playlistItem: YTPlaylistItemResource) {
        guard let videoId = playlistItem.contentDetails?.videoId ?? playlistItem.snippet?.resourceId?.videoId else {
            return nil
        }
        self.id = videoId
        self.title = playlistItem.snippet?.title ?? ""
        self.channelId = playlistItem.snippet?.videoOwnerChannelId ?? playlistItem.snippet?.channelId ?? ""
        self.channelTitle = playlistItem.snippet?.videoOwnerChannelTitle ?? playlistItem.snippet?.channelTitle ?? ""
        self.description = playlistItem.snippet?.description ?? ""
        self.thumbnailURL = playlistItem.snippet?.thumbnails?.bestURL
        self.publishedAt = YTDateParser.parse(playlistItem.snippet?.publishedAt)
    }
}

extension Channel {
    init(resource: YTResourceItem) {
        self.id = resource.id
        self.title = resource.snippet?.title ?? ""
        self.description = resource.snippet?.description ?? ""
        self.thumbnailURL = resource.snippet?.thumbnails?.bestURL
        self.subscriberCount = resource.statistics?.subscriberCount.flatMap { Int($0) }
        self.videoCount = resource.statistics?.videoCount.flatMap { Int($0) }
    }

    init?(searchItem: YTSearchItem) {
        guard let channelId = searchItem.id.channelId else { return nil }
        self.id = channelId
        self.title = searchItem.snippet?.title ?? ""
        self.description = searchItem.snippet?.description ?? ""
        self.thumbnailURL = searchItem.snippet?.thumbnails?.bestURL
    }

    init?(subscription: YTSubscriptionItem) {
        guard let channelId = subscription.snippet?.resourceId?.channelId else { return nil }
        self.id = channelId
        self.title = subscription.snippet?.title ?? ""
        self.description = subscription.snippet?.description ?? ""
        self.thumbnailURL = subscription.snippet?.thumbnails?.bestURL
    }
}

extension Playlist {
    init(resource: YTResourceItem) {
        self.id = resource.id
        self.title = resource.snippet?.title ?? ""
        self.description = resource.snippet?.description ?? ""
        self.thumbnailURL = resource.snippet?.thumbnails?.bestURL
        self.itemCount = resource.contentDetails?.itemCount
        self.channelTitle = resource.snippet?.channelTitle
    }
}

extension VideoComment {
    init(thread: YTCommentThreadItem) {
        let snippet = thread.snippet.topLevelComment.snippet
        self.id = thread.id
        self.authorName = snippet.authorDisplayName
        self.authorAvatarURL = snippet.authorProfileImageUrl
        self.text = snippet.textDisplay
        self.likeCount = snippet.likeCount
        self.publishedAt = YTDateParser.parse(snippet.publishedAt)
    }
}
