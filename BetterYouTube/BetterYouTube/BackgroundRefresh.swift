import BackgroundTasks
import Foundation

/// Periodically checks subscribed channels for new uploads and turns them into notifications.
///
/// There is no push channel for a personal YouTube client — the Data API has no webhooks for an
/// end user — so this polls on iOS's schedule via `BGAppRefreshTask`, plus once whenever the app
/// comes to the foreground.
enum BackgroundRefresh {
    static let taskIdentifier = "com.atomtoto.BetterYouTube.refresh"

    /// Must run before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
    }

    static func schedule(after interval: TimeInterval = 2 * 60 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        // Always queue the next one first: a task that isn't rescheduled never runs again.
        schedule()

        let work = Task {
            await checkForNewVideos()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    /// Fetches recent uploads, records them, and notifies about the ones that are new.
    static func checkForNewVideos() async {
        let (isEnabled, isSignedIn) = await MainActor.run {
            (NotificationStore.shared.isEnabled, GoogleAuthService.shared.isSignedIn)
        }
        guard isEnabled, isSignedIn else { return }

        guard let videos = try? await YouTubeAPIService.shared.subscriptionFeed(
            channelLimit: 25,
            perChannel: 3
        ) else { return }

        let fresh = await MainActor.run { NotificationStore.shared.ingest(videos) }
        guard !fresh.isEmpty else { return }

        // Cap the burst so a quiet week doesn't turn into a wall of banners.
        for video in fresh.prefix(5) {
            await NotificationService.shared.post(for: video)
        }
        await NotificationService.shared.updateBadge()
    }
}
