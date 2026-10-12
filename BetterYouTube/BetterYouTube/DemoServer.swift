import Foundation

/// The YouTube Data API, as the demo plays it.
///
/// While a demo runs, the app's requests to the API never leave the device: `DemoURLProtocol`
/// hands them here, and the answers come from `DemoCatalog` in the API's own JSON. So every
/// screen works exactly as it does signed in — the same client, the same decoding, the same code
/// — without an account, a key or a unit of quota.
///
/// The demo has an account of its own to show — subscriptions, two playlists, liked videos — but
/// it is read-only: anything that would write to YouTube comes back refused, with a message the
/// screen asking shows as it would any other refusal. Comments aren't part of the catalogue.
enum DemoServer {
    /// What the client sends as an access token in the demo. Never checked: it only has to exist,
    /// because the calls about the account won't go out without one.
    static let accessToken = "demo-access-token"

    /// Whether a request is one this answers: anything for the Data API.
    static func handles(_ request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.host() == "www.googleapis.com" && url.path().hasPrefix("/youtube/v3/")
    }

    /// The status and JSON body the API would give.
    static func response(to request: URLRequest, catalog: DemoCatalog = .shared) -> (status: Int, body: Data) {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return error(400, "Bad request") }
        let endpoint = String(url.path().dropFirst("/youtube/v3/".count))
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }

        guard (request.httpMethod ?? "GET").uppercased() == "GET" else {
            return error(403, String(localized: "Not available in the demo. Sign in with Google to like videos, subscribe, comment and edit playlists."), reason: "demoMode")
        }
        let server = Responder(catalog: catalog, query: query)
        switch endpoint {
        case "videos": return server.videos()
        case "videos/getRating": return server.ratings()
        case "search": return server.search()
        case "channels": return server.channels()
        case "playlists": return server.playlists()
        case "playlistItems": return server.playlistItems()
        case "subscriptions": return server.subscriptions()
        case "commentThreads", "comments":
            return error(403, String(localized: "Comments aren't part of the demo. Sign in with Google or add an API key to read them."), reason: "demoMode")
        default:
            return error(404, "Not found")
        }
    }

    static func error(_ status: Int, _ message: String, reason: String? = nil) -> (status: Int, body: Data) {
        var error: [String: Any] = ["code": status, "message": message]
        if let reason { error["errors"] = [["reason": reason, "message": message]] }
        return (status, json(["error": error]))
    }

    fileprivate static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

// MARK: - The demo's account

extension DemoServer {
    /// The account's own channel, shown at the top of Settings.
    static var accountTitle: String { String(localized: "Demo Account") }

    /// Every channel in the catalogue but the one-video curiosity.
    static func subscriptions(in catalog: DemoCatalog) -> [DemoCatalog.Channel] {
        catalog.channels.filter { catalog.uploads(of: $0.id).count > 1 }
    }

    /// A first video from each channel, which is what the account has liked.
    static func likedVideos(in catalog: DemoCatalog) -> [DemoCatalog.Video] {
        catalog.channels.compactMap { catalog.uploads(of: $0.id).first }
    }

    /// The account's own playlists: one of space, one of animation.
    static func accountPlaylists(in catalog: DemoCatalog) -> [DemoCatalog.Playlist] {
        let space = Set(catalog.channels.filter { ["@NASA", "@CnesFrance"].contains($0.handle) }.map(\.id))
        let spaceVideos = catalog.videos.filter { space.contains($0.channelId) }.prefix(8).map(\.id)
        let animation = catalog.videos.filter { $0.categoryId == "1" }.prefix(8).map(\.id)
        return [
            DemoCatalog.Playlist(id: "PLdemo-space", title: String(localized: "Space"),
                                 description: String(localized: "Launches, landings and the view from orbit."),
                                 videoIds: Array(spaceVideos)),
            DemoCatalog.Playlist(id: "PLdemo-animation", title: String(localized: "Animated Films"),
                                 description: String(localized: "Short films to watch tonight."),
                                 videoIds: Array(animation)),
        ].filter { !$0.videoIds.isEmpty }
    }
}

// MARK: - Answering

private struct Responder {
    let catalog: DemoCatalog
    let query: [String: String]

    private var ids: [String] {
        (query["id"] ?? "").split(separator: ",").map(String.init)
    }

    private var maxResults: Int {
        min(50, max(1, Int(query["maxResults"] ?? "") ?? 5))
    }

    /// A page of `items`, with the token for the next one when there is more. The token is just
    /// where the next page starts.
    private func page<Item>(_ items: [Item], render: (Item) -> Any) -> (status: Int, body: Data) {
        let start = min(items.count, Int(query["pageToken"] ?? "") ?? 0)
        let end = min(items.count, start + maxResults)
        var body: [String: Any] = [
            "items": items[start..<end].map(render),
            "pageInfo": ["totalResults": items.count, "resultsPerPage": maxResults],
        ]
        if end < items.count { body["nextPageToken"] = String(end) }
        return (200, DemoServer.json(body))
    }

