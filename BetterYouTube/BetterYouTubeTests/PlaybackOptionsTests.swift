import Foundation
import Testing
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
