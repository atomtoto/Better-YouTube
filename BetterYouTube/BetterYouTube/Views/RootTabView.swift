import SwiftUI

struct RootTabView: View {
    @ObservedObject private var reset = AppResetSignal.shared
    @ObservedObject private var demo = DemoMode.shared
    @EnvironmentObject private var apiKeyStore: APIKeyStore
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var notificationStore: NotificationStore
    @EnvironmentObject private var player: PlayerManager
    /// Search's state, held here so links and Siri can run a search, leaving the search tab can put
    /// its field away, and a search survives switching sections on a Mac.
    @StateObject private var search = SearchViewModel()
    @State private var showsOnboarding = false
    @AppStorage(OnboardingProgress.startedKey) private var hasStartedOnboarding = false
    @AppStorage(OnboardingProgress.completedKey) private var hasCompletedOnboarding = false
    #if os(iOS)
    @AppStorage(SettingsTabPreference.storageKey) private var showsSettingsTab = false
    @AppStorage(SearchTabPreference.storageKey) private var searchInTabBar = false
    /// The tab bar's row, in window coordinates. A tab's content is the one place that knows:
    /// its bottom safe area is the tab bar plus the home indicator.
    @State private var tabBarRow = CGRect.null
    #endif

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                #if os(macOS)
                sidebarSections
                #else
                tabs
                #endif
            }
            // Every screen starts over when a demo begins or ends: what they hold in memory
            // belongs to the library and account being swapped out.
            .id(demo.isActive)
            // Lives above every tab so playback survives navigation and tab switches. It keeps
            // its place when the keyboard comes up — in Search, that means the keyboard covers
            // it rather than shoving it up the screen.
            PlayerContainerView()
                .ignoresKeyboardInset()
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView {
                hasCompletedOnboarding = true
                showsOnboarding = false
            }
            .interactiveDismissDisabled()
        }
        .sheet(item: $router.pendingDownloadConfig) { link in
            DownloadConfigImportView(link: link)
        }
        .onOpenURL { url in
            router.open(url)
        }
        .handsOffPlayback(player)
        .onAppear {
            presentOnboardingIfNeeded()
        }
        .onChange(of: router.selectedTab) { _, tab in
            if tab != .search { search.isPresented = false }
        }
        .onChange(of: demo.isActive) { _, active in
            search.clear()
            router.homePath = NavigationPath()
            if active { showsOnboarding = false }
        }
        // Ending a demo with nothing set up brings the welcome back.
        .onChange(of: hasCompletedOnboarding) { _, completed in
            if !completed { presentOnboardingIfNeeded() }
        }
        .onChange(of: reset.generation) { _, _ in
            hasStartedOnboarding = true
            hasCompletedOnboarding = false
            showsOnboarding = true
        }
        // Cleared, then followed in a task of its own. A `.task(id:)` here cancelled itself:
        // clearing the request changes the id, SwiftUI cancels the running task, and the
        // lookup it was waiting on failed as cancelled — a tapped notification opened nothing.
        .onChange(of: router.pendingLink, initial: true) { _, link in
            guard let link else { return }
            router.pendingLink = nil
            Task { await router.follow(link) }
        }
        .onChange(of: router.pendingSearch, initial: true) { _, term in
            guard let term else { return }
            router.pendingSearch = nil
            search.search(term: term)
        }
        .alert("Couldn't Open Link", isPresented: Binding(
            get: { router.linkError != nil },
            set: { if !$0 { router.linkError = nil } }
        )) {
            Button("OK", role: .cancel) { router.linkError = nil }
        } message: {
            Text(router.linkError ?? "")
        }
        .onChange(of: router.pendingVideoId, initial: true) { _, videoId in
            guard let videoId else { return }
            router.pendingVideoId = nil
            // A tapped notification is in the inbox, which already knows the title and channel.
            let known = notificationStore.items.first { $0.videoId == videoId }?.video
            Task { await player.open(videoId: videoId, fallback: known) }
        }
        #if os(iOS)
        .onChange(of: showsSettingsTab) { _, visible in
            if !visible && router.selectedTab == .settings {
                router.selectedTab = .library
            }
        }
        #endif
    }

    private func presentOnboardingIfNeeded() {
        guard !hasCompletedOnboarding else { return }
        // Existing installs already configured with a key or OAuth should not see a new
        // welcome screen after updating. An unfinished first-run flow should resume.
        if !hasStartedOnboarding && (apiKeyStore.hasKey || auth.isSignedIn) {
            hasCompletedOnboarding = true
            return
        }
        hasStartedOnboarding = true
        showsOnboarding = true
    }

    /// Whichever section is selected, in its own navigation stack. Shared by both shapes below,
    /// so a screen never has to know whether it was reached from a tab or from a sidebar row.
    @ViewBuilder
    private func screen(for tab: AppRouter.Tab) -> some View {
        switch tab {
        case .home:
            NavigationStack(path: $router.homePath) { HomeView() }
        case .search:
            NavigationStack { SearchView(viewModel: search) }
                #if os(iOS)
                // Rebuilt when its field moves between the bottom and the title: moved in place,
                // the field under the title was drawn without its capsule.
                .id(searchInTabBar)
                #endif
        case .library:
            NavigationStack { LibraryView() }
        case .settings:
            NavigationStack { SettingsView() }
        }
    }

