import Foundation

/// Puts the app back to how it was before anything was typed into it.
///
/// Gathered in one place on purpose. The app's state is spread across four kinds of storage — a
/// couple of JSON files in Documents, a handful of `UserDefaults` keys, the keychain, and the web
/// session's own cookie store — and a reset that clears three of the four is worse than none at
/// all, because what survives is invisible. Anything new that persists belongs on this list.
@MainActor
enum AppReset {
    /// Everything: both sign-ins, the API key, the on-device library, notifications, the quota
    /// tally and the search history.
    static func eraseEverything() async {
        // Stop playback first — it holds the audio session and a video that's about to have no
        // history entry to belong to.
        PlayerManager.shared.close()

        // The two sign-ins. The web session's cookies live in a data store of their own, which
        // is why this one is async.
        GoogleAuthService.shared.signOut()
        GoogleAuthService.shared.clientId = ""
        await YouTubeWebSession.shared.signOut()
        YouTubeWebSession.shared.rendering = .nativeCards

        // The account-backed caches, which belong to a sign-in that is now gone.
        WatchLaterStore.shared.reset()

        // Everything kept on the device.
        LibraryStore.shared.eraseEverything()
        NotificationStore.shared.eraseEverything()
        RecentSearchStore.shared.clear()
        QuotaTracker.shared.reset()
        APIKeyStore.shared.apiKey = ""

        // Pending banners refer to videos the app no longer knows anything about.
        NotificationService.shared.cancelAll()
        await NotificationService.shared.updateBadge()
    }
}
