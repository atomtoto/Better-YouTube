import Foundation
import Testing
@testable import BetterYouTube

struct RichTextTests {
    private func seekTimes(in text: String) -> [TimeInterval] {
        RichText.links(in: text).compactMap { RichText.seekTime(in: $0.url) }
    }

    @Test("chapter lists become seek links")
    func chapters() {
        let description = """
        0:00 Intro
        2:35 The good part
        1:02:03 Credits
        """
        #expect(seekTimes(in: description) == [0, 155, 3723])
    }

    @Test("times inside words, versions and URLs are left alone")
    func notTimestamps() {
        #expect(seekTimes(in: "Version 1.2:30 and 10:30pm and 3:7").isEmpty)
        #expect(seekTimes(in: "Clock reads 10:30:45:12 today").isEmpty)
        #expect(seekTimes(in: "Minutes 1:75:00 aren't real").isEmpty)
        // A port is part of the link, not a moment in the video.
        let links = RichText.links(in: "Server at https://box.local:8080/12:30 now")
        #expect(links.count == 1)
        #expect(links.first?.url.host == "box.local")
    }

    @Test("web links are kept as web links, in reading order")
    func webLinks() {
        let text = "Part one: https://youtu.be/dQw4w9WgXcQ — skip to 4:20, or see www.example.com"
        let links = RichText.links(in: text)
        #expect(links.count == 3)
        #expect(links[0].url.absoluteString == "https://youtu.be/dQw4w9WgXcQ")
        #expect(RichText.seekTime(in: links[1].url) == 260)
        #expect(links[2].url.host == "www.example.com")
    }

    @Test("seek links name their moment and nothing else does")
    func seekURLs() throws {
        let url = try #require(RichText.seekURL(seconds: 42))
        #expect(RichText.seekTime(in: url) == 42)
        #expect(RichText.seekTime(in: URL(string: "https://youtu.be/dQw4w9WgXcQ?t=42")!) == nil)
        #expect(RichText.seekTime(in: URL(string: "betteryoutube://downloads?endpoint=x")!) == nil)
    }

    @Test("long timestamps")
    func longForm() {
        #expect(RichText.seconds(in: "75:00") == 4500)
        #expect(RichText.seconds(in: "1:00:00") == 3600)
        #expect(RichText.seconds(in: "1:60") == nil)
        #expect(RichText.seconds(in: "1:") == nil)
    }

    @Test("attributed text carries the links")
    @MainActor
    func attributed() {
        let text = RichText.attributed("Jump to 1:30 now")
        let linked = text.runs.compactMap { run in run.link.map { (String(text[run.range].characters), $0) } }
        #expect(linked.count == 1)
        #expect(linked.first?.0 == "1:30")
        #expect(linked.first.flatMap { RichText.seekTime(in: $0.1) } == 90)
    }
}
