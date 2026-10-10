import Foundation

/// What a YouTube link points at, read the way the YouTube app reads a shared one.
///
/// Pasting a link into Search used to spend a 100-unit `search.list` looking for a video the
/// link already named. Opening it directly costs one unit — or nothing, for the player — and
/// lands on exactly the thing that was shared, at the moment it was shared from.
///
/// Every shape YouTube hands out is accepted: `watch?v=`, `youtu.be/`, Shorts, live, embeds,
/// playlists, channel IDs and @handles, on any of YouTube's hosts, with or without a scheme. So
/// is the app's own scheme in front of any of them — `betteryoutube://www.youtube.com/watch?v=…`
/// — as well as `betteryoutube://watch?v=…` and `betteryoutube://open?url=…`, which is what lets
/// Shortcuts or another app send a link here.
enum YouTubeLink: Equatable, Hashable {
    /// A video, and where to start it, in seconds, when the link carries a time.
    case video(id: String, start: TimeInterval?)
    case playlist(id: String)
    /// A channel by its permanent `UC…` ID.
    case channel(id: String)
    /// A channel by its `@handle`, which the Data API resolves with `forHandle`.
    case handle(String)

    static let appScheme = "betteryoutube"

    /// Reads text typed or pasted into a field. Surrounding whitespace is ignored, and a link
    /// without a scheme — `youtu.be/…`, `youtube.com/…` — is read as the https link it stands for.
    init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        // A bare @handle names a channel as plainly as its URL does, and nobody searches for one.
        if trimmed.hasPrefix("@") {
            guard Self.isHandle(trimmed) else { return nil }
            self = .handle(trimmed)
            return
        }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate) else { return nil }
        self.init(url: url)
    }

    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = (url.host ?? "").lowercased()

        if scheme == Self.appScheme {
            switch host {
            case "watch":
                // betteryoutube://watch?v=ID&t=90
                guard let id = components.queryValue("v"), Self.isVideoID(id) else { return nil }
                self = .video(id: id, start: Self.startTime(in: components))
                return
            case "open":
                // betteryoutube://open?url=https%3A%2F%2Fyoutu.be%2FID
                guard let inner = components.queryValue("url").flatMap(URL.init(string:)),
                      inner.scheme?.lowercased() != Self.appScheme else { return nil }
                self.init(url: inner)
                return
            default:
                // betteryoutube://www.youtube.com/watch?v=ID — any link with the scheme swapped.
                guard Self.isYouTubeHost(host) else { return nil }
            }
        } else {
            guard scheme == "https" || scheme == "http", Self.isYouTubeHost(host) else { return nil }
        }

        let segments = url.path.split(separator: "/").map(String.init)

        if host == "youtu.be" || host == "www.youtu.be" {
            guard let id = segments.first, Self.isVideoID(id) else { return nil }
            self = .video(id: id, start: Self.startTime(in: components))
            return
        }

        guard let first = segments.first else { return nil }
        switch first.lowercased() {
        case "watch":
            guard let id = components.queryValue("v"), Self.isVideoID(id) else { return nil }
            self = .video(id: id, start: Self.startTime(in: components))
        case "shorts", "live", "embed", "v", "e":
            guard segments.count > 1, Self.isVideoID(segments[1]) else { return nil }
            self = .video(id: segments[1], start: Self.startTime(in: components))
        case "playlist":
            guard let id = components.queryValue("list"), Self.isPlaylistID(id) else { return nil }
            self = .playlist(id: id)
        case "channel":
            guard segments.count > 1, Self.isChannelID(segments[1]) else { return nil }
            self = .channel(id: segments[1])
        default:
            guard first.hasPrefix("@"), Self.isHandle(first) else { return nil }
            self = .handle(first)
        }
    }

    /// The link the YouTube app would share for this, for handing on.
    var webURL: URL? {
        switch self {
        case .video(let id, let start):
            guard let start, start >= 1 else { return URL(string: "https://youtu.be/\(id)") }
            return URL(string: "https://youtu.be/\(id)?t=\(Int(start))")
        case .playlist(let id):
            return URL(string: "https://www.youtube.com/playlist?list=\(id)")
        case .channel(let id):
            return URL(string: "https://www.youtube.com/channel/\(id)")
        case .handle(let handle):
            return URL(string: "https://www.youtube.com/\(handle)")
        }
    }

    // MARK: - Reading the pieces

    private static func isYouTubeHost(_ host: String) -> Bool {
        let hosts = ["youtube.com", "youtu.be", "youtube-nocookie.com"]
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Eleven characters of YouTube's ID alphabet.
    static func isVideoID(_ candidate: String) -> Bool {
        candidate.count == 11 && candidate.allSatisfy(isIDCharacter)
    }

    private static func isPlaylistID(_ candidate: String) -> Bool {
        (2...64).contains(candidate.count) && candidate.allSatisfy(isIDCharacter)
    }

    private static func isChannelID(_ candidate: String) -> Bool {
        candidate.count == 24 && candidate.hasPrefix("UC") && candidate.allSatisfy(isIDCharacter)
    }

    private static func isHandle(_ candidate: String) -> Bool {
        let name = candidate.dropFirst()
        return (3...30).contains(name.count) && name.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || "._-".contains(character))
        }
    }

    private static func isIDCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
    }

    /// `t` or `start`, in the query or after a `#`: `90`, `90s`, `1m30s`, `1h2m3s`.
    private static func startTime(in components: URLComponents) -> TimeInterval? {
        let fragmentValue = components.fragment.flatMap { fragment -> String? in
            URLComponents(string: "?" + fragment)?.queryValue("t")
        }
        guard let raw = components.queryValue("t") ?? components.queryValue("start") ?? fragmentValue else {
            return nil
        }
        return duration(raw)
    }

    /// Seconds in one of the forms YouTube writes a time in, or nil if it is none of them.
    static func duration(_ raw: String) -> TimeInterval? {
        let text = raw.lowercased()
        if let seconds = Int(text) { return seconds > 0 ? TimeInterval(seconds) : nil }

        var total = 0
        var number = ""
        var sawUnit = false
        for character in text {
            if character.isASCII, character.isNumber {
                number.append(character)
                continue
            }
            guard let value = Int(number) else { return nil }
            switch character {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: return nil
            }
            number = ""
            sawUnit = true
        }
        guard sawUnit, number.isEmpty, total > 0 else { return nil }
        return TimeInterval(total)
    }
}

private extension URLComponents {
    func queryValue(_ name: String) -> String? {
        queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }
}
