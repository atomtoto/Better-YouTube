import AppIntents
import Foundation

// MARK: - Shortcuts, Siri and Spotlight
//
// What the app can do without being opened first. Each action shows up in the Shortcuts app, can
// be asked of Siri by the phrases at the bottom, and is offered by Spotlight when you type the
// app's name. They all bring the app forward: every one of them ends in something to watch.

/// Opens a YouTube link — a video, a channel, a playlist — in the app.
///
/// The way into the app from Safari or the YouTube app: a shortcut built on this, with "Show in
/// Share Sheet" turned on, sends whatever is being shared here. A share extension can't do it, as
/// one may not open its app.
struct OpenYouTubeLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Open YouTube Link"
    static let description = IntentDescription("Opens a YouTube video, channel or playlist link in Better YouTube.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Link")
    var url: URL

    @MainActor
    func perform() async throws -> some IntentResult {
        guard AppRouter.shared.open(url) else {
            throw ShortcutError.notYouTube
        }
        return .result()
    }
}

/// Searches YouTube in the app — what Siri and Spotlight use for "search Better YouTube for…".
struct SearchYouTubeIntent: ShowInAppSearchResultsIntent {
    static let title: LocalizedStringResource = "Search YouTube"
    static let description = IntentDescription("Opens Better YouTube's search on the words you give.")
    static let searchScopes: [StringSearchScope] = [.general]

    @Parameter(title: "Search Term")
    var criteria: StringSearchCriteria

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.search(criteria.term)
        return .result()
    }
}

/// The video you were last watching, from where you stopped.
struct ResumeWatchingIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Watching"
    static let description = IntentDescription("Plays the video you watched last, from where you stopped.")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let video = LibraryStore.shared.history.first else {
            throw ShortcutError.nothingWatched
        }
        // With no start time given, the player picks up from the saved position by itself.
        PlayerManager.shared.play(video)
        return .result()
    }
}

/// One of the lists in Library.
enum LibraryList: String, AppEnum {
    case watchLater, favorites, history

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Library List"
    static let caseDisplayRepresentations: [LibraryList: DisplayRepresentation] = [
        .watchLater: "Watch Later",
        .favorites: "Favorites",
        .history: "History",
    ]
}

/// Plays a whole Library list, in order or shuffled.
struct PlayLibraryListIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Library List"
    static let description = IntentDescription("Plays your Watch Later, Favorites or History, in order or shuffled.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "List", default: .watchLater)
    var list: LibraryList

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$list)") {
            \.$shuffle
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        var videos: [Video]
        switch list {
        case .watchLater:
            let store = WatchLaterStore.shared
            // The account's own list is read on demand; a cold launch may not have it yet.
            if store.isSynced, store.entries.isEmpty { await store.refresh() }
            videos = store.videos
        case .favorites:
            videos = LibraryStore.shared.favorites
        case .history:
            videos = LibraryStore.shared.history
        }
        if shuffle { videos.shuffle() }
        guard let first = videos.first else {
            throw ShortcutError.emptyList
        }
        PlayerManager.shared.play(first, upNext: Array(videos.dropFirst()))
        return .result()
    }
}

enum ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case notYouTube
    case nothingWatched
    case emptyList

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notYouTube: "That isn't a link to a YouTube video, channel or playlist."
        case .nothingWatched: "You haven't watched anything yet."
        case .emptyList: "That list is empty."
        }
    }
}

/// The phrases Siri knows without any setup, and what Spotlight shows under the app's name.
/// Every phrase has to name the app; French ones are in `AppShortcuts.xcstrings`.
struct BetterYouTubeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumeWatchingIntent(),
            phrases: [
                "Resume watching in \(.applicationName)",
                "Continue my video in \(.applicationName)",
            ],
            shortTitle: "Resume Watching",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PlayLibraryListIntent(),
            phrases: [
                "Play my \(\.$list) in \(.applicationName)",
                "Play \(\.$list) in \(.applicationName)",
            ],
            shortTitle: "Play from Library",
            systemImageName: "play.square.stack"
        )
        AppShortcut(
            intent: SearchYouTubeIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search in \(.applicationName)",
            ],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenYouTubeLinkIntent(),
            phrases: [
                "Open a link in \(.applicationName)",
            ],
            shortTitle: "Open Link",
            systemImageName: "link"
        )
    }
}
