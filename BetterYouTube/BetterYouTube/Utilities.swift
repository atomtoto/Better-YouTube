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
