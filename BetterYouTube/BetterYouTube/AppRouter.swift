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

    private init() {}

    func open(videoId: String) {
        selectedTab = .home
        pendingVideoId = videoId
    }

    func push(_ video: Video) {
        selectedTab = .home
        homePath.append(video)
    }

    /// Handles a `betteryoutube://` link. Returns false for anything it doesn't recognise, so
    /// the caller can leave other schemes alone.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let link = DownloadConfigLink(url: url) else { return false }
        pendingDownloadConfig = link
        return true
    }
}
