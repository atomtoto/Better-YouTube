import Foundation
import Testing
import WebKit
@testable import BetterYouTube

@Suite(.serialized)
@MainActor
struct PlayerWebBridgeTests {
    @Test("WebKit events and navigation failures reach their owning player")
    func owningPlayer() async throws {
        let owner = PlayerManager(downloadedMediaURL: { _ in nil })
        let other = PlayerManager(downloadedMediaURL: { _ in nil })
        defer { owner.close(); other.close() }
        #expect(!owner.hasWebView)
        #expect(!other.hasWebView)
        let sharedIssue = PlayerManager.shared.issue
        let script = PlayerScriptBridge(owner: owner)
        owner.play(video())
        let playbackID = try #require(owner.playbackID)
        script.handleMessage(["type": "error", "state": 100,
                              "videoID": owner.currentVideo!.id, "playbackID": playbackID])
        try await waitUntil { owner.issue == .playerError(100) }
        #expect(other.issue == nil)
        #expect(PlayerManager.shared.issue == sharedIssue)
        #expect(!owner.hasWebView)

        let webView = owner.webView
        let navigation = try #require(webView.navigationDelegate as? PlayerNavigationBridge)
        let error = NSError(domain: "PlayerWebBridgeTests", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Fixture load failed"])
        navigation.webView(webView, didFailProvisionalNavigation: nil, withError: error)
        try await waitUntil { owner.issue == .loadFailed("Fixture load failed") }
        #expect(other.issue == nil)
        #expect(PlayerManager.shared.issue == sharedIssue)
    }

    @Test("Late events from an earlier playback of the same video are ignored")
    func reopenedVideo() async throws {
        let owner = PlayerManager(downloadedMediaURL: { _ in nil })
        defer { owner.close() }
        let script = PlayerScriptBridge(owner: owner)
        let video = video()
        owner.play(video)
        let previousID = try #require(owner.playbackID)
        owner.play(video)
        let currentID = try #require(owner.playbackID)
        #expect(previousID != currentID)
        script.handleMessage(["type": "error", "state": 100,
                              "videoID": video.id, "playbackID": previousID])
        script.handleMessage(["type": "time", "time": 99.0, "duration": 300.0,
                              "videoID": video.id, "playbackID": previousID])
        script.handleMessage(["type": "time", "time": 12.0, "duration": 300.0,
                              "videoID": video.id, "playbackID": currentID])
        try await waitUntil { owner.progress.currentTime == 12 }
        #expect(owner.issue == nil)
        #expect(owner.progress.duration == 300)
        #expect(!owner.hasWebView)
    }

    private func video() -> Video {
        Video(id: UUID().uuidString, title: "Fixture", channelId: "fixture", channelTitle: "Fixture",
              description: "", thumbnailURL: nil, publishedAt: nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
