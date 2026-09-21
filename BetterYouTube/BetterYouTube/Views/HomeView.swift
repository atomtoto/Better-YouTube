import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var notificationStore: NotificationStore
    @EnvironmentObject private var webSession: YouTubeWebSession
    @StateObject private var viewModel = HomeViewModel()
    @StateObject private var youTubeNavigation = YouTubeWebNavigationModel()

    @State private var showsNotifications = false

    /// YouTube's page in place of the app's cards: only on its own segment, and only when
    /// Settings asks for that rendering.
    private var showsYouTubePage: Bool {
        viewModel.feed == .youTube && webSession.rendering == .youTubePage
    }

    var body: some View {
        Group {
            if showsYouTubePage {
                // The page scrolls itself, so the picker sits above it rather than inside it.
                VStack(spacing: 12) {
                    feedPickerInContent
                    YouTubeWebFeedView(navigation: youTubeNavigation)
                }
                .padding(.top, 12)
            } else {
                cardFeed
            }
        }
        .background(Color.appBackground)
        .navigationTitle("Home")
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .principal) {
                // `fixedSize` because a segmented picker in a toolbar is given the whole width
                // otherwise, and hugs its titles with it.
                feedNavigationBar
                    .fixedSize()
            }

            // Pull-to-refresh below is the phone's affordance; a Mac needs somewhere to click.
            ToolbarItem(placement: .primaryAction) {
                RefreshButton { await refresh(force: true) }
            }
            #endif

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsNotifications = true
                } label: {
                    Image(systemName: notificationStore.unreadCount > 0 ? "bell.badge.fill" : "bell")
                        .symbolRenderingMode(notificationStore.unreadCount > 0 ? .multicolor : .monochrome)
                }
                .accessibilityLabel(
                    notificationStore.unreadCount > 0
                        ? "Notifications, \(notificationStore.unreadCount) unread"
                        : "Notifications"
                )
            }
        }
        .sheet(isPresented: $showsNotifications) {
            NotificationsView()
        }
        .navigationDestination(for: Channel.self) { ChannelView(channelId: $0.id, initialChannel: $0) }
        .refreshable { await refresh(force: true) }
        .onChange(of: webSession.isSignedIn, initial: true) { _, signedIn in
            viewModel.adoptDefaultFeed(webSignedIn: signedIn)
        }
        .onChange(of: webSession.feedGeneration) { _, _ in
            viewModel.adoptDefaultFeed(webSignedIn: webSession.isSignedIn)
        }
        .task(id: "\(viewModel.feed.rawValue)-\(webSession.rendering.rawValue)-\(webSession.hasCheckedSession)-\(webSession.isSignedIn)-\(webSession.feedGeneration)-\(auth.isSignedIn)") {
            guard webSession.hasCheckedSession else { return }
            if viewModel.feed == .youTube {
                if !showsYouTubePage { await viewModel.loadYouTubeFeed() }
            } else {
                await viewModel.load(isSignedIn: auth.isSignedIn, library: library)
            }
        }
    }

    /// Pull-to-refresh refreshes what you are looking at.
    private func refresh(force: Bool) async {
        if viewModel.feed == .youTube {
            await viewModel.loadYouTubeFeed(force: force)
        } else {
            await viewModel.load(isSignedIn: auth.isSignedIn, library: library, force: force)
        }
    }

    // MARK: Pieces

    /// The segmented control. YouTube's own feed is only on offer once there is a session to
    /// read it with — signed out of that, Home is exactly what it was before.
    ///
    /// It carries no margins of its own because the two platforms put it in different places: on
    /// a phone it scrolls with the feed, on a Mac it sits in the window's toolbar. See
    /// `feedPickerInContent` and the toolbar below.
    private var feedPicker: some View {
        Picker("Feed", selection: Binding(get: { viewModel.feed }, set: viewModel.select)) {
            ForEach(HomeViewModel.Feed.allCases) { feed in
                if feed != .youTube || webSession.isSignedIn {
                    Text(feed.title).tag(feed)
                }
            }
        }
        .pickerStyle(.segmented)
    }

    /// Safari-style history control immediately beside the feed tabs. It is present only while
    /// YouTube's live page is the selected feed, on both the in-content iPhone bar and the Mac
    /// toolbar bar.
    private var feedNavigationBar: some View {
        HStack(spacing: 8) {
            if showsYouTubePage {
                Button { youTubeNavigation.goBack() } label: {
                    Image(systemName: "chevron.backward")
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!youTubeNavigation.canGoBack)
                .accessibilityLabel("Back")
            }
            feedPicker
        }
    }

    /// The picker where it belongs *in the page*, which is nowhere on a Mac.
    ///
    /// A control that switches what the whole screen is showing belongs in the toolbar on macOS,
    /// not in the scroll view: in the content it scrolls away with the feed, and it reads as a
    /// row of tabs that has somehow ended up below the real title bar. A phone has no toolbar to
    /// put it in, and there the segmented control at the top of the feed is the native answer.
    @ViewBuilder
    private var feedPickerInContent: some View {
        #if os(iOS)
        feedNavigationBar
            .padding(.horizontal, Theme.Spacing.gutter)
        #endif
    }

    private var cardFeed: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                feedPickerInContent

                if isLoadingCurrentFeed && viewModel.videos.isEmpty {
                    placeholderFeed
                } else if viewModel.videos.isEmpty {
                    currentEmptyState
                        .padding(.top, 40)
                } else {
                    ForEach(viewModel.videos) { video in
                        Button {
                            player.play(video, upNext: viewModel.videos.after(video))
                        } label: {
                            FeedVideoCard(video: video, avatarURL: viewModel.avatar(for: video.channelId))
                        }
                        .buttonStyle(.plain)
                        .videoContextMenu(video)
                    }

                    if let note = feedSourceNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Spacing.gutter)
                            .padding(.top, 4)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        .minimizesPlayerBarOnScroll()
    }

    private var isLoadingCurrentFeed: Bool {
        viewModel.feed == .youTube ? viewModel.isLoadingYouTube : viewModel.isLoading
    }

    @ViewBuilder
    private var currentEmptyState: some View {
        if viewModel.feed == .youTube {
            EmptyStateView(
                title: "Nothing read yet",
                systemImage: "sparkles.tv",
                message: viewModel.youTubeIssue ?? "Pull down to read YouTube's home page again."
            )
        } else {
            emptyState
        }
    }

    /// Where the feed comes from, at the foot of it. Neither of these two is what it might be
    /// taken for, and a feed that quietly pretends otherwise is worse than one that says so.
    private var feedSourceNote: String? {
        switch viewModel.feed {
        case .youTube:
            return "The order comes from your YouTube home page, read in a signed-in web view. Everything shown about each video comes from the Data API."
        case .forYou:
            return "YouTube's personalized feed isn't open to apps. For You mixes YouTube's own charts for the categories you watch with new uploads from the channels you watch most."
        case .subscriptions:
            return nil
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            title: auth.isSignedIn ? "Nothing new yet" : "Your feed lives here",
            systemImage: "sparkles.tv",
            message: auth.isSignedIn
                ? "Watch a few videos and this feed will fill up with more from the channels you spend time on."
                : "Sign in with Google in Settings to see your subscriptions, or search for something to get started."
        )
    }

    private var placeholderFeed: some View {
        VStack(spacing: 24) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(Color.appTertiaryFill)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color.appTertiaryFill)
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            Capsule().fill(Color.appTertiaryFill).frame(height: 12)
                            Capsule().fill(Color.appTertiaryFill).frame(width: 140, height: 10)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .redacted(reason: .placeholder)
    }
}