#if os(iOS)

    private var tabs: some View {
        TabView(selection: $router.selectedTab) {
            Tab("Home", systemImage: "play.circle.fill", value: AppRouter.Tab.home) {
                tab(.home)
            }
            .badge(notificationStore.unreadCount)

            // By default the search role lifts Search out of the bar into a button of its own at
            // the end, which turns into the search field along the bottom when selected — in
            // thumb reach, like the field this app used to draw itself. Settings can put it back
            // in the bar as an ordinary tab, with its field under the title. See `SearchView`.
            Tab("Search", systemImage: "magnifyingglass", value: AppRouter.Tab.search,
                role: searchInTabBar ? nil : .search) {
                tab(.search)
            }

            Tab("Library", systemImage: "tray.full.fill", value: AppRouter.Tab.library) {
                tab(.library)
            }

            if showsSettingsTab {
                Tab("Settings", systemImage: "gearshape.fill", value: AppRouter.Tab.settings) {
                    tab(.settings)
                }
            }
        }
        // Lifts the search tab out of the bar and turns it into the field along the bottom.
        .tabViewSearchActivation(searchInTabBar ? .automatic : .searchTabSelection)
        // Shrink the floating tab bar as you scroll down, the way Apple's own apps do — it
        // comes back at the top of the scroll, not on the first flick upwards. The player bar
        // above it follows the same rule, see `minimizesPlayerBarOnScroll`.
        .tabBarMinimizeBehavior(.onScrollDown)
        // Touching the shrunk tab bar brings it back without any scroll, which the player bar
        // has no other way to hear about. Only its button does that: the rest of the row is the
        // pill, Search's button and the content between them, none of which grow the tab bar.
        // See `PassiveTap` for why it isn't a SwiftUI gesture.
        .gesture(PassiveTap { location in
            var button = tabBarRow
            button.size.width = MinimizedTabButton.extent
            if button.contains(location) { player.tabBarWasTouched() }
        })
    }

    /// A section's screen, measuring the tab bar's row on the way.
    private func tab(_ tab: AppRouter.Tab) -> some View {
        screen(for: tab)
            .onGeometryChange(for: CGRect.self) { proxy in
                // The frame already stops where the safe area starts, so the row is just below it.
                let frame = proxy.frame(in: .global)
                return CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: proxy.safeAreaInsets.bottom)
            } action: { row in
                tabBarRow = row
            }
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

#if os(iOS)
/// A tap anywhere, heard without taking the touch from whatever it lands on.
///
/// A SwiftUI tap gesture cancels the touches under it once it recognizes, and in a `List` or a
/// `Form` that cancelled the row's selection: with one across the whole tab view, no row in
/// Library or Settings could be opened, nor long-pressed. A UIKit recognizer can be told to
/// leave the touch alone, and to recognize alongside every other gesture.
private struct PassiveTap: UIGestureRecognizerRepresentable {
    /// Where the tap landed, in the window's coordinates.
    let action: (CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }
        action(context.converter.location(in: .global))
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif

enum OnboardingProgress {
    static let startedKey = "onboarding_started"
    static let completedKey = "onboarding_completed"
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
