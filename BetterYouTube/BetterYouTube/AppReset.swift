import Foundation

/// Puts the app back to how it was before anything was typed into it.
///
/// Gathered in one place on purpose. The app's state is spread across five kinds of storage — a
/// couple of JSON files in Documents, the Downloads folder beside them, a handful of `UserDefaults`
/// keys, the keychain, and the web session's own cookie store — and a reset that clears four of
/// the five is worse than none at all, because what survives is invisible. Anything new that
/// persists belongs on this list.
/// Says that an erase happened, and nothing else.
///
/// Screens don't only hold what is on disk — Settings holds a draft per text field and a result
/// banner per action, none of which the stores know about. While all of those lived in one type
/// the reset could clear them by hand, and that stopped being true the moment the sections moved
/// into files of their own.
///
/// So a screen holding state of its own keys itself on this counter and is rebuilt from the
/// stores, which by the time it is bumped are empty. See `SettingsView` and `MacSettingsWindow`.
///
/// Deliberately *not* `@MainActor`: a view holds this as a plain `@ObservedObject` default value,
/// and an isolated singleton read from a nonisolated initializer is a Swift 6 error in waiting.
/// Only `AppReset` writes to it, and `AppReset` is on the main actor.
final class AppResetSignal: ObservableObject {
    static let shared = AppResetSignal()

    @Published fileprivate(set) var generation = 0

    private init() {}
}

@MainActor
enum AppReset {
    /// Everything: both sign-ins, the API key, the on-device library, the Downloads folder,
    /// notifications, the quota tally and the search history.
    static func eraseEverything() async {
        // Stop playback first — it holds the audio session and a video that's about to have no
        // history entry to belong to.
        PlayerManager.shared.close()
        UserDefaults.standard.removeObject(forKey: MiniPlayerStyle.storageKey)

        // The two sign-ins. The web session's cookies live in a data store of their own, which
        // is why this one is async.
        GoogleAuthService.shared.signOut()
        GoogleAuthService.shared.clientId = ""
        await YouTubeWebSession.shared.signOut()
        YouTubeWebSession.shared.rendering = .nativeCards

        // The account-backed caches, which belong to a sign-in that is now gone.
        WatchLaterStore.shared.reset()

        // Everything kept on the device. Downloads go first and as one step: the manager has to
        // stop its transfers before the folder is removed, or a background task iOS is still
        // running writes the file straight back after the delete.
        DownloadManager.shared.removeAll()
        DownloadSettings.shared.backend = .local
        DownloadSettings.shared.endpoint = ""
        DownloadSettings.shared.token = ""

        LibraryStore.shared.eraseEverything()
        NotificationStore.shared.eraseEverything()
        RecentSearchStore.shared.clear()
        QuotaTracker.shared.reset()
        APIKeyStore.shared.apiKey = ""

        // Pending banners refer to videos the app no longer knows anything about.
        NotificationService.shared.cancelAll()
        await NotificationService.shared.updateBadge()

        // Last, so nothing is rebuilt from a store that hasn't been cleared yet.
        AppResetSignal.shared.generation += 1
    }
}
