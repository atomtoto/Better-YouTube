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
    /// Where the tab bar's row starts, in window coordinates. A tab's content is the one place
    /// that knows: its bottom safe area is the tab bar plus the home indicator.
    @State private var tabBarTop = CGFloat.infinity
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
        // Shrink the floating tab bar as you scroll down, the way Apple's own apps do; a flick
        // back up restores it. The player bar above it follows it, see
        // `TabBarMinimizationWatcher`.
        .tabBarMinimizeBehavior(.onScrollDown)
        // Touching the shrunk tab bar brings it back without any scroll, which the player bar
        // has no other way to hear about when the tab bar's state can't be read. See
        // `PassiveTap` for why it isn't a SwiftUI gesture.
        .gesture(PassiveTap { location in
            if location.y >= tabBarTop { player.tabBarWasTouched() }
        })
    }

    /// A section's screen, measuring where the tab bar's row starts on the way.
    private func tab(_ tab: AppRouter.Tab) -> some View {
        screen(for: tab)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .global).maxY - proxy.safeAreaInsets.bottom
            } action: { top in
                tabBarTop = top
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

#if os(iOS)
/// Whether the floating tab bar is minimized, read off the tab bar itself.
///
/// `tabBarMinimizeBehavior` decides when the tab bar minimizes and restores on rules of its own —
/// a flick upwards brings it back, a slow drag doesn't, not even all the way to the top — and no
/// API reports the outcome. The tab bar's views show it, though: minimizing reveals the button it
/// shrinks to, restoring reveals the full bar, and both happen as its animation starts. Watching
/// those two is what lets the docked player move with it.
///
/// They are UIKit's own views, found by class name. If an iOS update lays the tab bar out
/// differently, or the tab bar isn't along the bottom, `isMinimized()` answers `nil` and the
/// player falls back to following the scroll.
@MainActor
final class TabBarMinimizationWatcher {
    private let onChange: (Bool) -> Void
    private var minimized: Bool?
    /// The full bar and the button it minimizes to. They are rebuilt along with the tab view, so
    /// they are found again whenever they leave the window.
    private weak var fullBar: UIView?
    private weak var minimizedButton: UIView?
    private var observations: [NSKeyValueObservation] = []
    /// Looking for the tab bar walks the whole window, so a search that came up empty waits a
    /// moment before it is tried again — `isMinimized()` is asked on every frame of a scroll.
    private var nextSearch = Date.distantPast

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    /// The tab bar's state, or `nil` when it can't be read.
    func isMinimized() -> Bool? {
        if fullBar?.window == nil || minimizedButton?.window == nil {
            attach()
        }
        return minimized
    }

    private func attach() {
        observations = []
        minimized = nil
        guard Date() >= nextSearch else { return }
        nextSearch = Date().addingTimeInterval(1)

        guard let tabBar = Self.bottomTabBar(),
              let fullBar = tabBar.subviews.first(where: { Self.isView($0, named: "_UITabBarItemPlatterView") }),
              let minimizedButton = tabBar.subviews.first(where: { Self.isView($0, named: "_UITabBarPlatterView") })
        else { return }

        self.fullBar = fullBar
        self.minimizedButton = minimizedButton
        minimized = fullBar.isHidden
        // Each view is shown as the tab bar starts moving towards it, and the other is hidden
        // only once it gets there, so it is the one appearing that says where it is going.
        observations = [
            minimizedButton.layer.observe(\.isHidden) { [weak self] layer, _ in
                guard !layer.isHidden else { return }
                MainActor.assumeIsolated { self?.update(minimized: true) }
            },
            fullBar.layer.observe(\.isHidden) { [weak self] layer, _ in
                guard !layer.isHidden else { return }
                MainActor.assumeIsolated { self?.update(minimized: false) }
            },
        ]
    }

    private func update(minimized: Bool) {
        guard self.minimized != minimized else { return }
        self.minimized = minimized
        onChange(minimized)
    }

    /// The app's tab bar, if it runs along the bottom of its window — the only place it
    /// minimizes, and the only place the docked player sits beside it.
    private static func bottomTabBar() -> UITabBar? {
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows {
                guard let tabBar = firstTabBar(in: window) else { continue }
                let frame = tabBar.convert(tabBar.bounds, to: window)
                if frame.maxY >= window.bounds.maxY - 1 { return tabBar }
            }
        }
        return nil
    }

    private static func firstTabBar(in view: UIView) -> UITabBar? {
        if let tabBar = view as? UITabBar { return tabBar }
        for subview in view.subviews {
            if let tabBar = firstTabBar(in: subview) { return tabBar }
        }
        return nil
    }

    private static func isView(_ view: UIView, named name: String) -> Bool {
        // Without the module prefix `NSStringFromClass` adds ("UIKit._UITabBarPlatterView").
        String(describing: type(of: view)) == name
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
