import Foundation
import Testing
import WebKit
@testable import BetterYouTube

@MainActor
struct YouTubeWebPlaylistTests {
    private let id = "abcdefghijk"

    private func row(_ id: String, setID: String) -> [String: Any] {
        ["playlistVideoRenderer": [
            "videoId": id, "setVideoId": setID, "title": ["simpleText": "Title " + id],
            "shortBylineText": ["runs": [["text": "Channel"]]]
        ]]
    }

    private func page(_ rows: [[String: Any]]) -> [String: Any] {
        ["contents": ["playlistVideoListRenderer": ["contents": rows]]]
    }

    private func reply(_ endpoint: String, _ body: [String: Any], _ response: [String: Any]) -> [String: Any] {
        ["endpoint": endpoint, "body": body, "response": response]
    }

    private func run(_ operation: String, replies: [[String: Any]]) async throws -> [PlaylistEntry] {
        let web = WKWebView()
        web.loadHTMLString("<html><body id='ready'></body></html>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.body?.id")) as? String == "ready" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let harness = """
        const canonical = value => Array.isArray(value) ? value.map(canonical)
            : value && typeof value === 'object'
                ? Object.fromEntries(Object.keys(value).sort().map(k => [k, canonical(value[k])])) : value;
        const request = async (endpoint, body) => {
            const next = replies.shift();
            if (!next || next.endpoint !== endpoint || JSON.stringify(canonical(next.body)) !== JSON.stringify(canonical(body)))
                throw new Error('Unexpected request: ' + endpoint);
            return next.response;
        };
        """
        let result = try await web.callAsyncJavaScript(harness + YouTubeWebPlaylistService.operationsScript,
            arguments: ["replies": replies, "operation": operation, "videoID": id, "playlistID": "WL"],
            in: nil, contentWorld: .page)
        let string = try #require(result as? String)
        return try JSONDecoder().decode([PlaylistEntry].self, from: Data(string.utf8))
    }

    private func runLibrary(replies: [[String: Any]]) async throws -> [Playlist] {
        let web = WKWebView()
        web.loadHTMLString("<html><body id='ready'></body></html>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.body?.id")) as? String == "ready" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let harness = """
        const canonical = value => Array.isArray(value) ? value.map(canonical)
            : value && typeof value === 'object'
                ? Object.fromEntries(Object.keys(value).sort().map(k => [k, canonical(value[k])])) : value;
        const request = async (endpoint, body) => {
            const next = replies.shift();
            if (!next || next.endpoint !== endpoint || JSON.stringify(canonical(next.body)) !== JSON.stringify(canonical(body)))
                throw new Error('Unexpected request: ' + endpoint);
            return next.response;
        };
        """
        let result = try await web.callAsyncJavaScript(
            harness + YouTubeWebPlaylistService.playlistAggregationScript,
            arguments: ["replies": replies], in: nil, contentWorld: .page
        )
        let string = try #require(result as? String)
        return try JSONDecoder().decode([Playlist].self, from: Data(string.utf8))
    }

    @Test("Playlist aggregation includes saved, system and modern lockup playlists")
    func allPlaylists() async throws {
        let continuation: [String: Any] = ["continuationItemRenderer": [
            "continuationEndpoint": ["continuationCommand": ["token": "page2"]]]]
        let first: [String: Any] = ["contents": [
            "gridPlaylistRenderer": [
                "playlistId": "PLsaved", "title": ["simpleText": "Saved"],
                "videoCountText": ["simpleText": "12 videos"],
                "thumbnail": ["thumbnails": [["url": "https://example.com/saved.jpg"]]]],
            "playlistRenderer": ["playlistId": "WL", "title": ["simpleText": "Watch later"]],
            "continuation": continuation
        ]]
        let lockup: [String: Any] = [
            "contentId": "RDmix", "contentType": "LOCKUP_CONTENT_TYPE_PLAYLIST",
            "metadata": ["lockupMetadataViewModel": ["title": ["content": "My mix"]]],
            "contentImage": ["collectionThumbnailViewModel": ["primaryThumbnail": [
                "thumbnailViewModel": ["image": ["sources": [["url": "https://example.com/mix.jpg"]]]]
            ]]]
        ]
        let second: [String: Any] = [
            "onResponseReceivedActions": [[
                "appendContinuationItemsAction": [
                    "continuationItems": [["lockupViewModel": lockup]]
                ]
            ]]
        ]
        let playlists = try await runLibrary(replies: [
            reply("browse", ["browseId": "FEplaylist_aggregation"], first),
            reply("browse", ["continuation": "page2"], second)
        ])
        #expect(Set(playlists.map(\.id)) == ["PLsaved", "WL", "RDmix"])
        #expect(playlists.first(where: { $0.id == "PLsaved" })?.itemCount == 12)
        #expect(playlists.first(where: { $0.id == "RDmix" })?.thumbnailURL?.absoluteString
            == "https://example.com/mix.jpg")
    }

    @Test("Watch Later reads every continuation and preserves playlist item IDs")
    func pagination() async throws {
        let continuation: [String: Any] = ["continuationItemRenderer": [
            "continuationEndpoint": ["continuationCommand": ["token": "page2"]]]]
        let entries = try await run("list", replies: [
            reply("browse", ["browseId": "VLWL"], page([row(id, setID: "one"), continuation])),
            reply("browse", ["continuation": "page2"],
                  ["onResponseReceivedActions": [["appendContinuationItemsAction":
                    ["continuationItems": [row("12345678901", setID: "two")]]]]])
        ])
        #expect(entries.map(\.id) == ["one", "two"])
        #expect(entries.map(\.video.id) == [id, "12345678901"])
        #expect(entries.first?.video.title == "Title " + id)
    }

    @Test("Saving an existing video is idempotent and never sends another write")
    func duplicateSave() async throws {
        let entries = try await run("add", replies: [
            reply("browse", ["browseId": "VLWL"], page([row(id, setID: "one")]))
        ])
        #expect(entries.count == 1)
    }

    @Test("A save is successful only after YouTube confirms it in the actual WL playlist")
    func confirmedSave() async throws {
        let entries = try await run("add", replies: [
            reply("browse", ["browseId": "VLWL"], page([])),
            reply("browse/edit_playlist", ["playlistId": "WL",
                "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": id]]],
                ["status": "STATUS_SUCCEEDED"]),
            reply("browse", ["browseId": "VLWL"], page([row(id, setID: "new")]))
        ])
        #expect(entries.first?.id == "new")
    }

    @Test("Removing a video uses all its setVideoIds, never its video ID")
    func removeDuplicates() async throws {
        let entries = try await run("remove", replies: [
            reply("browse", ["browseId": "VLWL"], page([row(id, setID: "one"), row(id, setID: "two")])),
            reply("browse/edit_playlist", ["playlistId": "WL", "actions": [
                ["action": "ACTION_REMOVE_VIDEO", "setVideoId": "one"],
                ["action": "ACTION_REMOVE_VIDEO", "setVideoId": "two"]]],
                ["status": "STATUS_SUCCEEDED"]),
            reply("browse", ["browseId": "VLWL"], page([]))
        ])
        #expect(entries.isEmpty)
    }

    @Test("Changed markup must not be mistaken for an empty playlist")
    func unrecognizedPlaylist() async {
        await #expect(throws: (any Error).self) {
            try await run("list", replies: [reply("browse", ["browseId": "VLWL"], ["contents": [:]])])
        }
    }

    @Test("An HTTP-successful but rejected edit must be reported as a failure")
    func rejectedEdit() async {
        await #expect(throws: (any Error).self) {
            try await run("add", replies: [
                reply("browse", ["browseId": "VLWL"], page([])),
                reply("browse/edit_playlist", ["playlistId": "WL",
                    "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": id]]],
                    ["status": "STATUS_FAILED"])
            ])
        }
    }

    @Test("Accepted edits that do not appear on reread are not shown as successful")
    func unconfirmedEdit() async {
        await #expect(throws: (any Error).self) {
            try await run("add", replies: [
                reply("browse", ["browseId": "VLWL"], page([])),
                reply("browse/edit_playlist", ["playlistId": "WL",
                    "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": id]]],
                    ["status": "STATUS_SUCCEEDED"]),
                reply("browse", ["browseId": "VLWL"], page([]))
            ])
        }
    }
}