    private func all<Item>(_ items: [Item], render: (Item) -> Any) -> (status: Int, body: Data) {
        (200, DemoServer.json(["items": items.map(render)]))
    }

    // MARK: Endpoints

    func videos() -> (status: Int, body: Data) {
        if query["chart"] == "mostPopular" {
            var popular = catalog.videos.sorted { $0.views > $1.views }
            if let category = query["videoCategoryId"], !category.isEmpty {
                popular = popular.filter { $0.categoryId == category }
            }
            return page(popular, render: videoResource)
        }
        if query["myRating"] == "like" {
            return page(DemoServer.likedVideos(in: catalog), render: videoResource)
        }
        return all(ids.compactMap(catalog.video), render: videoResource)
    }

    func ratings() -> (status: Int, body: Data) {
        let liked = Set(DemoServer.likedVideos(in: catalog).map(\.id))
        return all(ids) { id in ["videoId": id, "rating": liked.contains(id) ? "like" : "none"] }
    }

    func search() -> (status: Int, body: Data) {
        let text = query["q"] ?? ""
        var videos = catalog.search(text)
        let duration = query["videoDuration"] ?? "any"
        videos = videos.filter { video in
            switch duration {
            case "short": video.seconds < 4 * 60
            case "medium": (4 * 60...20 * 60).contains(video.seconds)
            case "long": video.seconds > 20 * 60
            default: true
            }
        }
        if let after = YTDateParser.parse(query["publishedAfter"]) {
            videos = videos.filter { ($0.publishedDate ?? .distantPast) >= after }
        }
        switch query["order"] {
        case "date": videos.sort { $0.publishedAt > $1.publishedAt }
        case "viewCount", "rating": videos.sort { $0.views > $1.views }
        default: break
        }
        let channels = (query["type"] ?? "").contains("channel") ? catalog.searchChannels(text) : []
        // Channels first, as YouTube puts a channel that matches the search at the top.
        let results: [Any] = channels.map(searchChannel) + videos.map(searchVideo)
        return page(results) { $0 }
    }

    func channels() -> (status: Int, body: Data) {
        if query["mine"] == "true" {
            return all([0]) { _ in
                [
                    "id": "UCdemo-account",
                    "snippet": ["title": DemoServer.accountTitle, "description": ""],
                    "statistics": ["subscriberCount": "0", "videoCount": "0"],
                ]
            }
        }
        if let handle = query["forHandle"] {
            return all([catalog.channel(handle: handle)].compactMap { $0 }, render: channelResource)
        }
        return all(ids.compactMap { catalog.channel($0) }, render: channelResource)
    }

    func playlists() -> (status: Int, body: Data) {
        let mine = DemoServer.accountPlaylists(in: catalog)
        if query["mine"] == "true" {
            return page(mine) { playlistResource($0, owner: DemoServer.accountTitle) }
        }
        if let channelId = query["channelId"] {
            // The catalogue's playlists come from the channel whose uploads they hold most of.
            let owned = catalog.playlists.filter { owner(of: $0)?.id == channelId }
            return page(owned) { playlistResource($0, owner: owner(of: $0)?.title ?? "") }
        }
        let known = catalog.playlists + mine
        return all(ids.compactMap { id in known.first { $0.id == id } }) { playlist in
            playlistResource(playlist, owner: owner(of: playlist)?.title ?? DemoServer.accountTitle)
        }
    }

    func playlistItems() -> (status: Int, body: Data) {
        let playlistId = query["playlistId"] ?? ""
        var videos: [DemoCatalog.Video]
        if playlistId.hasPrefix("UU") {
            // A channel's uploads, newest first, under the playlist id the API gives them.
            videos = catalog.uploads(of: "UC" + playlistId.dropFirst(2))
        } else if let playlist = (catalog.playlists + DemoServer.accountPlaylists(in: catalog)).first(where: { $0.id == playlistId }) {
            videos = playlist.videoIds.compactMap(catalog.video)
        } else {
            return DemoServer.error(404, "The playlist identified with the request's playlistId parameter cannot be found.", reason: "playlistNotFound")
        }
        if let videoId = query["videoId"] {
            videos = videos.filter { $0.id == videoId }
        }
        return page(videos) { video in
            [
                "id": "item-\(playlistId)-\(video.id)",
                "snippet": [
                    "title": video.title,
                    "description": video.description,
                    "publishedAt": video.publishedAt,
                    "channelId": video.channelId,
                    "channelTitle": catalog.channel(video.channelId)?.title ?? "",
                    "videoOwnerChannelId": video.channelId,
                    "videoOwnerChannelTitle": catalog.channel(video.channelId)?.title ?? "",
                    "thumbnails": thumbnails(of: video),
                    "resourceId": ["kind": "youtube#video", "videoId": video.id],
                ] as [String: Any],
                "contentDetails": ["videoId": video.id],
            ]
        }
    }

