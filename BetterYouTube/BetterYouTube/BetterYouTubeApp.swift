import SwiftUI
import UserNotifications

@main
struct BetterYouTubeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var apiKeyStore = APIKeyStore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var watchLater = WatchLaterStore.shared
    @StateObject private var auth = GoogleAuthService.shared
    @StateObject private var recentSearches = RecentSearchStore.shared
    @StateObject private var notificationStore = NotificationStore.shared
    @StateObject private var notifications = NotificationService.shared
    @StateObject private var router = AppRouter.shared
    @StateObject private var player = PlayerManager.shared
    @StateObject private var quota = QuotaTracker.shared
    @StateObject private var webSession = YouTubeWebSession.shared
    @StateObject private var downloadStore = DownloadStore.shared
    @StateObject private var downloadManager = DownloadManager.shared
    @StateObject private var downloadSettings = DownloadSettings.shared

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(apiKeyStore)
                .environmentObject(library)
                .environmentObject(watchLater)
                .environmentObject(auth)
                .environmentObject(recentSearches)
                .environmentObject(notificationStore)
                .environmentObject(notifications)
                .environmentObject(router)
                .environmentObject(player)
                .environmentObject(quota)
                .environmentObject(webSession)
                .environmentObject(downloadStore)
                .environmentObject(downloadManager)
                .environmentObject(downloadSettings)
                .tint(.red)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                Task {
                    await notifications.refreshAuthorizationStatus()
                    await BackgroundRefresh.checkForNewVideos()
                }
            case .background:
                BackgroundRefresh.schedule()
            default:
                break
            }
        }
    }
}

/// Only here for the three things SwiftUI's lifecycle can't do: registering the background task
/// before launch finishes, owning the notification-center delegate, and being handed the
/// background downloads' completion handler.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundRefresh.register()
        UNUserNotificationCenter.current().delegate = NotificationService.shared
        NotificationService.shared.configure()
        return true
    }

    /// iOS relaunched the app to say a download finished while it was gone.
    ///
    /// The handler has to be kept and called once the session has finished reporting, which is
    /// what tells the system the app is done and can be suspended again. Skipping it is how a
    /// background download ends up being blamed for the battery it didn't spend.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            DownloadManager.shared.backgroundCompletionHandler = completionHandler
        }
    }
}
