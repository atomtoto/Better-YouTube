import Foundation
import Testing
@testable import BetterYouTube

/// The API client against canned responses: what it asks for, what it makes of the answers, what
/// it charges, and how it reports failure — all without a network, a key or a charge to the real
/// day's quota.
struct YouTubeAPIServiceTests {
    // MARK: Pagination

    @Test("a playlist page decodes, carries its next-page token and is filled in with durations")
    func playlistPage() async throws {
        let stub = StubAPI()
        stub.respond(to: "playlistItems") { request in
            #expect(request.query["playlistId"] == "PL1")
            #expect(request.query["pageToken"] == nil)
            return Fixture.playlistItems(["a1", "a2"], next: "PAGE2")
        }
        stub.respond(to: "videos") { request in
            #expect(request.query["id"] == "a1,a2")
            return Fixture.videos(["a1", "a2"])
        }

        let page = try await stub.service.videos(inPlaylist: "PL1", pageToken: nil)

        #expect(page.items.map(\.id) == ["a1", "a2"])
        #expect(page.nextPageToken == "PAGE2")
        #expect(page.items.first?.duration == "10:35")
        #expect(page.items.first?.viewCount == 1234)
    }

    @Test("the next page asks for the token it was handed")
    func nextPage() async throws {
        let stub = StubAPI()
        stub.respond(to: "playlistItems") { request in
            #expect(request.query["pageToken"] == "PAGE2")
            return Fixture.playlistItems(["b1"], next: nil)
        }
        stub.respond(to: "videos") { _ in Fixture.videos(["b1"]) }

        let page = try await stub.service.videos(inPlaylist: "PL1", pageToken: "PAGE2")

        #expect(page.items.map(\.id) == ["b1"])
        #expect(page.nextPageToken == nil)
    }

    @Test("a video the details call doesn't return keeps what the playlist said")
    func enrichmentGap() async throws {
        let stub = StubAPI()
        stub.respond(to: "playlistItems") { _ in Fixture.playlistItems(["kept", "gone"], next: nil) }
        stub.respond(to: "videos") { _ in Fixture.videos(["kept"]) }

        let page = try await stub.service.videos(inPlaylist: "PL1", pageToken: nil)

        #expect(page.items.map(\.id) == ["kept", "gone"])
        #expect(page.items[0].duration == "10:35")
        #expect(page.items[1].duration == nil)
        #expect(page.items[1].title == "Video gone")
    }

    // MARK: Search

    @Test("search results are videos and channels, the videos given their durations")
    func searchResults() async throws {
        let stub = StubAPI()
        stub.respond(to: "search") { request in
            #expect(request.query["q"] == "pommes")
            #expect(request.query["type"] == "video,channel")
            return Fixture.search(videos: ["v1"], channels: ["UC1"], next: "S2")
        }
        stub.respond(to: "videos") { _ in Fixture.videos(["v1"]) }

        let page = try await stub.service.search(query: "pommes", pageToken: nil)

        #expect(page.items.count == 2)
        guard case .video(let video) = page.items[0], case .channel(let channel) = page.items[1] else {
            Issue.record("expected a video then a channel, got \(page.items)")
            return
        }
        #expect(video.id == "v1")
        #expect(video.duration == "10:35")
        #expect(channel.id == "UC1")
        #expect(page.nextPageToken == "S2")
    }

    @Test("length and date filters narrow the search to videos")
    func searchFilters() async throws {
        let stub = StubAPI()
        stub.respond(to: "search") { request in
            #expect(request.query["type"] == "video")
            #expect(request.query["videoDuration"] == "long")
            #expect(request.query["order"] == "date")
            #expect(request.query["publishedAfter"] != nil)
            return Fixture.search(videos: [], channels: [], next: nil)
        }

        var filters = SearchFilters()
        filters.duration = .long
        filters.order = .date
        filters.uploadDate = .week
        _ = try await stub.service.search(query: "x", filters: filters, pageToken: nil)
    }

