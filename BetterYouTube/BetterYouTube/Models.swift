import Foundation

// MARK: - Video

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

    static func == (lhs: Video, rhs: Video) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Channel

struct Channel: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let title: String
    let description: String
    let thumbnailURL: URL?
    var subscriberCount: Int?
    var videoCount: Int?
}

// MARK: - Comment

struct VideoComment: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let authorName: String
    let authorAvatarURL: URL?
    let text: String
    let likeCount: Int
    let publishedAt: Date?
}

// MARK: - YouTube Data API v3 raw response models

struct YTListResponse<Item: Decodable>: Decodable {
    let items: [Item]
    let nextPageToken: String?
}

struct YTThumbnails: Decodable {
    let defaultThumb: YTThumbnail?
    let medium: YTThumbnail?
    let high: YTThumbnail?

    enum CodingKeys: String, CodingKey {
        case defaultThumb = "default"
        case medium
        case high
    }

    var bestURL: URL? {
        (high ?? medium ?? defaultThumb)?.url
    }
}

struct YTThumbnail: Decodable {
    let url: URL
}

struct YTSnippet: Decodable {
    let title: String
    let description: String
    let channelId: String?
    let channelTitle: String?
    let thumbnails: YTThumbnails?
    let publishedAt: String?
}

struct YTStatistics: Decodable {
    let viewCount: String?
    let likeCount: String?
    let subscriberCount: String?
    let videoCount: String?
}

struct YTContentDetails: Decodable {
    let duration: String?
}

/// `videos.list` / `channels.list` items expose `id` as a plain string.
struct YTResourceItem: Decodable {
    let id: String
    let snippet: YTSnippet?
    let statistics: YTStatistics?
    let contentDetails: YTContentDetails?
}

/// `search.list` items expose `id` as a nested object.
struct YTSearchItem: Decodable {
    let id: YTSearchItemId
    let snippet: YTSnippet?
}

struct YTSearchItemId: Decodable {
    let kind: String
    let videoId: String?
    let channelId: String?
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

// MARK: - Mapping helpers

enum YTDateParser {
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = formatter.date(from: string) { return date }
        let fallback = ISO8601DateFormatter()
        return fallback.date(from: string)
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
        self.viewCount = nil
        self.likeCount = nil
        self.duration = nil
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
        self.subscriberCount = nil
        self.videoCount = nil
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
