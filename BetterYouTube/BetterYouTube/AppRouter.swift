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

    private init() {}

    func open(videoId: String) {
        selectedTab = .home
        pendingVideoId = videoId
    }

    func push(_ video: Video) {
        selectedTab = .home
        homePath.append(video)
    }
}