    // MARK: Quota

    @Test("each call is charged at Google's price for its endpoint")
    func quotaCharges() async throws {
        let stub = StubAPI()
        stub.respond(to: "search") { _ in Fixture.search(videos: ["v1"], channels: [], next: nil) }
        stub.respond(to: "videos") { _ in Fixture.videos(["v1"]) }

        _ = try await stub.service.search(query: "x", pageToken: nil)

        #expect(stub.charges == [Charge(units: 100, endpoint: "search"), Charge(units: 1, endpoint: "videos")])
    }

    @Test("a refused call is charged too, as Google bills it")
    func refusedCallCharged() async throws {
        let stub = StubAPI()
        stub.respond(to: "videos") { _ in Fixture.error(status: 400, message: "Bad request") }

        await #expect(throws: APIError.self) {
            _ = try await stub.service.video(id: "x")
        }
        #expect(stub.charges == [Charge(units: 1, endpoint: "videos")])
    }

    // MARK: Failures

    @Test("with neither a key nor an account, nothing is sent")
    func missingCredentials() async throws {
        let stub = StubAPI(apiKey: "")

        do {
            _ = try await stub.service.video(id: "x")
            Issue.record("expected missing credentials")
        } catch APIError.missingCredentials {
            // Expected.
        }
        #expect(stub.requests.isEmpty)
        #expect(stub.charges.isEmpty)
    }

    @Test("an account-only call without an account says to sign in")
    func notSignedIn() async throws {
        let stub = StubAPI()

        do {
            _ = try await stub.service.myPlaylists()
            Issue.record("expected not signed in")
        } catch APIError.notSignedIn {
            // Expected.
        }
    }

    @Test("a sign-in that couldn't be renewed is not mistaken for no sign-in")
    func renewalFailed() async throws {
        let service = YouTubeAPIService(
            credentials: { .init(accessToken: nil, apiKey: "", renewalFailed: true) },
            recordSpend: { _, _ in }
        )
        do {
            _ = try await service.myPlaylists()
            Issue.record("expected the sign-in to be unreachable")
        } catch APIError.signInUnreachable {
            // Expected.
        }
        // A public call goes ahead on the key alone.
        let stub = StubAPI(renewalFailed: true)
        stub.respond(to: "videos") { _ in Fixture.videos(["x"]) }
        _ = try await stub.service.video(id: "x")
        #expect(stub.requests.count == 1)
    }

    @Test("Google's token errors read as a sentence, not as JSON")
    func tokenFailureMessage() {
        let body = Data(#"{"error": "invalid_grant", "error_description": "Bad Request"}"#.utf8)
        let message = GoogleAuthService.tokenFailureMessage(body, status: 400)
        #expect(message.contains("Bad Request"))
        #expect(message.contains("invalid_grant"))
        #expect(!message.contains("{"))
        #expect(!GoogleAuthService.tokenFailureMessage(Data("<html>".utf8), status: 503).contains("<html>"))
    }

    @Test("a 404 is told apart from other failures")
    func notFound() async throws {
        let stub = StubAPI()
        stub.respond(to: "playlists") { _ in Fixture.error(status: 404, message: "Playlist not found") }

        do {
            _ = try await stub.service.playlist(id: "gone")
            Issue.record("expected not found")
        } catch APIError.notFound {
            // Expected.
        }
    }

    @Test("Google's own message is what an error says")
    func serverMessage() async throws {
        let stub = StubAPI()
        stub.respond(to: "videos") { _ in Fixture.error(status: 403, message: "The request cannot be completed because you have exceeded your quota.", reason: "quotaExceeded") }

        do {
            _ = try await stub.service.video(id: "x")
            Issue.record("expected a server error")
        } catch APIError.server(let message) {
            #expect(message.contains("quota"))
        }
    }

    @Test("an unreadable answer is a decoding error, not a crash")
    func decodingError() async throws {
        let stub = StubAPI()
        stub.respond(to: "videos") { _ in (200, Data("not json".utf8)) }

        do {
            _ = try await stub.service.video(id: "x")
            Issue.record("expected a decoding error")
        } catch APIError.decoding {
            // Expected.
        }
    }

    @Test("the key goes in the query, and no account token with it")
    func keyInQuery() async throws {
        let stub = StubAPI()
        stub.respond(to: "videos") { request in
            #expect(request.query["key"] == stub.apiKey)
            #expect(request.authorization == nil)
            return Fixture.videos(["x"])
        }
        _ = try await stub.service.video(id: "x")
    }

    // MARK: Channel playlists

    @Test("a channel's playlists page through with their counts")
    @MainActor
    func channelPlaylists() async throws {
        let stub = StubAPI()
        stub.respond(to: "playlists") { request in
            #expect(request.query["channelId"] == "UC1")
            if request.query["pageToken"] == "P2" {
                return Fixture.playlists(["PL3"], next: nil)
            }
            return Fixture.playlists(["PL1", "PL2"], next: "P2")
        }

        let viewModel = ChannelViewModel(channelId: "UC1", service: stub.service)
        await viewModel.loadPlaylists()
        #expect(viewModel.playlists.map(\.id) == ["PL1", "PL2"])
        #expect(viewModel.canLoadMorePlaylists)
        #expect(viewModel.playlists.first?.itemCount == 12)

        await viewModel.loadPlaylists()
        #expect(viewModel.playlists.map(\.id) == ["PL1", "PL2", "PL3"])
        #expect(!viewModel.canLoadMorePlaylists)

        // Nothing left to ask for.
        await viewModel.loadPlaylists()
        #expect(stub.requests.count == 2)
    }

    // MARK: YouTube's suggestions

    @Test("YouTube's suggestion list is read from the second element")
    func suggestions() {
        let data = Data(#"["pomme de",["pomme de terre au four","pomme de reinette"],[],{"google:suggestsubtypes":[[512]]}]"#.utf8)
        #expect(YouTubeSuggestions.parse(data) == ["pomme de terre au four", "pomme de reinette"])
        #expect(YouTubeSuggestions.parse(Data("[]".utf8)).isEmpty)
        #expect(YouTubeSuggestions.parse(Data("oops".utf8)).isEmpty)
    }
}

// MARK: - The stub

/// One charge the client recorded.
struct Charge: Equatable, Sendable {
    let units: Int
    let endpoint: String
}

/// A request as the stub saw it.
struct StubRequest: Sendable {
    let endpoint: String
    let query: [String: String]
    let authorization: String?
}

/// A `YouTubeAPIService` whose network is a table of canned answers. Each stub has a key of its
/// own, which is how the shared URL protocol tells the tests' requests apart when they run side
/// by side.
final class StubAPI: @unchecked Sendable {
    typealias Responder = @Sendable (StubRequest) -> (Int, Data)

    let apiKey: String
    let service: YouTubeAPIService
    private let lock = NSLock()
    private var responders: [String: Responder] = [:]
    private var recordedRequests: [StubRequest] = []
    private var recordedCharges: [Charge] = []

    init(apiKey: String = "test-\(UUID().uuidString)", renewalFailed: Bool = false) {
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let routeKey = apiKey
        let box = WeakBox()
        service = YouTubeAPIService(
            session: URLSession(configuration: configuration),
            credentials: { .init(accessToken: nil, apiKey: routeKey, renewalFailed: renewalFailed) },
            recordSpend: { units, endpoint in box.stub?.record(Charge(units: units, endpoint: endpoint)) }
        )
        box.stub = self
        StubURLProtocol.register(self, for: apiKey)
    }

    deinit {
        StubURLProtocol.unregister(apiKey)
    }

    var requests: [StubRequest] { lock.withLock { recordedRequests } }
    var charges: [Charge] { lock.withLock { recordedCharges } }

    func respond(to endpoint: String, with responder: @escaping Responder) {
        lock.withLock { responders[endpoint] = responder }
    }

    fileprivate func answer(_ request: StubRequest) -> (Int, Data) {
        let responder = lock.withLock {
            recordedRequests.append(request)
            return responders[request.endpoint]
        }
        return responder?(request) ?? Fixture.error(status: 500, message: "No stub for \(request.endpoint)")
    }

    private func record(_ charge: Charge) {
        lock.withLock { recordedCharges.append(charge) }
    }

    private final class WeakBox: @unchecked Sendable {
        weak var stub: StubAPI?
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: WeakStub] = [:]

    private struct WeakStub {
        weak var stub: StubAPI?
    }

    static func register(_ stub: StubAPI, for key: String) {
        lock.withLock { stubs[key] = WeakStub(stub: stub) }
    }

    static func unregister(_ key: String) {
        _ = lock.withLock { stubs.removeValue(forKey: key) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value }
        let stub = Self.lock.withLock { query["key"].flatMap { Self.stubs[$0]?.stub } }
        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, data) = stub.answer(StubRequest(
            endpoint: url.lastPathComponent,
            query: query,
            authorization: request.value(forHTTPHeaderField: "Authorization")
        ))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Canned answers, in the API's own shapes

enum Fixture {
    static func json(_ object: Any) -> (Int, Data) {
        (200, try! JSONSerialization.data(withJSONObject: object))
    }

    static func error(status: Int, message: String, reason: String? = nil) -> (Int, Data) {
        var error: [String: Any] = ["code": status, "message": message]
        if let reason { error["errors"] = [["reason": reason, "message": message]] }
        return (status, try! JSONSerialization.data(withJSONObject: ["error": error]))
    }

    private static func page(_ items: [Any], next: String?) -> (Int, Data) {
        var body: [String: Any] = ["items": items]
        if let next { body["nextPageToken"] = next }
        return json(body)
    }

    static func playlistItems(_ ids: [String], next: String?) -> (Int, Data) {
        page(ids.map { id in
            [
                "id": "item-\(id)",
                "snippet": [
                    "title": "Video \(id)",
                    "publishedAt": "2025-03-01T12:00:00Z",
                    "videoOwnerChannelId": "UC1",
                    "videoOwnerChannelTitle": "Channel",
                    "thumbnails": ["high": ["url": "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"]],
                    "resourceId": ["kind": "youtube#video", "videoId": id],
                ],
                "contentDetails": ["videoId": id],
            ]
        }, next: next)
    }

    static func videos(_ ids: [String]) -> (Int, Data) {
        page(ids.map { id in
            [
                "id": id,
                "snippet": [
                    "title": "Video \(id)",
                    "channelId": "UC1",
                    "channelTitle": "Channel",
                    "publishedAt": "2025-03-01T12:00:00Z",
                    "thumbnails": ["maxres": ["url": "https://i.ytimg.com/vi/\(id)/maxresdefault.jpg"]],
                ],
                "statistics": ["viewCount": "1234", "likeCount": "56"],
                "contentDetails": ["duration": "PT10M35S"],
            ]
        }, next: nil)
    }

    static func search(videos: [String], channels: [String], next: String?) -> (Int, Data) {
        let videoItems: [Any] = videos.map { id in
            ["id": ["kind": "youtube#video", "videoId": id], "snippet": ["title": "Video \(id)", "channelId": "UC1", "channelTitle": "Channel"]]
        }
        let channelItems: [Any] = channels.map { id in
            ["id": ["kind": "youtube#channel", "channelId": id], "snippet": ["title": "Channel \(id)"]]
        }
        return page(videoItems + channelItems, next: next)
    }

    static func playlists(_ ids: [String], next: String?) -> (Int, Data) {
        page(ids.map { id in
            [
                "id": id,
                "snippet": ["title": "Playlist \(id)", "channelTitle": "Channel"],
                "contentDetails": ["itemCount": 12],
            ]
        }, next: next)
    }
}
