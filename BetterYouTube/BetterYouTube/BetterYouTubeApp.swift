import SwiftUI
import UserNotifications

@main
struct BetterYouTubeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var apiKeyStore = APIKeyStore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var auth = GoogleAuthService.shared
    @StateObject private var recentSearches = RecentSearchStore.shared
    @StateObject private var notificationStore = NotificationStore.shared
    @StateObject private var notifications = NotificationService.shared
    @StateObject private var router = AppRouter.shared
    @StateObject private var player = PlayerManager.shared

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(apiKeyStore)
                .environmentObject(library)
                .environmentObject(auth)
                .environmentObject(recentSearches)
                .environmentObject(notificationStore)
                .environmentObject(notifications)
                .environmentObject(router)
                .environmentObject(player)
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

/// Only here for the two things SwiftUI's lifecycle can't do: registering the background task
/// before launch finishes, and owning the notification-center delegate.
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
}
