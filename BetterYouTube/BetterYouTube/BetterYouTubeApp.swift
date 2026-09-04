import SwiftUI

@main
struct BetterYouTubeApp: App {
    @StateObject private var apiKeyStore = APIKeyStore.shared
    @StateObject private var library = LibraryStore.shared

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(apiKeyStore)
                .environmentObject(library)
        }
    }
}
