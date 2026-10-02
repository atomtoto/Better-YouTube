import Foundation
import Testing
#if os(iOS)
import CarPlay
#endif
@testable import BetterYouTube

@Suite(.serialized)
@MainActor
struct CarPlayPlaybackTests {
    @Test("CarPlay starts downloaded audio without a phone surface or a network request")
    func downloadedAudioAndQueue() throws {
        let file = try audioFixture()
        let player = PlayerManager(resolveAudio: { _ in
            Issue.record("A downloaded item must not resolve a stream")
            throw CancellationError()
        }, downloadedMediaURL: { _ in file })
        defer { player.close() }
        let first = video(), second = video()
        player.setCarPlayConnected(true)
        player.play(first, upNext: [second])
        #expect(player.source == .local(file))
        #expect(player.isAudioOnly)
        #expect(!player.isExpanded)
        player.setLandscape(true)
        #expect(!player.isFullScreen)
        player.setCarPlayConnected(false)
        player.playNext()
        #expect(player.currentVideo?.id == second.id)
        #expect(player.isAudioOnly)
        #expect(player.source == .local(file))
        #expect(player.upNext.isEmpty)
        player.setLandscape(false)
        player.play(first)
        #expect(!player.isAudioOnly)
        #expect(player.isExpanded)
    }

    #if os(iOS)
    @Test("CarPlay implements the scene connection and disconnection callbacks")
    func sceneCallbacks() {
        let delegate = CarPlaySceneDelegate()
        #expect(delegate.responds(to: #selector(CPTemplateApplicationSceneDelegate.templateApplicationScene(_:didConnect:))))
        #expect(delegate.responds(to: #selector(CPTemplateApplicationSceneDelegate.templateApplicationScene(_:didDisconnectInterfaceController:))))
    }
    #endif

    @Test("A video-capable car uses downloaded video without opening phone fullscreen")
    func downloadedVideo() throws {
        let file = try #require(Bundle(for: CarPlayFixtureBundleMarker.self)
            .url(forResource: "video", withExtension: "mp4", subdirectory: "Fixtures"))
        let player = PlayerManager(resolveAudio: { _ in throw CancellationError() },
                                   resolveVideo: { _ in
            Issue.record("Downloaded video must play without resolving a stream")
            throw CancellationError()
        }, downloadedMediaURL: { _ in file })
        defer { player.close() }
        let first = video(), second = video()
        player.play(first, upNext: [second])
        player.pause()
        player.seek(to: 0.3)
        player.setCarPlayConnected(true, supportsVideo: true)
        #expect(player.isCarPlayVideoPlayback)
        #expect(!player.isAudioOnly)
        #expect(!player.isPlaying)
        #expect(!player.isExpanded)
        #expect(player.progress.currentTime == 0.3)
        #expect(player.upNext == [second])
        player.playNext()
        #expect(player.currentVideo?.id == second.id)
        #expect(player.source == .local(file))
        #expect(player.isCarPlayVideoPlayback)
        #expect(!player.isFullScreen)
    }

    @Test("Video streams use native playback and unavailable video falls back to audio")
    func videoStreamAndFallback() async throws {
        let resolver = PendingAudio()
        let file = try audioFixture()
        let player = PlayerManager(resolveAudio: { _ in file },
                                   resolveVideo: { try await resolver.resolve($0) },
                                   downloadedMediaURL: { _ in nil })
        defer { player.close() }
        player.setCarPlayConnected(true, supportsVideo: true)
        player.play(video(), upNext: [video()])
        try await waitUntil { resolver.requests.count == 1 }
        #expect(player.isCarPlayVideoPlayback)
        resolver.requests[0].resume(throwing: DownloadError.noMedia)
        try await waitUntil { player.source == .local(file) }
        #expect(player.isAudioOnly)
        #expect(!player.isCarPlayVideoPlayback)
        #expect(player.issue == nil)
        // A failed video stream must not force subsequent queue items into audio mode.
        player.playNext()
        try await waitUntil { resolver.requests.count == 2 }
        #expect(player.isCarPlayVideoPlayback)
        resolver.finish(at: 1, with: file)
        try await waitUntil { player.source == .local(file) }
        #expect(!player.isAudioOnly)
    }

    @Test("Pausing while audio resolves prevents autoplay and resume uses the same item")
    func pauseWhileResolving() async throws {
        let resolver = PendingAudio()
        let file = try audioFixture()
        let player = PlayerManager(resolveAudio: { try await resolver.resolve($0) }, downloadedMediaURL: { _ in nil })
        defer { player.close() }
        player.play(video(), audioOnly: true)
        try await waitUntil { resolver.requests.count == 1 }
        player.pause()
        resolver.finish(at: 0, with: file)
        try await waitUntil { player.source == .local(file) }
        #expect(!player.isPlaying)
        #expect(player.local.player.rate == 0)
        player.resume()
        #expect(player.isPlaying)
        #expect(resolver.requests.count == 1)
    }

    @Test("An obsolete audio resolution cannot replace a newer playback or reopen a closed player")
    func obsoleteResolution() async throws {
        let resolver = PendingAudio()
        let file = try audioFixture()
        let player = PlayerManager(resolveAudio: { try await resolver.resolve($0) }, downloadedMediaURL: { _ in nil })
        defer { player.close() }
        let repeated = video()
        player.play(repeated, audioOnly: true)
        try await waitUntil { resolver.requests.count == 1 }
        player.play(repeated, audioOnly: true)
        try await waitUntil { resolver.requests.count == 2 }
        resolver.finish(at: 0, with: file)
        await Task.yield()
        #expect(player.source == .embed)
        #expect(player.isBuffering)
        player.close()
        resolver.finish(at: 1, with: file)
        await Task.yield()
        #expect(player.currentVideo == nil)
        #expect(player.local.player.currentItem == nil)
    }

    @Test("Stream failures surface and the play command can retry")
    func failureAndRetry() async throws {
        let resolver = PendingAudio()
        let file = try audioFixture()
        let player = PlayerManager(resolveAudio: { try await resolver.resolve($0) }, downloadedMediaURL: { _ in nil })
        defer { player.close() }
        player.play(video(), audioOnly: true)
        try await waitUntil { resolver.requests.count == 1 }
        resolver.requests[0].resume(throwing: DownloadError.noMedia)
        try await waitUntil { player.issue != nil }
        #expect(!player.isBuffering)
        player.resume()
        try await waitUntil { resolver.requests.count == 2 }
        resolver.finish(at: 1, with: file)
        try await waitUntil { player.source == .local(file) }
        #expect(player.issue == nil)
    }

    private func audioFixture() throws -> URL {
        try #require(Bundle(for: CarPlayFixtureBundleMarker.self)
            .url(forResource: "audio", withExtension: "m4a", subdirectory: "Fixtures"))
    }

    private func video() -> Video {
        Video(id: "carplay-test-\(UUID().uuidString)", title: "Audio", channelId: "channel",
              channelTitle: "Artist", description: "", thumbnailURL: nil, publishedAt: nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TestTimeout()
    }

    private struct TestTimeout: Error {}
}

private final class CarPlayFixtureBundleMarker: NSObject {}

@MainActor
private final class PendingAudio {
    var requests: [CheckedContinuation<URL, Error>] = []

    func resolve(_ videoID: String) async throws -> URL {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }

    func finish(at index: Int, with url: URL) {
        requests[index].resume(returning: url)
    }
}