    func subscriptions() -> (status: Int, body: Data) {
        var channels = DemoServer.subscriptions(in: catalog)
        if let channelId = query["forChannelId"] {
            channels = channels.filter { $0.id == channelId }
        }
        return page(channels) { channel in
            [
                "id": "sub-\(channel.id)",
                "snippet": [
                    "title": channel.title,
                    "description": channel.description,
                    "resourceId": ["kind": "youtube#channel", "channelId": channel.id],
                    "thumbnails": avatar(of: channel),
                ] as [String: Any],
            ]
        }
    }

    // MARK: Resources, in the API's shapes

    private func thumbnails(of video: DemoCatalog.Video) -> [String: Any] {
        var sizes: [String: Any] = [
            "medium": ["url": "https://i.ytimg.com/vi/\(video.id)/mqdefault.jpg"],
            "high": ["url": "https://i.ytimg.com/vi/\(video.id)/hqdefault.jpg"],
        ]
        if video.hasMaxres { sizes["maxres"] = ["url": "https://i.ytimg.com/vi/\(video.id)/maxresdefault.jpg"] }
        return sizes
    }

    private func avatar(of channel: DemoCatalog.Channel) -> [String: Any] {
        ["high": ["url": channel.avatar.absoluteString]]
    }

    private func videoResource(_ video: DemoCatalog.Video) -> Any {
        [
            "id": video.id,
            "snippet": [
                "title": video.title,
                "description": video.description,
                "publishedAt": video.publishedAt,
                "channelId": video.channelId,
                "channelTitle": catalog.channel(video.channelId)?.title ?? "",
                "categoryId": video.categoryId,
                "thumbnails": thumbnails(of: video),
            ] as [String: Any],
            "statistics": ["viewCount": String(video.views)],
            "contentDetails": ["duration": video.duration],
        ]
    }

    private func channelResource(_ channel: DemoCatalog.Channel) -> Any {
        var statistics: [String: String] = [:]
        if let subscribers = channel.subscribers { statistics["subscriberCount"] = String(subscribers) }
        if let count = channel.videoCount { statistics["videoCount"] = String(count) }
        return [
            "id": channel.id,
            "snippet": [
                "title": channel.title,
                "description": channel.description,
                "thumbnails": avatar(of: channel),
            ] as [String: Any],
            "statistics": statistics,
            "contentDetails": ["relatedPlaylists": ["uploads": "UU" + channel.id.dropFirst(2)]],
        ]
    }

    private func playlistResource(_ playlist: DemoCatalog.Playlist, owner: String) -> Any {
        let first = playlist.videoIds.first.flatMap(catalog.video)
        return [
            "id": playlist.id,
            "snippet": [
                "title": playlist.title,
                "description": playlist.description,
                "channelTitle": owner,
                "thumbnails": first.map(thumbnails) ?? [:],
            ] as [String: Any],
            "contentDetails": ["itemCount": playlist.videoIds.count],
        ]
    }

    private func searchVideo(_ video: DemoCatalog.Video) -> Any {
        [
            "id": ["kind": "youtube#video", "videoId": video.id],
            "snippet": [
                "title": video.title,
                "description": video.description,
                "publishedAt": video.publishedAt,
                "channelId": video.channelId,
                "channelTitle": catalog.channel(video.channelId)?.title ?? "",
                "thumbnails": thumbnails(of: video),
            ] as [String: Any],
        ]
    }

    private func searchChannel(_ channel: DemoCatalog.Channel) -> Any {
        [
            "id": ["kind": "youtube#channel", "channelId": channel.id],
            "snippet": [
                "title": channel.title,
                "description": channel.description,
                "thumbnails": avatar(of: channel),
            ] as [String: Any],
        ]
    }

    /// The channel most of a playlist's videos come from.
    private func owner(of playlist: DemoCatalog.Playlist) -> DemoCatalog.Channel? {
        let counts = Dictionary(grouping: playlist.videoIds.compactMap { catalog.video($0)?.channelId }, by: { $0 })
        return counts.max { $0.value.count < $1.value.count }.flatMap { catalog.channel($0.key) }
    }
}

// MARK: - On the wire

/// Takes the app's requests to the Data API while a demo runs and answers them from the
/// catalogue. Registered once at launch for the shared URL session, which is the one the API
/// client uses; it declines every request when no demo is running, so outside one the network
/// carries on as if it weren't there.
final class DemoURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        DemoMode.isRunning && DemoServer.handles(request)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, body) = DemoServer.response(to: request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json; charset=UTF-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
