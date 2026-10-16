import Foundation
import Testing
#if os(iOS)
import UIKit
#endif
@testable import BetterYouTube

@MainActor
struct PlaybackOptionsTests {
    @Test("A description's timestamp list becomes chapters")
    func descriptionChapters() {
        let description = """
        Microplastics are accumulating in human brains.
        https://www.youtube.com/watch?v=0PT5c1z3LL8

        00:00 Intro
        0:05 - The cool thing
        [1:02:17] Ending: the end
        """
        let chapters = DescriptionChapters.parse(description)
        #expect(chapters.map(\.title) == ["Intro", "The cool thing", "Ending: the end"])
        #expect(chapters.map(\.start) == [0, 5, 3737])
    }

    @Test("Lists that don't start at 0:00, are too short or go backwards aren't chapters")
    func notChapters() {
        #expect(DescriptionChapters.parse("1:00 One\n2:00 Two\n3:00 Three").isEmpty)
        #expect(DescriptionChapters.parse("0:00 One\n2:00 Two").isEmpty)
        // A second list further down ends the first one rather than joining it.
        let chapters = DescriptionChapters.parse("0:00 A\n1:00 B\n2:00 C\n\nTracklist\n0:30 Song")
        #expect(chapters.map(\.title) == ["A", "B", "C"])
        // A timestamp inside a sentence is a link, not a chapter.
        #expect(DescriptionChapters.parse("See 0:00 here\nand 1:00 there\nor 2:00 after").isEmpty)
    }

    @Test("The embed's report fills the menus, and an ad or the end lets YouTube's layer through")
    func embedReport() throws {
        let json = """
        {"qualities":[{"id":"hd1080","title":"1080p"},{"id":"hd720","title":"720p"}],
         "quality":"auto","qualityLabel":"720p",
         "captions":[{"id":".en","title":"English"},{"id":"a.fr","title":"French (auto-generated)"}],
         "caption":".en","translation":"it","translations":[{"id":"it","title":"Italian"}],
         "audioTracks":[{"id":"en-US.4","title":"English original"},{"id":"fr.3","title":"French"}],
         "audioTrack":"fr.3","rates":[0.5,1,2],"rate":1.5,
         "chapters":[{"title":"Intro","start":0},{"title":"Red Light","start":61.5}],
         "ad":false,"ended":false}
        """
        let report = try JSONDecoder().decode(EmbedOptionsReport.self, from: Data(json.utf8))
        let options = PlaybackOptions()
        options.apply(report)
        #expect(options.qualities.map(\.title) == ["1080p", "720p"])
        #expect(options.quality == PlaybackOptions.automaticQuality)
        #expect(options.playingQualityLabel == "720p")
        #expect(options.caption == ".en")
        #expect(options.translation == "it")
        #expect(options.audioTrack == "fr.3")
        #expect(options.rate == 1.5)
        #expect(options.chapter(at: 90)?.title == "Red Light")
        #expect(options.chapter(at: 10)?.title == "Intro")
        #expect(!options.showsYouTubeLayer)

        let ad = try JSONDecoder().decode(EmbedOptionsReport.self, from: Data(#"{"ad":true}"#.utf8))
        options.apply(ad)
        #expect(options.showsYouTubeLayer)
        // A report without chapters keeps the ones already known, from the description.
        #expect(options.chapters.count == 2)
    }

    @Test("Holding to speed up doesn't let the embed's reported speed replace the chosen one")
    func speedingUpKeepsChosenRate() throws {
        let options = PlaybackOptions()
        options.reset(rate: 1.25)
        options.setSpeedingUp(true)
        let report = try JSONDecoder().decode(EmbedOptionsReport.self, from: Data(#"{"rate":2}"#.utf8))
        options.apply(report)
        #expect(options.rate == 1.25)
        options.setSpeedingUp(false)
        #expect(options.rate == 1.25)
    }
}

#if os(iOS)
@Suite(.serialized)
@MainActor
struct BackgroundPlaybackTests {
    @Test("Leaving the app moves a streamed video's sound to the native player, and returning gives it back to the embed")
    func handoffAndReturn() async throws {
        UserDefaults.standard.removeObject(forKey: BackgroundPlaybackPreference.storageKey)
        let audio = try audioFixture()
        let player = PlayerManager(resolveAudio: { _ in audio }, downloadedMediaURL: { _ in nil })
        defer {
            NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
            player.close()
        }
        player.play(video())
        // The embed would report itself playing; there is no web view here to do it.
        player.resume()
        #expect(player.source == .embed)

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await waitUntil { player.source == .local(audio) }
        #expect(player.isPlaying)

        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(player.source == .embed)
        #expect(player.isPlaying)
    }

    @Test("With Background Playback off, leaving the app pauses instead")
    func pausesWhenTurnedOff() {
        UserDefaults.standard.set(false, forKey: BackgroundPlaybackPreference.storageKey)
        let player = PlayerManager(resolveAudio: { _ in
            Issue.record("Nothing should be resolved for the background when it is off")
            throw CancellationError()
        }, downloadedMediaURL: { _ in nil })
        defer {
            NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
            UserDefaults.standard.removeObject(forKey: BackgroundPlaybackPreference.storageKey)
            player.close()
        }
        player.play(video())
        player.resume()

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(!player.isPlaying)
        #expect(player.source == .embed)
    }

    private func audioFixture() throws -> URL {
        try #require(Bundle(for: BackgroundFixtureMarker.self)
            .url(forResource: "audio", withExtension: "m4a", subdirectory: "Fixtures"))
    }

    private func video() -> Video {
        Video(id: "background-test-\(UUID().uuidString)", title: "Video", channelId: "channel",
              channelTitle: "Channel", description: "", thumbnailURL: nil, publishedAt: nil)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out")
    }
}

private final class BackgroundFixtureMarker: NSObject {}
#endif
