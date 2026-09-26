import SwiftUI

struct RootTabView: View {
    @ObservedObject private var reset = AppResetSignal.shared
    @EnvironmentObject private var apiKeyStore: APIKeyStore
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var notificationStore: NotificationStore
    @EnvironmentObject private var player: PlayerManager
    @State private var showsOnboarding = false
    @AppStorage(OnboardingProgress.startedKey) private var hasStartedOnboarding = false
    @AppStorage(OnboardingProgress.completedKey) private var hasCompletedOnboarding = false
    #if os(iOS)
    @AppStorage(SettingsTabPreference.storageKey) private var showsSettingsTab = false
    #endif

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
        .onAppear {
            presentOnboardingIfNeeded()
        }
        .onChange(of: reset.generation) { _, _ in
            hasStartedOnboarding = true
            hasCompletedOnboarding = false
            showsOnboarding = true
        }
        .task(id: router.pendingVideoId) {
            guard let videoId = router.pendingVideoId else { return }
            router.pendingVideoId = nil
            await player.open(videoId: videoId)
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
                .tabItem { Label("Library", systemImage: "tray.full.fill") }
                .tag(AppRouter.Tab.library)

            if showsSettingsTab {
                screen(for: .settings)
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                    .tag(AppRouter.Tab.settings)
            }
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

enum OnboardingProgress {
    static let startedKey = "onboarding_started"
    static let completedKey = "onboarding_completed"
}

/// First-run setup. Each screen has one decision so the Cloud Console instructions, credential
/// entry, and optional website session never compete for space on a phone.
private struct OnboardingView: View {
    @EnvironmentObject private var apiKeyStore: APIKeyStore
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var webSession: YouTubeWebSession
    let onFinish: () -> Void

    private enum Step: Equatable { case welcome, cloud, google, apiKey, home }
    @State private var step: Step = .welcome
    @State private var previousConnectionStep: Step = .google
    @State private var apiKeyDraft = ""
    @State private var showsYouTubeSignIn = false
    @State private var isSigningIn = false
    @State private var authError: String?
    @State private var copiedBundleID = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    progress
                    heading
                    pageContent
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .id(step)
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step != .welcome {
                        Button("Back", systemImage: "chevron.left", action: goBack)
                            .disabled(isSigningIn)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if step != .home {
                        Button("Set Up Later", action: onFinish)
                            .disabled(isSigningIn)
                    }
                }
            }
            .sheet(isPresented: $showsYouTubeSignIn) {
                YouTubeSignInView()
            }
            .onAppear {
                if auth.isSignedIn {
                    previousConnectionStep = .google
                    step = .home
                } else if apiKeyStore.hasKey {
                    previousConnectionStep = .apiKey
                    step = .home
                }
            }
        }
    }

    private var progress: some View {
        HStack(spacing: 7) {
            ForEach(0..<4) { index in
                Capsule()
                    .fill(index <= progressIndex ? Color.accentColor : Color.appTertiaryFill)
                    .frame(height: 5)
            }
        }
        .accessibilityLabel("Setup step \(progressIndex + 1) of 4")
    }

    private var progressIndex: Int {
        switch step {
        case .welcome: 0
        case .cloud: 1
        case .google, .apiKey: 2
        case .home: 3
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: stepIcon)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 62, height: 62)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
            Text(stepTitle)
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(stepSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepIcon: String {
        switch step {
        case .welcome: "play.rectangle.fill"
        case .cloud: "checklist"
        case .google: "person.crop.circle.fill"
        case .apiKey: "key.fill"
        case .home: "house.fill"
        }
    }

    private var stepTitle: String {
        switch step {
        case .welcome: "Welcome to Better YouTube"
        case .cloud: "Prepare Google Cloud"
        case .google: "Connect your Google account"
        case .apiKey: "Use an API key"
        case .home: "Bring in your YouTube Home"
        }
    }

    private var stepSubtitle: String {
        switch step {
        case .welcome: "A calmer way to browse. Set up access in a few short steps."
        case .cloud: "Enable the API and create an OAuth client in your Google Cloud project."
        case .google: "Paste your OAuth client ID, then sign in securely with Google."
        case .apiKey: "An optional way to browse public videos without signing in."
        case .home: "Connect youtube.com for your personalized Home feed and Watch Later."
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch step {
        case .welcome: welcomePage
        case .cloud: cloudPage
        case .google: googlePage
        case .apiKey: apiKeyPage
        case .home: homePage
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            feature("1", "Connect Google", "OAuth lets you browse and access your subscriptions, playlists and likes. No separate API key is needed.")
            feature("2", "Add YouTube Home", "A separate, optional youtube.com connection brings in your personal feed and Watch Later.")
            Text("You can also choose an API key for public videos, or finish setup later in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func feature(_ number: String, _ title: String, _ detail: String) -> some View {
        card {
            HStack(alignment: .top, spacing: 14) {
                Text(number)
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cloudPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose the same Google Cloud project on each linked page.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            setupLink("1", "Enable YouTube Data API v3", "Required for browsing and account features.", GoogleCloudSetupURL.youtubeDataAPI)
            setupLink("2", "Create an OAuth client ID", "Choose the iOS application type, including on a Mac.", GoogleCloudSetupURL.oauthClients)
            card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use this bundle ID").font(.headline)
                    HStack(spacing: 10) {
                        Text(bundleID)
                            .font(.subheadline.monospaced())
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button(copiedBundleID ? "Copied" : "Copy", systemImage: copiedBundleID ? "checkmark" : "doc.on.doc") {
                            Platform.copyToPasteboard(bundleID)
                            copiedBundleID = true
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Paste it into the OAuth client's Bundle ID field.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            setupLink("3", "Add yourself as a test user", "Needed while the OAuth consent screen is in Testing.", GoogleCloudSetupURL.oauthAudience)
        }
    }

    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.atomtoto.BetterYouTube"
    }

    private func setupLink(_ number: String, _ title: String, _ detail: String, _ url: URL) -> some View {
        Link(destination: url) {
            card {
                HStack(alignment: .top, spacing: 14) {
                    Text(number)
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        ExternalLinkLabel(title).font(.headline)
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private var googlePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("OAuth client ID").font(.headline)
                    TextField("Paste your client ID", text: $auth.clientId)
                        .identifierField()
                        .textFieldStyle(.plain)
                        .padding(14)
                        .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 12))
                        .onChange(of: auth.clientId) { _, _ in authError = nil }
                    if let inputError = auth.clientIdInputError,
                       case .clientIdIsURL = inputError {
                        Text(inputError.localizedDescription)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Text("It ends in .apps.googleusercontent.com. You can find it under Google Cloud → Clients.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if auth.isSignedIn {
                Label("Connected with Google", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("On Google's consent screen, select the YouTube permission before continuing.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let authError {
                Label(authError, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Link(destination: GoogleCloudSetupURL.oauthClients) {
                ExternalLinkLabel("Find your OAuth client ID")
            }
            .font(.subheadline)
        }
    }

    private var apiKeyPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            setupLink("1", "Enable YouTube Data API v3", "Choose your Google Cloud project first.", GoogleCloudSetupURL.youtubeDataAPI)
            setupLink("2", "Create an API key", "Find it under APIs & Services → Credentials.", GoogleCloudSetupURL.apiCredentials)
            card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("API key").font(.headline)
                    TextField("Paste your API key", text: $apiKeyDraft)
                        .identifierField()
                        .textFieldStyle(.plain)
                        .padding(14)
                        .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 12))
                    Text("You can add OAuth later in Settings for subscriptions, playlists and likes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var homePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Your own YouTube feed", systemImage: "sparkles.tv")
                        .font(.headline)
                    Text("Sign in to youtube.com to see your personalized Home and YouTube Watch Later playlist here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if webSession.isSignedIn {
                Label("Connected to youtube.com", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("This website connection is separate from Google OAuth. Use the same Google account when YouTube asks you to sign in.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("YouTube Home reads the website outside the official API and may need attention if YouTube changes its pages.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .cardBackground(cornerRadius: 20)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            switch step {
            case .welcome:
                primaryButton("Set Up Google", icon: "arrow.right") { step = .cloud }
                secondaryButton("Use an API key instead") { step = .apiKey }
            case .cloud:
                primaryButton("I Have My OAuth Client ID", icon: "arrow.right") { step = .google }
            case .google:
                if auth.isSignedIn {
                    primaryButton("Continue to YouTube Home", icon: "arrow.right") {
                        previousConnectionStep = .google
                        step = .home
                    }
                } else {
                    Button(action: signIn) {
                        HStack(spacing: 10) {
                            if isSigningIn { ProgressView().controlSize(.small) }
                            Text("Sign in with Google")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isSigningIn || auth.redirectScheme == nil)
                }
            case .apiKey:
                primaryButton("Continue with API Key", icon: "arrow.right") {
                    apiKeyStore.apiKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    previousConnectionStep = .apiKey
                    step = .home
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .home:
                if webSession.isSignedIn {
                    primaryButton("Start Using Better YouTube", icon: "checkmark", action: onFinish)
                } else {
                    primaryButton("Connect YouTube Home", icon: "arrow.right") { showsYouTubeSignIn = true }
                    secondaryButton("Continue Without YouTube Home", action: onFinish)
                }
            }
        }
        .frame(maxWidth: 512)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private func primaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Image(systemName: icon)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private func goBack() {
        switch step {
        case .welcome: break
        case .cloud, .apiKey: step = .welcome
        case .google: step = .cloud
        case .home: step = previousConnectionStep
        }
    }

    private func signIn() {
        isSigningIn = true
        authError = nil
        Task {
            do {
                try await auth.signIn()
                previousConnectionStep = .google
                step = .home
            } catch {
                authError = error.localizedDescription
            }
            isSigningIn = false
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
