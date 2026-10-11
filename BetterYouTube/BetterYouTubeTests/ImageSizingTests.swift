import Foundation
import Testing
@testable import BetterYouTube

struct ImageSizingTests {
    private let maxres = URL(string: "https://i.ytimg.com/vi/aqz-KE-bpKQ/maxresdefault.jpg")!

    @Test("a small frame asks for the smallest 16:9 size that is still sharp")
    func smallVideoFrames() {
        #expect(ImageSizing.video(maxres, pixelWidth: 240)?.absoluteString == "https://i.ytimg.com/vi/aqz-KE-bpKQ/mqdefault.jpg")
        #expect(ImageSizing.video(maxres, pixelWidth: 320)?.absoluteString == "https://i.ytimg.com/vi/aqz-KE-bpKQ/mqdefault.jpg")
        #expect(ImageSizing.video(maxres, pixelWidth: 400)?.absoluteString == "https://i.ytimg.com/vi/aqz-KE-bpKQ/hqdefault.jpg")
    }

    @Test("a large frame keeps the large picture")
    func largeVideoFrames() {
        #expect(ImageSizing.video(maxres, pixelWidth: 1100) == maxres)
        #expect(ImageSizing.video(maxres, pixelWidth: 481) == maxres)
    }

    @Test("a picture is never swapped for a larger one")
    func neverLarger() {
        let medium = URL(string: "https://i.ytimg.com/vi/aqz-KE-bpKQ/mqdefault.jpg")!
        #expect(ImageSizing.video(medium, pixelWidth: 400) == medium)
        let tiny = URL(string: "https://i.ytimg.com/vi/aqz-KE-bpKQ/default.jpg")!
        #expect(ImageSizing.video(tiny, pixelWidth: 100) == tiny)
    }

    @Test("a signed web thumbnail becomes the plain fixed size")
    func signedWebThumbnail() {
        let signed = URL(string: "https://i.ytimg.com/vi/aqz-KE-bpKQ/hq720.jpg?sqp=-oaymwEcCNAFEJQDSFXyq4qpAw4IARUAAIhCGAFwAcABBg==&rs=AOn4CLC")!
        #expect(ImageSizing.video(signed, pixelWidth: 300)?.absoluteString == "https://i.ytimg.com/vi/aqz-KE-bpKQ/mqdefault.jpg")
    }

    @Test("anything else is left alone")
    func unknownURLs() {
        let other = URL(string: "https://example.com/vi/abc/maxresdefault.jpg")!
        #expect(ImageSizing.video(other, pixelWidth: 100) == other)
        let poster = URL(string: "https://i.ytimg.com/an_webp/abc/mqdefault_6s.webp")!
        #expect(ImageSizing.video(poster, pixelWidth: 100) == poster)
        #expect(ImageSizing.video(nil, pixelWidth: 100) == nil)
        #expect(ImageSizing.video(maxres, pixelWidth: 0) == maxres)
    }

    @Test("an avatar is asked for at the size it is drawn")
    func avatars() {
        let avatar = URL(string: "https://yt3.ggpht.com/ytc/AIdro_abc=s800-c-k-c0x00ffffff-no-rj")!
        #expect(ImageSizing.avatar(avatar, pixelSize: 108)?.absoluteString == "https://yt3.ggpht.com/ytc/AIdro_abc=s108-c-k-c0x00ffffff-no-rj")
        #expect(ImageSizing.avatar(avatar, pixelSize: 1000) == avatar)
        let unsized = URL(string: "https://yt3.ggpht.com/ytc/AIdro_abc")!
        #expect(ImageSizing.avatar(unsized, pixelSize: 108) == unsized)
    }
}
