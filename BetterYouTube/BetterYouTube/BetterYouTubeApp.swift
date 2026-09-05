import SwiftUI

@main
struct BetterYouTubeApp: App {
    @StateObject private var apiKeyStore = APIKeyStore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var auth = GoogleAuthService.shared
    @StateObject private var recentSearches = RecentSearchStore.shared

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(apiKeyStore)
                .environmentObject(library)
                .environmentObject(auth)
                .environmentObject(recentSearches)
                .tint(.red)
        }
    }
}
