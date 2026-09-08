import Foundation

/// Converts ISO 8601 durations returned by the YouTube API (e.g. "PT1H2M3S") into "1:02:03".
enum ISO8601DurationFormatter {
    static func humanReadable(_ iso: String) -> String {
        var hours = 0, minutes = 0, seconds = 0
        var number = ""
        var isTime = false

        for char in iso {
            switch char {
            case "P":
                continue
            case "T":
                isTime = true
            case "H":
                hours = Int(number) ?? 0
                number = ""
            case "M":
                minutes = Int(number) ?? 0
                number = ""
            case "S":
                seconds = Int(number) ?? 0
                number = ""
            default:
                if char.isNumber { number.append(char) }
            }
        }
        _ = isTime

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
    /// Ids in the order the file lists them, without duplicates.
    static func videoIDs(in text: String) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []

        for line in text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true) {

            let field = line
                .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{FEFF}"))
                .trimmingCharacters(in: .whitespaces)

            guard isVideoID(field), seen.insert(field).inserted else { continue }
            ids.append(field)
        }
        return ids
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
