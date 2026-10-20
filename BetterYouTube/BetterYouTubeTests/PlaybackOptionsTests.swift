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

    @Test("The player chosen in Settings applies as far as it can")
    func chosenControls() {
        // YouTube's controls can't play a downloaded file, which keeps the app's.
        #expect(PlayerManager.controls(chosen: .youTube, isFullScreen: false, isLocal: false) == .youTube)
        #expect(PlayerManager.controls(chosen: .youTube, isFullScreen: false, isLocal: true) == .app)
        #if os(iOS)
        // Full screen is the Full-Screen Player's to decide.
        #expect(PlayerManager.controls(chosen: .youTube, isFullScreen: true, isLocal: false) == .app)
        #else
        // A Mac keeps the choice full screen too, and macOS's player takes downloads as well.
        #expect(PlayerManager.controls(chosen: .youTube, isFullScreen: true, isLocal: false) == .youTube)
        #expect(PlayerManager.controls(chosen: .system, isFullScreen: true, isLocal: true) == .system)
        #endif
    }

    @Test("A player this platform doesn't have falls back to the app's")
    func unavailableControls() {
        let key = PlayerControlsPreference.storageKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(PlayerControlsPreference.stored == .app)
        UserDefaults.standard.set(PlayerControlsPreference.system.rawValue, forKey: key)
        #if os(iOS)
        #expect(PlayerControlsPreference.stored == .app)
        #else
        #expect(PlayerControlsPreference.stored == .system)
        #endif
    }
}

struct StreamIndexTests {
    private let url = URL(string: "https://example.com/videoplayback?itag=140")!

    /// A header, then an index of two pieces: 5 s in 100 bytes, then 4.5 s in 200.
    private var stream: [UInt8] {
        func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
            be(UInt64(8 + body.count), 4) + Array(type.utf8) + body
        }
        func be(_ value: UInt64, _ count: Int) -> [UInt8] {
            (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64(count - 1 - $0))) }
        }
        let sidx = box("sidx", [0, 0, 0, 0] + be(1, 4) + be(1000, 4) + be(0, 4) + be(0, 4) + be(0, 2) + be(2, 2)
            + be(100, 4) + be(5000, 4) + be(0x9000_0000, 4)
            + be(200, 4) + be(4500, 4) + be(0x9000_0000, 4))
        return box("ftyp", Array(repeating: 0, count: 8)) + box("moov", Array(repeating: 0, count: 8)) + sidx
    }

    @Test("A stream's index gives where each of its pieces lies")
    func readsIndex() throws {
        guard case .index(let index) = StreamIndex.parse(Data(stream), url: url) else {
            Issue.record("No index read")
            return
        }
        #expect(index.headerLength == 32)
        // The pieces start right after the index, which ends at byte 88.
        #expect(index.segments == [
            StreamIndex.Segment(offset: 88, length: 100, duration: 5),
            StreamIndex.Segment(offset: 188, length: 200, duration: 4.5),
        ])
        let playlist = index.playlist
        #expect(playlist.contains("#EXT-X-TARGETDURATION:5\n"))
        #expect(playlist.contains("#EXT-X-MAP:URI=\"\(url.absoluteString)\",BYTERANGE=\"32@0\""))
        #expect(playlist.contains("#EXTINF:4.500,\n#EXT-X-BYTERANGE:200@188\n\(url.absoluteString)\n"))
        #expect(playlist.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    @Test("An index running past what was read asks for more, and a stream without one has none")
    func incompleteOrMissingIndex() {
        #expect(StreamIndex.parse(Data(stream.prefix(60)), url: url) == .needs(88))
        let noIndex: [UInt8] = [0, 0, 0, 8] + Array("moof".utf8)
        #expect(StreamIndex.parse(Data(noIndex), url: url) == .invalid)
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
        // The native player carries the sound until the embed plays again; a pause ends that.
        #expect(player.local.player.currentItem != nil)
        player.pause()
        #expect(player.local.player.currentItem == nil)
    }

    @Test("A Picture in Picture window the lock closes hands the sound to the native player")
    func pictureInPictureClosedWhileAway() async throws {
        UserDefaults.standard.removeObject(forKey: BackgroundPlaybackPreference.storageKey)
        let audio = try audioFixture()
        let player = PlayerManager(resolveAudio: { _ in audio }, downloadedMediaURL: { _ in nil })
        defer {
            NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
            player.close()
        }
        player.play(video())
        player.resume()
        try await Task.sleep(for: .milliseconds(100))

        // In its window, the video goes on by itself.
        player.embedPictureInPictureDidChange(true)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(player.source == .embed)

        // The lock closes the window: the sound carries on alone.
        player.embedPictureInPictureDidChange(false)
        try await waitUntil { player.source == .local(audio) }
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
