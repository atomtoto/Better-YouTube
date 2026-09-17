import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var apiKeyStore: APIKeyStore
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var notificationStore: NotificationStore
    @EnvironmentObject private var player: PlayerManager
    @State private var showsOnboarding = false

    var body: some View {
        ZStack(alignment: .bottom) {
            #if os(macOS)
            sidebarSections
            #else
            tabs
            #endif
            // Lives above every tab so playback survives navigation and tab switches. It keeps
            // its place when the keyboard comes up — in Search, that means the keyboard covers
            // it rather than shoving it up the screen.
            PlayerContainerView()
                .ignoresKeyboardInset()
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView()
        }
        .sheet(item: $router.pendingDownloadConfig) { link in
            DownloadConfigImportView(link: link)
        }
        .onOpenURL { url in
            router.open(url)
        }
        .onAppear {
            showsOnboarding = !apiKeyStore.hasKey && !auth.isSignedIn
        }
        .task(id: router.pendingVideoId) {
            guard let videoId = router.pendingVideoId else { return }
            router.pendingVideoId = nil
            await player.open(videoId: videoId)
        }
    }

    /// Whichever section is selected, in its own navigation stack. Shared by both shapes below,
    /// so a screen never has to know whether it was reached from a tab or from a sidebar row.
    @ViewBuilder
    private func screen(for tab: AppRouter.Tab) -> some View {
        switch tab {
        case .home:
            NavigationStack(path: $router.homePath) { HomeView() }
        case .search:
            NavigationStack { SearchView() }
        case .library:
            NavigationStack { LibraryView() }
        case .settings:
            NavigationStack { SettingsView() }
        }
    }

#if os(iOS)

    private var tabs: some View {
        TabView(selection: $router.selectedTab) {
            screen(for: .home)
                .tabItem { Label("Home", systemImage: "play.circle.fill") }
                .badge(notificationStore.unreadCount)
                .tag(AppRouter.Tab.home)

            screen(for: .search)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppRouter.Tab.search)

            screen(for: .library)
                .tabItem { Label("Library", systemImage: "rectangle.stack.badge.play.fill") }
                .tag(AppRouter.Tab.library)

            screen(for: .settings)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppRouter.Tab.settings)
        }
        // Shrink the floating tab bar as you scroll down, the way Apple's own apps do — it
        // comes back at the top of the scroll, not on the first flick upwards. The player bar
        // above it follows the same rule, see `minimizesPlayerBarOnScroll`.
        .tabBarMinimizeBehavior(.onScrollDown)
    }

#else

    /// The Mac's shape: the same four sections as a source list down the side.
    ///
    /// A `TabView` on macOS becomes a row of segments across the top of the window, which is a
    /// preferences pane rather than an app. A sidebar is where a Mac app of this shape — Music,
    /// Podcasts, TV — puts its sections, and it leaves the top of the window to the screen's own
    /// title and toolbar.
    private var sidebarSections: some View {
        NavigationSplitView {
            // A source list's selection is optional — clicking the empty space below the rows
            // clears it — while the app always has a section open. Dropping the nil rather than
            // acting on it is what keeps those two facts from disagreeing.
            List(selection: Binding(
                get: { Optional(router.selectedTab) },
                set: { if let tab = $0 { router.selectedTab = tab } }
            )) {
                Label("Home", systemImage: "play.circle.fill")
                    .badge(notificationStore.unreadCount)
                    .tag(AppRouter.Tab.home)
                Label("Search", systemImage: "magnifyingglass")
                    .tag(AppRouter.Tab.search)
                Label("Library", systemImage: "rectangle.stack.badge.play.fill")
                    .tag(AppRouter.Tab.library)
                // No Settings row: on a Mac it is a window, opened with ⌘, from the app menu
                // like every other Mac app's. See the `Settings` scene in `BetterYouTubeApp`.
            }
            .navigationSplitViewColumnWidth(min: 178, ideal: 205, max: 280)
        } detail: {
            screen(for: router.selectedTab)
        }
        // The docked player floats over the bottom of the window rather than sitting in a tab
        // bar's row, so the content underneath is given its height to keep clear of. Without
        // this the last row of every list hides behind the bar.
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: player.currentVideo == nil ? 0 : 84)
        }
    }

#endif
}

/// First-run screen explaining the two ways to authenticate against the YouTube API.
private struct OnboardingView: View {
    @EnvironmentObject private var apiKeyStore: APIKeyStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 12) {
                        Image(systemName: "play.rectangle.on.rectangle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.red)
                        Text("Welcome to Better YouTube")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                        Text("A calmer way to browse YouTube, built on the official Data API.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 32)

                    VStack(spacing: 16) {
                        FeatureRow(
                            icon: "key.fill",
                            title: "Add an API key",
                            detail: "Enable the YouTube Data API v3 in the Google Cloud Console and create an API key."
                        )
                        FeatureRow(
                            icon: "person.crop.circle.fill",
                            title: "Sign in (optional)",
                            detail: "Connect your Google account in Settings to see your subscriptions, playlists and likes."
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("API key")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("Paste your key", text: $draft)
                            .identifierField()
                            // The field draws its own background below; without this macOS
                            // would put its bezel inside the rounded rectangle.
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.appSecondaryBackground)
                            )

                        Button {
                            apiKeyStore.apiKey = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            dismiss()
                        } label: {
                            Text("Continue")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
            }
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.red)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    RootTabView()
        .environmentObject(APIKeyStore.shared)
        .environmentObject(LibraryStore.shared)
        .environmentObject(WatchLaterStore.shared)
        .environmentObject(GoogleAuthService.shared)
        .environmentObject(RecentSearchStore.shared)
        .environmentObject(NotificationStore.shared)
        .environmentObject(NotificationService.shared)
        .environmentObject(AppRouter.shared)
        .environmentObject(PlayerManager.shared)
        .environmentObject(QuotaTracker.shared)
        .environmentObject(YouTubeWebSession.shared)
        .environmentObject(DownloadStore.shared)
        .environmentObject(DownloadManager.shared)
        .environmentObject(DownloadSettings.shared)
}
