import SwiftUI

/// Settings, as one scrolling screen.
///
/// This is the phone's shape and the iPad's: a `Form` with every section in it, reached from the
/// tab bar. A Mac gets the same sections in a window of panes instead — see `MacSettingsWindow` —
/// which is why each section is a view of its own rather than a property of this one. Nothing
/// here knows the order it will be shown in or what else is on screen with it.
struct SettingsView: View {
    /// Every section keeps its own drafts and result banners, and an app reset makes all of them
    /// stale at once. Rather than have the reset reach into each, the screen is rebuilt — see
    /// `AppResetSignal`.
    @ObservedObject private var reset = AppResetSignal.shared

    var body: some View {
        Form {
            AccountSection()
            WatchLaterSection()
            NotificationsSection()
            APIKeySection()
            QuotaSection()
            YouTubeHomeSection()
            DownloadsSection()
            OnThisDeviceSection()
            ResetSection()
            AboutSection()
        }
        .id(reset.generation)
        .settingsFormStyle()
        .minimizesPlayerBarOnScroll()
        .navigationTitle("Settings")
    }
}

/// "Open Settings", from wherever a screen has to send someone there.
///
/// On a phone that is a push onto the current navigation stack. On a Mac, Settings is a window of
/// its own, so `SettingsLink` opens that instead of pushing a settings screen into the Library.
struct OpenSettingsButton: View {
    var title = "Open Settings"

    var body: some View {
        #if os(macOS)
        SettingsLink {
            Text(title).font(.subheadline.weight(.semibold))
        }
        #else
        NavigationLink {
            SettingsView()
        } label: {
            Text(title).font(.subheadline.weight(.semibold))
        }
        #endif
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environmentObject(APIKeyStore.shared)
        .environmentObject(LibraryStore.shared)
        .environmentObject(WatchLaterStore.shared)
        .environmentObject(GoogleAuthService.shared)
        .environmentObject(NotificationStore.shared)
        .environmentObject(NotificationService.shared)
        .environmentObject(QuotaTracker.shared)
        .environmentObject(YouTubeWebSession.shared)
        .environmentObject(DownloadStore.shared)
        .environmentObject(DownloadManager.shared)
        .environmentObject(DownloadSettings.shared)
}
