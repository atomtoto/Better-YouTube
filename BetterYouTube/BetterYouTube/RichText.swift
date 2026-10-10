import Foundation

/// Descriptions and comments with their timestamps and web links made tappable, the way YouTube
/// shows them.
///
/// A timestamp — `2:35`, `1:02:03` — becomes a link the player answers by seeking, which is how
/// chapters and "skip to the good part" comments work everywhere else. A web link stays a web
/// link; one that points at YouTube is caught by the screen and opened in the app, so following
/// a video's "watch part one first" doesn't leave for Safari.
enum RichText {
    /// A link no browser will ever see: the details screen intercepts it and seeks.
    static let seekHost = "seek"

    /// The URL a timestamp carries: `betteryoutube://seek?t=155`.
    static func seekURL(seconds: Int) -> URL? {
        URL(string: "\(YouTubeLink.appScheme)://\(seekHost)?t=\(seconds)")
    }

    /// The moment a timestamp link names, or nil for any other URL.
    static func seekTime(in url: URL) -> TimeInterval? {
        guard url.scheme?.lowercased() == YouTubeLink.appScheme,
              url.host?.lowercased() == seekHost,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "t" })?.value,
              let seconds = Int(value), seconds >= 0 else { return nil }
        return TimeInterval(seconds)
    }

    struct Link: Equatable {
        let range: Range<String.Index>
        let url: URL
    }

    /// Every web link and timestamp in the text, in reading order. A timestamp inside a link —
    /// a port number, a time in a URL — belongs to the link.
    static func links(in text: String) -> [Link] {
        let fullRange = NSRange(text.startIndex..., in: text)
        var links: [Link] = []

        for match in linkDetector?.matches(in: text, range: fullRange) ?? [] {
            guard let url = match.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let range = Range(match.range, in: text) else { continue }
            links.append(Link(range: range, url: url))
        }

        for match in timestampPattern.matches(in: text, range: fullRange) {
            guard let range = Range(match.range, in: text),
                  !links.contains(where: { $0.range.overlaps(range) }),
                  let seconds = seconds(in: text[range]),
                  let url = seekURL(seconds: seconds) else { continue }
            links.append(Link(range: range, url: url))
        }

        return links.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Seconds in `m:ss`, `mm:ss` or `h:mm:ss`. Minutes past 59 are only read as minutes when
    /// there is no hour in front of them, the way YouTube reads `75:00`.
    static func seconds<S: StringProtocol>(in timestamp: S) -> Int? {
        let fields = timestamp.split(separator: ":", omittingEmptySubsequences: false)
        let parts = fields.compactMap { Int($0) }
        guard parts.count == fields.count, (2...3).contains(parts.count),
              parts.allSatisfy({ $0 >= 0 }), parts.last! < 60 else { return nil }
        if parts.count == 3, parts[1] >= 60 { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// The text ready for `Text`, with its links attached. Kept for the screen's lifetime:
    /// a details screen redraws whenever the player changes state, and detecting links in a
    /// long description on every one of those would be wasted work.
    @MainActor
    static func attributed(_ text: String) -> AttributedString {
        if let cached = cache[text] { return cached }
        var result = AttributedString(text)
        for link in links(in: text) {
            guard let lower = AttributedString.Index(link.range.lowerBound, within: result),
                  let upper = AttributedString.Index(link.range.upperBound, within: result) else { continue }
            result[lower..<upper].link = link.url
        }
        if cache.count >= 300 { cache.removeAll() }
        cache[text] = result
        return result
    }

    @MainActor private static var cache: [String: AttributedString] = [:]

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"(?<![\w:.])(?:\d{1,2}:)?\d{1,3}:\d{2}(?![\w:])"#
    )
}
