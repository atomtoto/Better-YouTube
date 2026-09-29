import SwiftUI

@main
struct BetterYouTubeWatchApp: App {
    @StateObject private var bridge = WatchBridge.shared
    @StateObject private var downloads = WatchDownloads.shared
    @StateObject private var player = WatchPlayer.shared
    @StateObject private var accountLibrary = WatchAccountLibraryStore.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(bridge)
                .environmentObject(downloads)
                .environmentObject(player)
                .environmentObject(accountLibrary)
                .tint(.red)
                .task { bridge.start() }
        }
    }
}
