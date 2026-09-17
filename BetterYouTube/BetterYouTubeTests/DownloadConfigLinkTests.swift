import Foundation
import Testing
@testable import BetterYouTube

/// A setup link is something anyone can send you, so what it refuses matters more than what it
/// accepts.
struct DownloadConfigLinkTests {
    @Test("a well-formed link is read")
    func reads() throws {
        let url = try #require(URL(string: "betteryoutube://downloads?endpoint=https://box.example/yt&token=s3cret"))
        let link = try #require(DownloadConfigLink(url: url))
        #expect(link.endpoint == "https://box.example/yt")
        #expect(link.token == "s3cret")
        #expect(link.displayHost == "box.example")
        #expect(link.isInsecure == false)
    }

    /// The characters that would otherwise end the value or the query: a token carrying an `&`
    /// used to be written literally and read back as two query items, so the other person got
    /// half a token and no sign that anything was wrong.
    @Test("a link round-trips, whatever the token holds")
    func roundTrip() throws {
        for token in ["s3cret", "a&b", "a=b", "a b", "a+b", "a#b?c", "{}/:@"] {
            let original = DownloadConfigLink(endpoint: "https://box.example/yt/{id}.mp4", token: token)
            let url = try #require(original.url, "should build a URL for token \(token)")
            #expect(DownloadConfigLink(url: url) == original, "round trip failed for token \(token)")
        }
    }

    @Test("plain http is accepted but says so")
    func insecure() throws {
        let url = try #require(URL(string: "betteryoutube://downloads?endpoint=http://box.local:8080"))
        let link = try #require(DownloadConfigLink(url: url))
        #expect(link.isInsecure)
        #expect(link.displayHost == "box.local")
    }

    @Test("the token is optional")
    func tokenOptional() throws {
        let url = try #require(URL(string: "betteryoutube://downloads?endpoint=https://box.example"))
        let link = try #require(DownloadConfigLink(url: url))
        #expect(link.token.isEmpty)
        // And is left out of the URL it builds rather than written as empty.
        #expect(link.url?.absoluteString.contains("token") == false)
    }

    @Test("what a link cannot configure")
    func refusals() throws {
        let refused = [
            // Not this app's scheme.
            "https://downloads?endpoint=https://box.example",
            // Not this app's host, so not a downloads link.
            "betteryoutube://settings?endpoint=https://box.example",
            // No endpoint at all.
            "betteryoutube://downloads?token=s3cret",
            // A scheme the app must never fetch: file:// would have it read its own container.
            "betteryoutube://downloads?endpoint=file:///etc/passwd",
            // Not an address.
            "betteryoutube://downloads?endpoint=not%20a%20url",
            // A scheme with no host behind it.
            "betteryoutube://downloads?endpoint=https://"
        ]
        for text in refused {
            let url = try #require(URL(string: text), "fixture should be a URL: \(text)")
            #expect(DownloadConfigLink(url: url) == nil, "should have been refused: \(text)")
        }
    }

    @Test("surrounding whitespace is trimmed off both fields")
    func trims() {
        let link = DownloadConfigLink(endpoint: "  https://box.example  ", token: " s3cret\n")
        #expect(link.endpoint == "https://box.example")
        #expect(link.token == "s3cret")
    }
}
