import Foundation
import Testing
@testable import BetterYouTube

/// The demo's catalogue, and the API client talking to the demo's server — the same client, the
/// same decoding the app uses — without a network or a demo running.
struct DemoModeTests {
    private let catalog = DemoCatalog.shared

    // MARK: The catalogue

    @Test("the bundled catalogue decodes and holds together")
    func catalogueIntegrity() {
        #expect(catalog.videos.count >= 30)
        #expect(catalog.channels.count >= 5)
        let channelIDs = Set(catalog.channels.map(\.id))
        let videoIDs = catalog.videos.map(\.id)
        #expect(Set(videoIDs).count == videoIDs.count, "video ids are unique")
        for video in catalog.videos {
            #expect(channelIDs.contains(video.channelId), "\(video.id)'s channel is in the catalogue")
            #expect(video.seconds > 0, "\(video.id) has a length")
            #expect(video.publishedDate != nil, "\(video.id) has a date")
        }
        for playlist in catalog.playlists {
            #expect(!playlist.videoIds.isEmpty)
            for id in playlist.videoIds { #expect(catalog.video(id) != nil, "\(id) of \(playlist.title)") }
        }
    }

    @Test("search ignores case and accents, and puts title matches first")
    func catalogueSearch() {
        let results = catalog.search("OPEN movie")
        #expect(!results.isEmpty)
        // Every word somewhere — title, channel or description — and the titles that hold them first.
        for video in results {
            let text = "\(video.title) \(catalog.channel(video.channelId)?.title ?? "") \(video.description)"
            #expect(text.localizedCaseInsensitiveContains("open") && text.localizedCaseInsensitiveContains("movie"), "\(video.title)")
        }
        #expect(results.first.map { $0.title.localizedCaseInsensitiveContains("open movie") } == true)
        #expect(catalog.search("cnes").count == catalog.search("CNÉS").count)
        #expect(catalog.search("   ").isEmpty)
    }

    @Test("suggestions come from the catalogue's own titles")
    func catalogueSuggestions() {
        let suggestions = catalog.suggestions(for: "spr")
        #expect(!suggestions.isEmpty)
        #expect(suggestions.allSatisfy { $0.localizedCaseInsensitiveContains("spr") })
        #expect(suggestions.count <= 8)
    }

    @Test("ISO 8601 lengths convert to seconds")
    func durationSeconds() {
        #expect(ISO8601DurationFormatter.seconds("PT10M35S") == 635)
        #expect(ISO8601DurationFormatter.seconds("PT1H10S") == 3610)
        #expect(ISO8601DurationFormatter.seconds("PT19S") == 19)
        #expect(ISO8601DurationFormatter.seconds("nonsense") == nil)
        #expect(ISO8601DurationFormatter.humanReadable("PT1H10S") == "1:00:10")
    }

    // MARK: The server, through the real client

    private func service(signedIn: Bool = true) -> YouTubeAPIService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DemoServerProtocol.self]
        return YouTubeAPIService(
            session: URLSession(configuration: configuration),
            credentials: { .init(accessToken: signedIn ? DemoServer.accessToken : nil, apiKey: signedIn ? "" : "demo") },
            recordSpend: { _, _ in }
        )
    }

    @Test("a search returns catalogue videos with their lengths, and channels when asked")
    func search() async throws {
        let page = try await service().search(query: "blender", pageToken: nil)
        #expect(!page.items.isEmpty)
        let videos = page.items.compactMap { if case .video(let video) = $0 { video } else { nil } }
        #expect(videos.allSatisfy { $0.duration != nil })
        #expect(page.items.contains { if case .channel = $0 { true } else { false } })
    }

    @Test("length filters narrow the demo's search too")
    func searchFilters() async throws {
        var filters = SearchFilters()
        filters.duration = .long
        let page = try await service().search(query: "blender", filters: filters, pageToken: nil)
        let videos = page.items.compactMap { if case .video(let video) = $0 { video } else { nil } }
        #expect(videos.allSatisfy { video in (catalog.video(video.id)?.seconds ?? 0) > 20 * 60 })
    }

    @Test("a channel's uploads come newest first, a page at a time")
    func uploads() async throws {
        let channel = try #require(catalog.channels.max { catalog.uploads(of: $0.id).count < catalog.uploads(of: $1.id).count })
        let api = service()
        let first = try await api.videos(byChannel: channel.id, maxResults: 3, pageToken: nil)
        #expect(first.items.count == 3)
        #expect(first.items.allSatisfy { $0.channelId == channel.id })
        let dates = first.items.compactMap(\.publishedAt)
        #expect(dates == dates.sorted(by: >))
        let next = try #require(first.nextPageToken)
        let second = try await api.videos(byChannel: channel.id, maxResults: 3, pageToken: next)
        #expect(Set(second.items.map(\.id)).isDisjoint(with: first.items.map(\.id)))
    }

    @Test("channels resolve by id and by handle, with or without the @")
    func channels() async throws {
        let blender = try #require(catalog.channels.first)
        let api = service()
        #expect(try await api.channel(id: blender.id)?.title == blender.title)
        #expect(try await api.channel(handle: blender.handle)?.id == blender.id)
        #expect(try await api.channel(handle: String(blender.handle.dropFirst()))?.id == blender.id)
        #expect(try await api.channel(id: "UCnope") == nil)
    }

    @Test("the demo account has subscriptions, playlists and liked videos")
    func account() async throws {
        let api = service()
        #expect(try await api.myChannel()?.title == DemoServer.accountTitle)
        let subscriptions = try await api.mySubscriptions()
        #expect(subscriptions.count == DemoServer.subscriptions(in: catalog).count)
        #expect(!subscriptions.isEmpty)
        let playlists = try await api.myPlaylists()
        #expect(!playlists.isEmpty)
        let first = try #require(playlists.first)
        #expect(try await api.videos(inPlaylist: first.id, pageToken: nil).items.count == first.itemCount)
        #expect(try await api.likedVideos().count == DemoServer.likedVideos(in: catalog).count)
        #expect(try await api.subscriptionID(forChannel: subscriptions[0].id) != nil)
    }

    @Test("anything that would change YouTube is refused with the demo's message")
    func writesAreRefused() async throws {
        let api = service()
        let video = try #require(catalog.videos.first)
        for attempt in [
            { try await api.rate(videoId: video.id, rating: .like) },
            { _ = try await api.subscribe(toChannel: video.channelId) },
            { _ = try await api.addComment(videoId: video.id, text: "Hello") },
        ] as [() async throws -> Void] {
            do {
                try await attempt()
                Issue.record("expected the demo to refuse a write")
            } catch APIError.server(let message) {
                #expect(!message.isEmpty)
            }
        }
    }

    @Test("comments say they aren't part of the demo")
    func comments() async throws {
        let video = try #require(catalog.videos.first)
        do {
            _ = try await service().comments(videoId: video.id)
            Issue.record("expected comments to be unavailable")
        } catch APIError.server(let message) {
            #expect(!message.isEmpty)
        }
    }

    @Test("YouTube's most popular chart is the catalogue by views")
    func chart() async throws {
        let videos = try await service().trendingVideos(maxResults: 10)
        #expect(videos.count == 10)
        let views = videos.compactMap(\.viewCount)
        #expect(views == views.sorted(by: >))
    }
}

/// Answers every request from `DemoServer`, whether or not a demo is running — which in the tests
/// it never is.
final class DemoServerProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { DemoServer.handles(request) }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = DemoServer.response(to: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