/// Long-press actions shared by every video presentation.
struct VideoContextMenu: ViewModifier {
    let video: Video
    @State private var showsPlaylistPicker = false
    @State private var saveError: String?
    func body(content: Content) -> some View {
        content.contextMenu {
            VideoMenuItems(
                video: video,
                showPlaylistPicker: { showsPlaylistPicker = true },
                reportWatchLaterError: { saveError = $0 }
            )
        }
        .sheet(isPresented: $showsPlaylistPicker) { PlaylistPickerView(video: video) }
        .alert("Watch Later", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
    }
}

/// The single source of truth for both a video's long-press menu and its ellipsis menu.
struct VideoMenuItems: View {
    let video: Video
    let showPlaylistPicker: () -> Void
    let reportWatchLaterError: (String?) -> Void

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watchLater: WatchLaterStore
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var downloadManager: DownloadManager

    @ViewBuilder
    var body: some View {
        DownloadMenuButton(video: video, store: downloads, manager: downloadManager)

        Button {
            library.toggleFavorite(video)
        } label: {
            Label(
                library.isFavorite(video) ? "Remove from Favorites" : "Add to Favorites",
                systemImage: library.isFavorite(video) ? "heart.slash" : "heart"
            )
        }

        Button {
            Task {
                await watchLater.toggle(video)
                reportWatchLaterError(watchLater.errorMessage)
            }
        } label: {
            Label(
                watchLater.contains(video) ? "Remove from Watch Later" : "Add to Watch Later",
                systemImage: watchLater.contains(video) ? "clock.badge.xmark" : "clock"
            )
        }
        .disabled(watchLater.pendingVideoIDs.contains(video.id))

        Button(action: showPlaylistPicker) {
            Label("Add to Playlist…", systemImage: "text.badge.plus")
        }

        if let url = video.watchURL {
            ShareLink(item: url) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }
}

extension View {
    func videoContextMenu(_ video: Video) -> some View {
        modifier(VideoContextMenu(video: video))
    }
}

#Preview {
    NavigationStack { HomeView() }
        .environmentObject(APIKeyStore.shared)
        .environmentObject(LibraryStore.shared)
        .environmentObject(WatchLaterStore.shared)
        .environmentObject(GoogleAuthService.shared)
        .environmentObject(NotificationStore.shared)
        .environmentObject(AppRouter.shared)
        .environmentObject(YouTubeWebSession.shared)
}
