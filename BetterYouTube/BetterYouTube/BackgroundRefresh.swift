import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// Periodically checks subscribed channels for new uploads and turns them into notifications.
///
/// There is no push channel for a personal YouTube client — the Data API has no webhooks for an
/// end user — so the app polls, plus once whenever it comes to the foreground.
///
/// *Who* keeps the clock is the one real difference between the two platforms. On iOS the app is
/// suspended the moment it leaves the screen, so the poll has to be handed to the system as a
/// `BGAppRefreshTask` and run on iOS's schedule rather than the app's. A Mac app that is open is
/// simply running, so it keeps its own timer and nothing needs to be handed anywhere — which also
/// means the interval is honoured rather than treated as a hint.
enum BackgroundRefresh {
    /// How long between polls. On iOS this is the earliest the system will *consider* running the
    /// task; on macOS it is what actually happens.
    static let interval: TimeInterval = 2 * 60 * 60

#if os(iOS)

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

    static func schedule(after interval: TimeInterval = BackgroundRefresh.interval) {
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

#else

    /// The Mac's clock, started once at launch and left running for the life of the app.
    ///
    /// Held so a second call can't start a second loop — `startPolling` is called from the app
    /// delegate, and an app delegate method is not a promise that it happens once.
    @MainActor private static var poller: Task<Void, Never>?

    @MainActor
    static func startPolling() {
        guard poller == nil else { return }
        poller = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await checkForNewVideos()
            }
        }
    }

    /// The counterpart of iOS's "queue the next one before going away". A Mac app doesn't go
    /// away, so there is nothing to queue; the loop above is already running.
    static func schedule(after interval: TimeInterval = BackgroundRefresh.interval) {}

#endif

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
