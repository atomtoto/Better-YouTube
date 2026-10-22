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

    /// The system's refresh task, shared by the work and the expiration handler that may cut it
    /// short. BackgroundTasks documents its task objects as safe to complete from any thread,
    /// which their class can't declare.
    private final class RefreshTask: @unchecked Sendable {
        let task: BGAppRefreshTask
        private let lock = NSLock()
        private var isCompleted = false

        init(_ task: BGAppRefreshTask) { self.task = task }

        /// Completes the task, once.
        ///
        /// The system allows exactly one completion, and two callers can arrive: the expiration
        /// handler cuts the work short, the work then finishes anyway and completes the task a
        /// second time. The system logs that as an error and blames the app for the background
        /// work, so the second one is dropped here.
        func complete(success: Bool) {
            lock.lock()
            let alreadyCompleted = isCompleted
            isCompleted = true
            lock.unlock()
            guard !alreadyCompleted else { return }
            task.setTaskCompleted(success: success)
        }
    }

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

        let refresh = RefreshTask(task)
        let work = Task {
            await checkForNewVideos()
            refresh.complete(success: true)
        }

        refresh.task.expirationHandler = {
            // Cancelling the task stops the work where it stands — the check below watches for
            // it — and the task is completed here, once, whichever of the two gets there first.
            work.cancel()
            refresh.complete(success: false)
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
    ///
    /// The channels read are the ones notifications are actually on for. This used to read the
    /// first 25 subscriptions — alphabetically, because that is how the API lists them — so a
    /// channel whose bell was on but whose name came later in the alphabet was never checked
    /// at all. Selected channels need no Google sign-in: their uploads are public, and an API
    /// key reads them too.
    ///
    /// `force` skips the minimum interval, for an explicit pull to refresh. Every other trigger
    /// — coming back to the app, the system's background refresh, the Mac's timer — respects it,
    /// because each check costs about a quota unit per channel.
    static func checkForNewVideos(force: Bool = false) async {
        // The demo's channels are a snapshot: nothing new comes of them, and its inbox is filled.
        guard !DemoMode.isRunning else { return }
        // The system's expiration handler cancels the work when the app runs out of time. The
        // check below is the only thing that stops mid-way, so it has to be looked at between
        // the steps: the work is not worth finishing once it has been cut short.
        guard !Task.isCancelled else { return }
        let (mode, isSignedIn, hasKey, isDue) = await MainActor.run {
            (NotificationStore.shared.mode, GoogleAuthService.shared.isSignedIn,
             APIKeyStore.shared.hasKey, NotificationStore.shared.isUploadCheckDue)
        }
        guard mode != .off, isSignedIn || hasKey, force || isDue else { return }

        let subscriptions: [String]
        if mode == .all {
            guard isSignedIn,
                  let channels = try? await YouTubeAPIService.shared.mySubscriptions() else { return }
            subscriptions = channels.map(\.id)
        } else {
            subscriptions = []
        }
        let channelIDs = await MainActor.run {
            NotificationStore.shared.channelsToCheck(subscriptions: subscriptions)
        }
        guard !channelIDs.isEmpty else { return }
        guard !Task.isCancelled else { return }

        guard let videos = try? await YouTubeAPIService.shared.videos(
            fromChannels: channelIDs,
            perChannel: 3,
            limit: 300,
            enriched: false
        ) else { return }

        let fresh = await MainActor.run {
            NotificationStore.shared.recordUploadCheck()
            return NotificationStore.shared.ingest(videos)
        }
        guard !fresh.isEmpty else { return }
        guard !Task.isCancelled else { return }

        // Cap the burst so a quiet week doesn't turn into a wall of banners.
        for video in fresh.prefix(5) {
            guard !Task.isCancelled else { return }
            await NotificationService.shared.post(for: video)
        }
        await NotificationService.shared.updateBadge()
    }
}
