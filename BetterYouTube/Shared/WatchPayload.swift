import Foundation

/// Small, credential-free values exchanged with the companion watch app.
struct WatchVideo: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let channel: String
    let thumbnailURL: URL?

    init(id: String, title: String, channel: String, thumbnailURL: URL?) {
        self.id = id
        self.title = title
        self.channel = channel
        self.thumbnailURL = thumbnailURL
    }
}

struct WatchChannel: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let thumbnailURL: URL?
}

struct WatchPlaylist: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let thumbnailURL: URL?
}

struct WatchAccountLibrary: Codable, Equatable {
    var subscriptions: [WatchChannel]
    var playlists: [WatchPlaylist]
    var likedVideos: [WatchVideo]

    static let empty = WatchAccountLibrary(subscriptions: [], playlists: [], likedVideos: [])
}

struct WatchLocalLibrary: Codable, Equatable {
    var favorites: [WatchVideo]
    var watchLater: [WatchVideo]
    var history: [WatchVideo]
    var downloads: [WatchVideo]
}

struct WatchSnapshot: Codable, Equatable {
    var current: WatchVideo?
    var isPlaying: Bool
    var elapsed: Double
    var duration: Double
    var upNext: [WatchVideo]
    var homeFeed: [WatchVideo]
    var favorites: [WatchVideo]
    var watchLater: [WatchVideo]
    var history: [WatchVideo]
    var downloads: [WatchVideo]
    var accountSignedIn: Bool
    var updatedAt: Date

    static let empty = WatchSnapshot(
        current: nil,
        isPlaying: false,
        elapsed: 0,
        duration: 0,
        upNext: [],
        homeFeed: [],
        favorites: [],
        watchLater: [],
        history: [],
        downloads: [],
        accountSignedIn: false,
        updatedAt: .distantPast
    )
}

enum WatchMessage {
    static let snapshot = "snapshot"
    static let localLibrary = "localLibrary"
    static let command = "command"
    static let videoID = "videoID"
    static let error = "error"
    static let apiKey = "apiKey"
    static let mediaURL = "mediaURL"
    static let byteCount = "byteCount"
    static let videos = "videos"
}

/// A WatchConnectivity message, reply or application context, carried from the session's own
/// queue to the main actor.
///
/// They hold only property-list values — strings, numbers, data, dates, and arrays and
/// dictionaries of those — which are immutable once built, so handing one across can't race. The
/// compiler can't see that through `[String: Any]`; this says it on its behalf, in one place.
struct WatchDictionary: @unchecked Sendable {
    let value: [String: Any]

    init(_ value: [String: Any]) {
        self.value = value
    }
}

/// The handler WatchConnectivity gives for answering a message. The framework documents it as
/// callable from any thread, which its plain closure type can't say.
struct WatchReply: @unchecked Sendable {
    let send: ([String: Any]) -> Void
}
