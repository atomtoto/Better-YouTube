import Foundation

/// Converts ISO 8601 durations returned by the YouTube API (e.g. "PT1H2M3S") into "1:02:03".
///
/// The `T` decides what `M` means, and it used to be read and then thrown away: before the `T` it
/// is months, after it minutes. So `P1M` — a month — came back as "1:00", the same as `PT1M`.
/// No video is a month long, but the date half of a duration is not hypothetical either: `P0D` is
/// what a live stream returns.
///
/// Days and weeks fold into hours, so a 30-hour stream reads as 30:00:00 rather than losing a
/// day. Years and months are dropped, because converting them needs a calendar and a date to
/// start from, and a duration has neither.
enum ISO8601DurationFormatter {
    static func humanReadable(_ iso: String) -> String {
        var days = 0, hours = 0, minutes = 0, seconds = 0
        var number = ""
        /// Set by the `T`, which is the only thing separating months from minutes.
        var isTime = false

        for character in iso {
            switch character {
            case "P":
                continue
            case "T":
                isTime = true
                number = ""
            case "Y":
                // Nothing to fold a year into. See above.
                number = ""
            case "M":
                // The one letter that means two things.
                if isTime { minutes = Int(number) ?? 0 }
                number = ""
            case "W":
                days += (Int(number) ?? 0) * 7
                number = ""
            case "D":
                days += Int(number) ?? 0
                number = ""
            case "H":
                hours = Int(number) ?? 0
                number = ""
            case "S":
                seconds = Int(number) ?? 0
                number = ""
            default:
                if character.isNumber { number.append(character) }
            }
        }

        hours += days * 24
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

enum CountFormatter {
    static func abbreviated(_ count: Int?) -> String {
        guard let count else { return "—" }
        let number = Double(count)
        switch count {
        case 1_000_000_000...:
            return String(format: "%.1fB", number / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", number / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", number / 1_000)
        default:
            return "\(count)"
        }
    }
}

enum RelativeDateFormatter {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func string(from date: Date?) -> String {
        guard let date else { return "" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Reads the video ids out of a playlist CSV exported from Google Takeout.
///
/// Deliberately a scanner rather than a CSV parser: only one column is ever wanted, and Google has
/// changed the shape of this file more than once. So every line is examined, its first field taken,
/// and kept if it looks like a video id — which carries it over headers, the metadata block some
/// exports put on top, a UTF-8 BOM, CRLF endings, quoting and stray spaces alike.
///
/// It can be generous because it isn't the last word: ids are resolved against `videos.list`
/// afterwards, so anything that merely *looks* like one — an eleven-letter word in a preamble —
/// resolves to nothing and is reported as missing rather than silently believed.
enum TakeoutPlaylistCSV {
    /// One line of the export: the video, and when it was added to the playlist if the file says.
    struct Row: Equatable {
        let id: String
        let addedAt: Date?
    }

    /// The most recently added ids, newest first, at most `limit` of them.
    ///
    /// The export carries the date each video was added, so that is what decides — the file's own
    /// order is never trusted when the dates are there. Only when a file carries no dates at all
    /// does it fall back to position, taking the head: a real export lists the newest first, so
    /// the opening lines are already the wanted end, in the wanted order.
    static func mostRecentlyAdded(in rows: [Row], limit: Int) -> [String] {
        let dated = rows.compactMap { row in row.addedAt.map { (row.id, $0) } }

        guard !rows.isEmpty, dated.count == rows.count else {
            return rows.prefix(limit).map(\.id)
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Rows in the order the file lists them, without duplicates.
    static func rows(in text: String) -> [Row] {
        var seen = Set<String>()
        var rows: [Row] = []

        for line in text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true) {

            let fields = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            let field = Self.unwrap(fields[0])

            guard isVideoID(field), seen.insert(field).inserted else { continue }
            let stamp = fields.count > 1 ? Self.unwrap(fields[1]) : ""
            rows.append(Row(id: field, addedAt: YTDateParser.parse(stamp.isEmpty ? nil : stamp)))
        }
        return rows
    }

    /// Strips the quoting, spacing and byte-order mark a CSV field can arrive wrapped in.
    private static func unwrap(_ field: Substring) -> String {
        field
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"﻿"))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Eleven characters of YouTube's id alphabet, and nothing else.
    private static func isVideoID(_ candidate: String) -> Bool {
        guard candidate.count == 11 else { return false }
        return candidate.allSatisfy { character in
            character.isLetter && character.isASCII
                || character.isNumber && character.isASCII
                || character == "-" || character == "_"
        }
    }
}

/// An in-memory and persistent cache for channel avatars across screens.
@MainActor
final class ChannelAvatarCache {
    static let shared = ChannelAvatarCache()

    private var memoryCache: [String: URL] = [:]
    private var inFlight: [String: Task<URL?, Never>] = [:]

    private init() {
        if let homeAvatars = YouTubeWebSession.shared.feedCache.load()?.avatars {
            memoryCache = homeAvatars
        }
    }

    func avatarURL(for channelId: String) -> URL? {
        guard !channelId.isEmpty else { return nil }
        return memoryCache[channelId]
    }

    func setAvatarURL(_ url: URL, for channelId: String) {
        guard !channelId.isEmpty else { return }
        memoryCache[channelId] = url
    }

    func setAvatarURLs(_ dict: [String: URL]) {
        for (id, url) in dict where !id.isEmpty {
            memoryCache[id] = url
        }
    }

    func fetchAvatar(for channelId: String, service: YouTubeAPIService = .shared) async -> URL? {
        guard !channelId.isEmpty else { return nil }
        if let cached = memoryCache[channelId] {
            return cached
        }
        if let existingTask = inFlight[channelId] {
            return await existingTask.value
        }

        let task = Task<URL?, Never> {
            // 1. Try API service (channels.list)
            if let channel = try? await service.channel(id: channelId), let url = channel.thumbnailURL {
                return url
            }
            // 2. Try API service (channelAvatars batch)
            let avatars = await service.channelAvatars(ids: [channelId])
            if let url = avatars[channelId] {
                return url
            }
            // 3. Fallback to public channel web page meta tag og:image
            return await Self.fetchWebAvatar(channelId: channelId)
        }

        inFlight[channelId] = task
        let result = await task.value
        inFlight[channelId] = nil

        if let result {
            memoryCache[channelId] = result
        }
        return result
    }

    private static func fetchWebAvatar(channelId: String) async -> URL? {
        guard let url = URL(string: "https://www.youtube.com/channel/\(channelId)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(YouTubeWebSession.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Match <meta property="og:image" content="(...)">
        if let match = html.range(of: #"<meta property="og:image" content="([^"]+)""#, options: .regularExpression) {
            let meta = String(html[match])
            if let contentRange = meta.range(of: #"content="([^"]+)""#, options: .regularExpression) {
                let contentString = String(meta[contentRange])
                    .replacingOccurrences(of: "content=\"", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                if let avatarURL = URL(string: contentString) {
                    return avatarURL
                }
            }
        }
        return nil
    }
}
