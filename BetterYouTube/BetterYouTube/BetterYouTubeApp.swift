import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

@main
struct BetterYouTubeApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

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
                #if os(macOS)
                // A phone-shaped window is not a Mac app. This is wide enough for the sidebar
                // and a two-column feed, and tall enough that the expanded player has the
                // video *and* its details on screen at once.
                .frame(minWidth: 880, minHeight: 620)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        .windowToolbarStyle(.unified)
        .commands { PlayerCommands(player: player, router: router) }
        #endif
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

#if os(iOS)

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

#else

/// The Mac's half of the same job, minus the parts the Mac doesn't have.
///
/// There is no `BGTaskScheduler` to register with and no relaunch-for-downloads handshake: a Mac
/// app that is open is running, so `BackgroundRefresh` keeps its own clock (see that file), and a
/// background `URLSession` simply carries on in the same process. What is left is the notification
/// delegate, which is owned here for the same reason as on iOS — it has to exist before the first
/// notification can be delivered.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = NotificationService.shared
        NotificationService.shared.configure()
        BackgroundRefresh.startPolling()
    }

    /// One window, and closing it means you are done — the app has no document to leave open
    /// behind an empty menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Clicking the Dock icon with the window closed brings the app back rather than doing
    /// nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}

/// The menu bar.
///
/// Every one of these is something the iPhone offers as a gesture — a tap on the bar, a flick
/// down, turning the phone on its side — and a Mac has no gesture for any of them. A menu item is
/// the Mac's version of an affordance being discoverable, and the keyboard shortcut is what makes
/// it quicker than the phone's.
struct PlayerCommands: Commands {
    @ObservedObject var player: PlayerManager
    @ObservedObject var router: AppRouter

    var body: some Commands {
        // ⌘, opens Settings on every Mac app there has ever been. The app keeps Settings as a
        // sidebar item rather than a window of its own, so this selects it.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { router.selectedTab = .settings }
                .keyboardShortcut(",", modifiers: .command)
        }

        // Every shortcut below carries ⌘. That rules out the one the hand reaches for — space,
        // which is what Music, TV and QuickTime use — and it is deliberate: AppKit offers a key
        // event to the main menu *before* the focused view, so a menu item on a bare key takes
        // the space bar away from the search field, and ⌘←/⌘→ take away move-to-start-of-line.
        // A shortcut that breaks typing is worse than one more modifier.
        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play") {
                player.togglePlayPause()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(player.currentVideo == nil)

            Divider()

            Button("Skip Back 15 Seconds") {
                player.seek(to: player.progress.currentTime - 15)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(player.currentVideo == nil)

            Button("Skip Forward 15 Seconds") {
                player.seek(to: player.progress.currentTime + 15)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(player.currentVideo == nil)

            Button("Next Video") { player.playNext() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(player.upNext.isEmpty)

            Divider()

            Button(player.isExpanded ? "Minimize Player" : "Open Player") {
                if player.isExpanded {
                    player.collapse()
                } else {
                    player.expand()
                }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(player.currentVideo == nil)

            Button(player.isFullScreen ? "Exit Fill Window" : "Fill Window") {
                player.toggleFillsWindow()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(player.currentVideo == nil)

            Button("Stop Playback") { player.close() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(player.currentVideo == nil)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Button("Home") { router.selectedTab = .home }
                .keyboardShortcut("1", modifiers: .command)
            Button("Search") { router.selectedTab = .search }
                .keyboardShortcut("2", modifiers: .command)
            Button("Library") { router.selectedTab = .library }
                .keyboardShortcut("3", modifiers: .command)
        }
    }
}

#endif
