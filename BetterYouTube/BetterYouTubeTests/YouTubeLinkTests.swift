import Foundation
import Testing
@testable import BetterYouTube

struct YouTubeLinkTests {
    private let id = "dQw4w9WgXcQ"

    @Test("every shape of video link names the video")
    func videoLinks() {
        let links = [
            "https://www.youtube.com/watch?v=\(id)",
            "https://m.youtube.com/watch?v=\(id)&feature=share",
            "https://music.youtube.com/watch?v=\(id)&list=RDAMVM\(id)",
            "http://youtube.com/watch?app=desktop&v=\(id)",
            "https://youtu.be/\(id)",
            "https://youtu.be/\(id)?si=AbCdEf",
            "https://www.youtube.com/shorts/\(id)",
            "https://www.youtube.com/live/\(id)?feature=shared",
            "https://www.youtube.com/embed/\(id)",
            "https://www.youtube-nocookie.com/embed/\(id)",
            "youtu.be/\(id)",
            "www.youtube.com/watch?v=\(id)",
            "  https://youtu.be/\(id)\n"
        ]
        for link in links {
            #expect(YouTubeLink(string: link) == .video(id: id, start: nil), "\(link)")
        }
    }

    @Test("a shared time is kept, in every way YouTube writes one")
    func startTimes() {
        #expect(YouTubeLink(string: "https://youtu.be/\(id)?t=90") == .video(id: id, start: 90))
        #expect(YouTubeLink(string: "https://youtu.be/\(id)?t=90s") == .video(id: id, start: 90))
        #expect(YouTubeLink(string: "https://www.youtube.com/watch?v=\(id)&t=1m30s") == .video(id: id, start: 90))
        #expect(YouTubeLink(string: "https://www.youtube.com/watch?v=\(id)&t=1h2m3s") == .video(id: id, start: 3723))
        #expect(YouTubeLink(string: "https://www.youtube.com/embed/\(id)?start=42") == .video(id: id, start: 42))
        #expect(YouTubeLink(string: "https://www.youtube.com/watch?v=\(id)#t=2m") == .video(id: id, start: 120))
        #expect(YouTubeLink(string: "https://youtu.be/\(id)?t=0") == .video(id: id, start: nil))
        #expect(YouTubeLink(string: "https://youtu.be/\(id)?t=soon") == .video(id: id, start: nil))
    }

    @Test("playlists, channels and handles")
    func otherDestinations() {
        #expect(YouTubeLink(string: "https://www.youtube.com/playlist?list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf")
            == .playlist(id: "PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf"))
        #expect(YouTubeLink(string: "https://www.youtube.com/channel/UCBR8-60-B28hp2BmDPdntcQ")
            == .channel(id: "UCBR8-60-B28hp2BmDPdntcQ"))
        #expect(YouTubeLink(string: "https://www.youtube.com/@YouTube") == .handle("@YouTube"))
        #expect(YouTubeLink(string: "https://www.youtube.com/@YouTube/videos") == .handle("@YouTube"))
        #expect(YouTubeLink(string: "@mkbhd") == .handle("@mkbhd"))
    }

    @Test("the app's own scheme opens links from Shortcuts and other apps")
    func appScheme() {
        #expect(YouTubeLink(string: "betteryoutube://watch?v=\(id)&t=30") == .video(id: id, start: 30))
        #expect(YouTubeLink(string: "betteryoutube://www.youtube.com/watch?v=\(id)") == .video(id: id, start: nil))
        let wrapped = "https://youtu.be/\(id)?t=15".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(YouTubeLink(string: "betteryoutube://open?url=\(wrapped)") == .video(id: id, start: 15))
        // The setup link shares the scheme and must stay the download configuration's.
        #expect(YouTubeLink(string: "betteryoutube://downloads?endpoint=https://box.local") == nil)
    }

    @Test("ordinary searches are left to search")
    func searchesAreNotLinks() {
        for query in ["lofi hip hop", "programming", "dQw4w9WgXcQ", "youtube.com", "https://example.com/watch?v=\(id)",
                      "https://www.youtube.com/watch?v=short", "https://www.youtube.com/feed/subscriptions", "@", "@a"] {
            #expect(YouTubeLink(string: query) == nil, "\(query)")
        }
    }

    @Test("links hand on as the YouTube app shares them")
    func webURLs() {
        #expect(YouTubeLink.video(id: id, start: 75.4).webURL?.absoluteString == "https://youtu.be/\(id)?t=75")
        #expect(YouTubeLink.video(id: id, start: nil).webURL?.absoluteString == "https://youtu.be/\(id)")
    }
}
