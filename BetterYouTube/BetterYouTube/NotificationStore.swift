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
        case .off: return "Off"
        case .all: return "All Subscriptions"
        case .selected: return "Selected Channels"
        }
    }
}

/// Notification preferences, the seen-video ledger used to detect new uploads, and the inbox.
@MainActor
final class NotificationStore: ObservableObject {
    static let shared = NotificationStore()

    @Published var mode: NotificationMode { didSet { persist() } }
    @Published private(set) var channelOptIns: Set<String> = []
    @Published private(set) var items: [NotificationItem] = []

    /// Video IDs already accounted for, so a video is only ever announced once.
    private var seenVideoIds: Set<String> = []
    /// The first sync only records what already exists — otherwise every back-catalogue
    /// video would arrive as a notification at once.
    private var hasBootstrapped = false

    private struct Snapshot: Codable {
        var mode: NotificationMode
        var channelOptIns: Set<String>
        var items: [NotificationItem]
        var seenVideoIds: Set<String>
        var hasBootstrapped: Bool
    }

    private let fileURL: URL

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = documents.appendingPathComponent("notifications.json")
        self.mode = .off

        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            self.mode = snapshot.mode
            self.channelOptIns = snapshot.channelOptIns
            self.items = snapshot.items
            self.seenVideoIds = snapshot.seenVideoIds
            self.hasBootstrapped = snapshot.hasBootstrapped
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
    func ingest(_ videos: [Video]) -> [Video] {
        let unseen = videos.filter { !seenVideoIds.contains($0.id) }
        seenVideoIds.formUnion(videos.map(\.id))
        if seenVideoIds.count > 2_000 {
            seenVideoIds = Set(seenVideoIds.prefix(2_000))
        }

        guard hasBootstrapped else {
            hasBootstrapped = true
            persist()
            return []
        }

        let announced = unseen.filter { isEnabled(for: $0.channelId) }
        if !announced.isEmpty {
            items.insert(contentsOf: announced.map { NotificationItem(video: $0) }, at: 0)
            if items.count > 100 { items.removeLast(items.count - 100) }
        }
        persist()
        return announced
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

    private func persist() {
        let snapshot = Snapshot(
            mode: mode,
            channelOptIns: channelOptIns,
            items: items,
            seenVideoIds: seenVideoIds,
            hasBootstrapped: hasBootstrapped
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
