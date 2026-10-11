import Foundation

/// One entry in the in-app notification inbox.
struct NotificationItem: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let videoId: String
    let title: String
    let channelId: String
    let channelTitle: String
    let thumbnailURL: URL?
    let date: Date
    var isRead: Bool

    var video: Video {
        Video(id: videoId, title: title, channelId: channelId, channelTitle: channelTitle,
              description: "", thumbnailURL: thumbnailURL, publishedAt: nil)
    }

    init(video: Video, date: Date = Date()) {
        self.id = video.id
        self.videoId = video.id
        self.title = video.title
        self.channelId = video.channelId
        self.channelTitle = video.channelTitle
        self.thumbnailURL = video.thumbnailURL
        self.date = video.publishedAt ?? date
        self.isRead = false
    }
}

enum NotificationMode: String, Codable, CaseIterable, Identifiable {
    case off
    case all
    case selected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return String(localized: "Off")
        case .all: return String(localized: "All Subscriptions")
        case .selected: return String(localized: "Selected Channels")
        }
    }
}

/// Notification preferences, the seen-video ledger used to detect new uploads, and the inbox.
@MainActor
final class NotificationStore: ObservableObject {
    static let shared = NotificationStore(fileURL: FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("notifications.json"))

    @Published var mode: NotificationMode { didSet { persist() } }
    @Published private(set) var channelOptIns: Set<String> = []
    @Published private(set) var items: [NotificationItem] = []
    @Published private(set) var isImportingYouTube = false
    @Published private(set) var lastYouTubeImport: YouTubeImport?
    @Published private(set) var lastYouTubeImportDate: Date?
    @Published var automaticallyImportYouTube = UserDefaults.standard.object(forKey: "auto_import_youtube_notifications") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticallyImportYouTube, forKey: "auto_import_youtube_notifications") }
    }
    private var lastYouTubeAttempt: Date?

    func importYouTubeIfDue() async {
        guard automaticallyImportYouTube, !isImportingYouTube else { return }
        await YouTubeWebSession.shared.refresh()
        guard YouTubeWebSession.shared.isSignedIn else { return }
        let interval: TimeInterval = lastYouTubeImport?.failure == nil ? 15 * 60 : 60
        guard lastYouTubeAttempt.map({ Date().timeIntervalSince($0) >= interval }) ?? true else { return }
        _ = await importFromYouTube(enableNotifications: false)
    }

    /// Video IDs already accounted for, so a video is only ever announced once.
    private var seenVideoIds: Set<String> = []
    /// The same IDs, least recently seen first — what decides which ones the cap forgets.
    ///
    /// A `Set` has no order, and trimming one with `prefix` dropped arbitrary IDs, recent ones
    /// included. A forgotten ID that is still in a channel's latest uploads reads as new on the
    /// next check, and was announced a second time.
    private var seenOrder: [String] = []
    /// Channels whose uploads have been read at least once. The first read of a channel only
    /// records what it already has — otherwise turning the bell on for it, or a check that
    /// reaches it for the first time, would announce its back catalogue as new.
    private var knownChannels: Set<String> = []
    /// The first sync only records what already exists — otherwise every back-catalogue
    /// video would arrive as a notification at once.
    private var hasBootstrapped = false

    private static let seenLimit = 2_000
    /// A channel read for the first time still announces what it uploaded within this window:
    /// that is news, where the rest of its latest uploads are not.
    private static let freshUploadWindow: TimeInterval = 24 * 60 * 60

    private struct Snapshot: Codable {
        var mode: NotificationMode
        var channelOptIns: Set<String>
        var items: [NotificationItem]
        /// Oldest first. Files written before the ledger was ordered hold a set's array here,
        /// which decodes the same way.
        var seenVideoIds: [String]
        var hasBootstrapped: Bool
        var knownChannels: Set<String>?
    }

    private let fileURL: URL

    /// Internal rather than private so tests can point a store at a file of their own.
    init(fileURL: URL) {
        self.fileURL = fileURL
        self.mode = .off

        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            self.mode = snapshot.mode
            self.channelOptIns = snapshot.channelOptIns
            self.items = snapshot.items
            self.seenOrder = snapshot.seenVideoIds
            self.seenVideoIds = Set(snapshot.seenVideoIds)
            self.hasBootstrapped = snapshot.hasBootstrapped
            self.knownChannels = snapshot.knownChannels ?? []
        }
    }

    // MARK: Checking for new uploads

    private static let lastCheckKey = "notifications_last_upload_check"
    /// The least time between two automatic checks. Coming back to the app is one of the
    /// triggers, and each check reads every channel it covers — about a quota unit apiece.
    static let minimumCheckInterval: TimeInterval = 30 * 60

    /// Whether an automatic check is allowed yet. Pulling to refresh skips this.
    var isUploadCheckDue: Bool {
        guard let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date else { return true }
        return Date().timeIntervalSince(last) >= Self.minimumCheckInterval
    }

    func recordUploadCheck(at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: Self.lastCheckKey)
    }

    /// The channels a check should read, in the order they should be read: the ones you rang
    /// the bell for first, since the reader stops at a fixed number of channels.
    func channelsToCheck(subscriptions: [String]) -> [String] {
        switch mode {
        case .off:
            return []
        case .selected:
            return channelOptIns.sorted()
        case .all:
            let optedIn = channelOptIns.sorted()
            let optedInSet = Set(optedIn)
            return optedIn + subscriptions.filter { !optedInSet.contains($0) }
        }
    }

    var unreadCount: Int { items.filter { !$0.isRead }.count }

    var isEnabled: Bool { mode != .off }

    // MARK: Per-channel opt-in

    func isEnabled(for channelId: String) -> Bool {
        switch mode {
        case .off: return false
        case .all: return true
        case .selected: return channelOptIns.contains(channelId)
        }
    }

    func isOptedIn(_ channelId: String) -> Bool {
        channelOptIns.contains(channelId)
    }

    func toggleOptIn(_ channelId: String) {
        if channelOptIns.contains(channelId) {
            channelOptIns.remove(channelId)
        } else {
            channelOptIns.insert(channelId)
            // Opting a channel in implies wanting notifications at all.
            if mode == .off { mode = .selected }
        }
        persist()
    }

    // MARK: Inbox

    /// Records `videos` as seen and returns the ones that are genuinely new *and* opted in.
    func ingest(_ videos: [Video], now: Date = Date()) -> [Video] {
        let unseen = videos.filter { !seenVideoIds.contains($0.id) }
        let newcomers = Set(videos.map(\.channelId)).subtracting(knownChannels)
        markSeen(videos.map(\.id))
        knownChannels.formUnion(videos.map(\.channelId).filter { !$0.isEmpty })

        guard hasBootstrapped else {
            hasBootstrapped = true
            persist()
            return []
        }

        let announced = unseen.filter { video in
            guard isEnabled(for: video.channelId) else { return false }
            guard newcomers.contains(video.channelId) else { return true }
            // A channel read for the first time: only what it uploaded just now is news.
            guard let published = video.publishedAt else { return false }
            return now.timeIntervalSince(published) < Self.freshUploadWindow
        }
        if !announced.isEmpty {
            items.insert(contentsOf: announced.map { NotificationItem(video: $0) }, at: 0)
            if items.count > 100 { items.removeLast(items.count - 100) }
        }
        persist()
        return announced
    }

    /// Adds IDs to the ledger, or moves them to its recent end if they are already there, then
    /// forgets the least recently seen beyond the cap. A video still among a channel's latest
    /// uploads is seen again on every check, so it is never the one forgotten.
    private func markSeen(_ ids: [String]) {
        let batch = Set(ids)
        guard !batch.isEmpty else { return }
        seenOrder.removeAll { batch.contains($0) }
        var appended = Set<String>()
        for id in ids where appended.insert(id).inserted { seenOrder.append(id) }
        seenVideoIds.formUnion(batch)

        let overflow = seenOrder.count - Self.seenLimit
        if overflow > 0 {
            seenVideoIds.subtract(seenOrder.prefix(overflow))
            seenOrder.removeFirst(overflow)
        }
    }

    // MARK: YouTube's own notifications

    /// What reading YouTube's notification inbox turned up.
    struct YouTubeImport: Equatable {
        var notifications = 0
        var channels = 0
        var failure: String?
    }

    /// Reads the account's real notification inbox through the web session, and takes two things
    /// from it: the notifications themselves, and the channels behind them.
    ///
    /// The second is the answer to "which channels have the bell on", arrived at sideways. The
    /// Data API cannot say: a subscription resource carries `contentDetails.activityType`, a
    /// leftover from when the choice was uploads-or-everything, and nothing that maps to the
    /// bell's three settings. But a channel only reaches this inbox *because* its bell is on, so
    /// the channels that appear here are the ones you asked to hear about — with the one gap
    /// that a channel which hasn't uploaded lately isn't in the list to be found.
    func importFromYouTube(enableNotifications: Bool = true) async -> YouTubeImport {
        guard !isImportingYouTube else { return YouTubeImport(failure: String(localized: "An import is already in progress.")) }
        isImportingYouTube = true
        lastYouTubeAttempt = Date()
        defer { isImportingYouTube = false }
        let result = await performYouTubeImport(enableNotifications: enableNotifications)
        lastYouTubeImport = result
        if result.failure == nil { lastYouTubeImportDate = Date() }
        await NotificationService.shared.updateBadge()
        return result
    }

    private func performYouTubeImport(enableNotifications: Bool) async -> YouTubeImport {
        do {
            let ids = try await YouTubeFeedReader.notifications.harvest(from: YouTubeWebSession.notificationsURL)
            guard !ids.isEmpty else { return YouTubeImport() }
            let videos = try await YouTubeAPIService.shared.videos(ids: ids)
            guard !videos.isEmpty else {
                return YouTubeImport(failure: YouTubeFeedIssue.nothingFound.localizedDescription)
            }

            let channels = Set(videos.map(\.channelId).filter { !$0.isEmpty })
            channelOptIns.formUnion(channels)
            if enableNotifications, mode == .off { mode = .selected }

            // YouTube has already shown you these, so they land in the inbox read, and counted as
            // seen — announcing them again as banners would be the app shouting yesterday's news.
            let known = Set(items.map(\.id))
            let imported = videos
                .filter { !known.contains($0.id) }
                .map { video -> NotificationItem in
                    var item = NotificationItem(video: video)
                    item.isRead = true
                    return item
                }

            items.append(contentsOf: imported)
            items.sort { $0.date > $1.date }
            if items.count > 100 { items.removeLast(items.count - 100) }

            markSeen(videos.map(\.id))
            hasBootstrapped = true
            persist()

            return YouTubeImport(notifications: imported.count, channels: channels.count)
        } catch {
            return YouTubeImport(failure: error.localizedDescription)
        }
    }

    func markRead(_ item: NotificationItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isRead = true
        persist()
    }

    func markAllRead() {
        for index in items.indices { items[index].isRead = true }
        persist()
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    /// The inbox, the opt-ins, the ledger of what has been seen — all of it. For the reset in
    /// Settings. `hasBootstrapped` goes back to false on purpose: the next check should learn
    /// what already exists rather than announce a back catalogue all at once.
    func eraseEverything() {
        items = []
        channelOptIns = []
        seenVideoIds = []
        seenOrder = []
        knownChannels = []
        hasBootstrapped = false
        mode = .off
        automaticallyImportYouTube = true
        lastYouTubeImport = nil
        lastYouTubeImportDate = nil
        UserDefaults.standard.removeObject(forKey: Self.lastCheckKey)
        persist()
    }

    private func persist() {
        let snapshot = Snapshot(
            mode: mode,
            channelOptIns: channelOptIns,
            items: items,
            seenVideoIds: seenOrder,
            hasBootstrapped: hasBootstrapped,
            knownChannels: knownChannels
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
