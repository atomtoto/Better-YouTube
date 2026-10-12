import Foundation

/// What the demo has to show: real, public videos and their channels, read from
/// `DemoCatalog.json` in the app's bundle.
///
/// The videos play for real — YouTube's embed needs no key — and everything else about them, from
/// titles to view counts, comes from this file, which `scripts/build-demo-catalog.py` builds from
/// the videos' public pages. Openly licensed channels on purpose: Blender's open movies, NASA,
/// CNES, NoCopyrightSounds and MIT OpenCourseWare.
struct DemoCatalog: Decodable, Sendable {
    struct Channel: Decodable, Sendable {
        let id: String
        let title: String
        let handle: String
        let description: String
        let avatar: URL
        let subscribers: Int?
        let videoCount: Int?
    }

    struct Video: Decodable, Sendable {
        let id: String
        let title: String
        let channelId: String
        let description: String
        let publishedAt: String
        /// ISO 8601, as the Data API gives it: `PT10M35S`.
        let duration: String
        let views: Int
        let categoryId: String
        let hasMaxres: Bool

        var seconds: Int { ISO8601DurationFormatter.seconds(duration) ?? 0 }
        var publishedDate: Date? { YTDateParser.parse(publishedAt) }
    }

    struct Playlist: Decodable, Sendable {
        let id: String
        let title: String
        let description: String
        let videoIds: [String]
    }

    let generatedAt: String
    let channels: [Channel]
    let videos: [Video]
    let playlists: [Playlist]

    /// Read once, the first time the demo needs it.
    static let shared: DemoCatalog = {
        guard let url = Bundle.main.url(forResource: "DemoCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(DemoCatalog.self, from: data)
        else {
            assertionFailure("DemoCatalog.json is missing from the bundle or doesn't decode")
            return DemoCatalog(generatedAt: "", channels: [], videos: [], playlists: [])
        }
        return catalog
    }()

    func channel(_ id: String) -> Channel? { channels.first { $0.id == id } }
    func video(_ id: String) -> Video? { videos.first { $0.id == id } }
    func uploads(of channelId: String) -> [Video] { videos.filter { $0.channelId == channelId } }

    /// The channel behind a `@handle`, written with or without its `@`.
    func channel(handle: String) -> Channel? {
        let wanted = handle.hasPrefix("@") ? handle : "@" + handle
        return channels.first { $0.handle.caseInsensitiveCompare(wanted) == .orderedSame }
    }

    /// The videos whose title, channel or description hold every word of `query`, those that
    /// name it in the title first. Accents and case don't matter: "cnes" finds CNES, "medecine"
    /// finds "médecine".
    func search(_ query: String) -> [Video] {
        let words = Self.words(in: query)
        guard !words.isEmpty else { return [] }
        let matches = videos.filter { video in
            let haystack = Self.fold("\(video.title) \(channel(video.channelId)?.title ?? "") \(video.description)")
            return words.allSatisfy(haystack.contains)
        }
        return matches.sorted { left, right in
            let leftInTitle = words.allSatisfy(Self.fold(left.title).contains)
            let rightInTitle = words.allSatisfy(Self.fold(right.title).contains)
            if leftInTitle != rightInTitle { return leftInTitle }
            return left.views > right.views
        }
    }

    func searchChannels(_ query: String) -> [Channel] {
        let words = Self.words(in: query)
        guard !words.isEmpty else { return [] }
        return channels.filter { channel in
            let haystack = Self.fold("\(channel.title) \(channel.handle)")
            return words.allSatisfy(haystack.contains)
        }
    }

    /// What the search field offers while you type in the demo: the catalogue's own titles and
    /// channels that start with, or contain, what is there so far — so every suggestion finds
    /// something.
    func suggestions(for query: String) -> [String] {
        let folded = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !folded.isEmpty else { return [] }
        let names = channels.map(\.title) + videos.map(\.title)
        let starting = names.filter { Self.fold($0).hasPrefix(folded) }
        let containing = names.filter { !Self.fold($0).hasPrefix(folded) && Self.fold($0).contains(folded) }
        var seen = Set<String>()
        return (starting + containing).filter { seen.insert($0.lowercased()).inserted }.prefix(8).map { $0 }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func words(in query: String) -> [String] {
        fold(query).split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init)
    }
}

// MARK: - As the app's own models

extension DemoCatalog.Video {
    /// The thumbnail the API would hand over as the best one.
    var thumbnailURL: URL? {
        URL(string: "https://i.ytimg.com/vi/\(id)/\(hasMaxres ? "maxresdefault" : "hqdefault").jpg")
    }

    func asVideo(in catalog: DemoCatalog = .shared) -> Video {
        Video(
            id: id,
            title: title,
            channelId: channelId,
            channelTitle: catalog.channel(channelId)?.title ?? "",
            description: description,
            thumbnailURL: thumbnailURL,
            publishedAt: publishedDate,
            viewCount: views,
            likeCount: nil,
            duration: ISO8601DurationFormatter.humanReadable(duration),
            categoryId: categoryId
        )
    }
}
