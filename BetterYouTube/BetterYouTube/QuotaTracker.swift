import Foundation

/// One endpoint's share of a day's quota.
struct QuotaSpend: Identifiable {
    let endpoint: String
    let units: Int

    var id: String { endpoint }

    /// The endpoint under a name that means something outside the API client.
    var title: String {
        switch endpoint {
        case "search": return "Search"
        case "videos": return "Videos"
        case "channels": return "Channels"
        case "playlists": return "Playlists"
        case "playlistItems": return "Playlist items"
        case "subscriptions": return "Subscriptions"
        case "commentThreads": return "Comments"
        default: return endpoint.capitalized
        }
    }
}

/// What the day's API calls have cost, counted here on the device.
///
/// The Data API bills every call against a daily allowance — 10,000 units for a new Cloud
/// project — but offers no endpoint that reports what is left of it, so the only way to show a
/// number is to price the calls as they go out. Every request in `YouTubeAPIService` passes
/// through one place, which is where the counting happens.
///
/// Two things follow from that, and Settings says both: the total covers what *this device*
/// spent, while the allowance belongs to the Cloud project behind the API key and anything else
/// using that key spends from the same pot; and the count is Google's published price list
/// applied locally, not a reading taken from Google.
///
/// The day rolls over at midnight in Google's own time zone — Pacific, not local — so that is
/// the calendar the boundary is computed in.
@MainActor
final class QuotaTracker: ObservableObject {
    static let shared = QuotaTracker()

    /// The daily allowance every Cloud project starts with.
    static let dailyLimit = 10_000

    /// Units spent since the last reset.
    @Published private(set) var used: Int = 0
    /// Units per endpoint, so Settings can say where the day went.
    @Published private(set) var spending: [String: Int] = [:]

    /// The Pacific day the totals above belong to.
    private var day: String
    private let defaults = UserDefaults.standard

    private enum Key {
        static let day = "quota_day"
        static let used = "quota_used"
        static let spending = "quota_spending"
    }

    private init() {
        self.day = Self.currentDay()
        // Yesterday's total is Google's to forget, not ours to carry over.
        guard defaults.string(forKey: Key.day) == day else {
            persist()
            return
        }
        used = defaults.integer(forKey: Key.used)
        spending = defaults.dictionary(forKey: Key.spending) as? [String: Int] ?? [:]
    }

    // MARK: - Counting

    /// Charges one call. Called for every request that reaches the API, whatever it answers:
    /// a rejected call is billed like an accepted one.
    func record(units: Int, endpoint: String) {
        guard units > 0, !endpoint.isEmpty else { return }
        rollOverIfNeeded()
        used += units
        spending[endpoint, default: 0] += units
        persist()
    }

    /// Google's price list, in units per call:
    /// https://developers.google.com/youtube/v3/determine_quota_cost
    ///
    /// Reads are 1 unit and a search 100 — which is why the app reads a channel's uploads
    /// through its uploads playlist rather than searching for them — while anything that writes
    /// is 50, the price of every change to the Watch Later playlist.
    nonisolated static func cost(endpoint: String, method: String) -> Int {
        guard method.uppercased() == "GET" else { return 50 }
        return endpoint == "search" ? 100 : 1
    }

    /// Rolls the counter over once the Pacific day has turned. Also called from Settings, so a
    /// screen left open overnight doesn't keep showing yesterday's total.
    func refresh() {
        rollOverIfNeeded()
    }

    /// Starts the day over by hand — for when the count has drifted from what the Cloud Console
    /// shows because the same key was spent somewhere else.
    func reset() {
        day = Self.currentDay()
        used = 0
        spending = [:]
        persist()
    }

    private func rollOverIfNeeded() {
        let today = Self.currentDay()
        guard today != day else { return }
        day = today
        used = 0
        spending = [:]
        persist()
    }

    private func persist() {
        defaults.set(day, forKey: Key.day)
        defaults.set(used, forKey: Key.used)
        defaults.set(spending, forKey: Key.spending)
    }

    // MARK: - What Settings shows

    var remaining: Int { max(0, Self.dailyLimit - used) }

    /// The share of the allowance spent, 0...1.
    var fraction: Double {
        min(1, max(0, Double(used) / Double(Self.dailyLimit)))
    }

    /// When the allowance comes back: the next midnight in Google's time zone, as a date the UI
    /// can show in the reader's own.
    var resetDate: Date {
        let calendar = Self.quotaCalendar
        let startOfDay = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
    }

    /// Where the day went, biggest first.
    var breakdown: [QuotaSpend] {
        spending
            .map { QuotaSpend(endpoint: $0.key, units: $0.value) }
            .sorted { first, second in
                first.units == second.units
                    ? first.endpoint < second.endpoint
                    : first.units > second.units
            }
    }

    // MARK: - Google's day

    private static let quotaCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        if let pacific = TimeZone(identifier: "America/Los_Angeles") {
            calendar.timeZone = pacific
        }
        return calendar
    }()

    /// Today in Pacific time, as a key stable enough to compare two launches by.
    private static func currentDay() -> String {
        let components = quotaCalendar.dateComponents([.year, .month, .day], from: Date())
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}
