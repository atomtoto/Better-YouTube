import Foundation
import SwiftUI

/// Owns cross-screen navigation so a tapped notification can open a video from anywhere.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    enum Tab: Hashable {
        case home, search, library, settings
    }

    @Published var selectedTab: Tab = .home
    @Published var homePath = NavigationPath()
    /// Set by a notification tap; Home resolves it to a video and pushes it.
    @Published var pendingVideoId: String?
    /// Set when a configuration link is opened. It is a *proposal*, not a setting: the root view
    /// puts it to the user, and nothing is saved unless they agree.
    @Published var pendingDownloadConfig: DownloadConfigLink?
    /// A YouTube link opened from outside the app — Shortcuts, another app, a `betteryoutube://`
    /// link. The root view follows it once the window is up.
    @Published var pendingLink: YouTubeLink?
    /// Why the last link couldn't be followed, for the root view to say.
    @Published var linkError: String?

    private init() {}

    func open(videoId: String) {
        selectedTab = .home
        pendingVideoId = videoId
    }

    func push(_ video: Video) {
        selectedTab = .home
        homePath.append(video)
    }

    /// Handles a `betteryoutube://` link, or a YouTube one. Returns false for anything it doesn't
    /// recognise, so the caller can leave other schemes alone.
    @discardableResult
    func open(_ url: URL) -> Bool {
        if let link = DownloadConfigLink(url: url) {
            pendingDownloadConfig = link
            return true
        }
        if let link = YouTubeLink(url: url) {
            pendingLink = link
            return true
        }
        return false
    }

    /// Takes a link to what it names: a video plays, a channel or playlist opens in Home.
    func follow(_ link: YouTubeLink) async {
        switch link {
        case .video(let id, let start):
            await PlayerManager.shared.open(videoId: id, startTime: start)
        case .playlist(let id):
            show(Playlist(id: id, title: "", description: "", thumbnailURL: nil))
        case .channel(let id):
            show(Channel(id: id, title: "", description: "", thumbnailURL: nil))
        case .handle(let handle):
            do {
                guard let channel = try await YouTubeAPIService.shared.channel(handle: handle) else {
                    linkError = String(localized: "YouTube has no channel called \(handle).")
                    return
                }
                show(channel)
            } catch {
                linkError = error.localizedDescription
            }
        }
    }

    /// Pushes a page onto Home, out from under the player if it is open.
    private func show<Destination: Hashable>(_ destination: Destination) {
        PlayerManager.shared.collapse()
        selectedTab = .home
        homePath.append(destination)
    }
}
