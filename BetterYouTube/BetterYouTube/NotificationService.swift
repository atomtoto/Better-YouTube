import Foundation
import UIKit
import UserNotifications

/// File-scope so the nonisolated delegate methods can read them without hopping actors.
private enum NotificationIdentifier {
    static let category = "NEW_VIDEO"
    static let watchLater = "WATCH_LATER"
    static let open = "OPEN_VIDEO"
}

/// Local notifications for new uploads: permission, delivery (with artwork and actions),
/// and handling taps so they open the right video.
@MainActor
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private override init() {
        super.init()
    }

    /// Registers the notification category and its actions. Called at launch.
    func configure() {
        let watchLater = UNNotificationAction(
            identifier: NotificationIdentifier.watchLater,
            title: "Watch Later",
            options: []
        )
        let open = UNNotificationAction(
            identifier: NotificationIdentifier.open,
            title: "Watch Now",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: NotificationIdentifier.category,
            actions: [open, watchLater],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        Task { await refreshAuthorizationStatus() }
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorizationStatus()
        return granted
    }

    /// Delivers one "new video" notification, with the thumbnail attached when it can be fetched.
    func post(for video: Video) async {
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = video.channelTitle.isEmpty ? "New video" : video.channelTitle
        content.body = video.title
        content.sound = .default
        content.categoryIdentifier = NotificationIdentifier.category
        content.threadIdentifier = video.channelId
        content.userInfo = [
            "videoId": video.id,
            "title": video.title,
            "channelId": video.channelId,
            "channelTitle": video.channelTitle,
            "thumbnailURL": video.thumbnailURL?.absoluteString ?? ""
        ]
        if let attachment = await Self.attachment(for: video) {
            content.attachments = [attachment]
        }
        content.badge = NSNumber(value: NotificationStore.shared.unreadCount)

        let request = UNNotificationRequest(
            identifier: "new-video-\(video.id)",
            content: content,
            trigger: nil // deliver immediately
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    func updateBadge() async {
        let count = NotificationStore.shared.unreadCount
        try? await UNUserNotificationCenter.current().setBadgeCount(count)
    }

    private static func attachment(for video: Video) async -> UNNotificationAttachment? {
        guard let url = video.thumbnailURL else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent("\(video.id).jpg")
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: video.id, url: fileURL)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Show banners even while the app is open, like YouTube does.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let videoId = userInfo["videoId"] as? String else { return }
        let actionIdentifier = response.actionIdentifier

        await MainActor.run {
            switch actionIdentifier {
            case NotificationIdentifier.watchLater:
                let video = Video(
                    id: videoId,
                    title: userInfo["title"] as? String ?? "",
                    channelId: userInfo["channelId"] as? String ?? "",
                    channelTitle: userInfo["channelTitle"] as? String ?? "",
                    description: "",
                    thumbnailURL: (userInfo["thumbnailURL"] as? String).flatMap(URL.init(string:)),
                    publishedAt: nil
                )
                if !LibraryStore.shared.isInWatchLater(video) {
                    LibraryStore.shared.toggleWatchLater(video)
                }
            default:
                AppRouter.shared.open(videoId: videoId)
            }

            if let item = NotificationStore.shared.items.first(where: { $0.videoId == videoId }) {
                NotificationStore.shared.markRead(item)
            }
        }
    }
}
