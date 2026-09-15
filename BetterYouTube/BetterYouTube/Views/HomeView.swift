import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var notificationStore: NotificationStore
    @EnvironmentObject private var webSession: YouTubeWebSession
    @StateObject private var viewModel = HomeViewModel()

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
                    feedPicker
                    YouTubeWebFeedView()
                        .ignoresSafeArea(edges: .bottom)
                }
                .padding(.top, 12)
            } else {
                cardFeed
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Home")
        .toolbar {
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
        .task(id: auth.isSignedIn) {
            await viewModel.load(isSignedIn: auth.isSignedIn, library: library)
        }
        .task(id: webSession.isSignedIn) {
            viewModel.adoptDefaultFeed(webSignedIn: webSession.isSignedIn)
        }
        // Keyed on the rendering too: switching back from YouTube's page to the cards has to
        // fill them, and there is nothing to read while the page is showing itself.
        .task(id: "\(viewModel.feed.rawValue)-\(webSession.rendering.rawValue)") {
            guard viewModel.feed == .youTube, !showsYouTubePage else { return }
            await viewModel.loadYouTubeFeed()
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
    private var feedPicker: some View {
        Picker("Feed", selection: Binding(get: { viewModel.feed }, set: viewModel.select)) {
            ForEach(HomeViewModel.Feed.allCases) { feed in
                if feed != .youTube || webSession.isSignedIn {
                    Text(feed.title).tag(feed)
                }
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Theme.Spacing.gutter)
    }

    private var cardFeed: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                feedPicker

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
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(uiColor: .tertiarySystemFill))
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            Capsule().fill(Color(uiColor: .tertiarySystemFill)).frame(height: 12)
                            Capsule().fill(Color(uiColor: .tertiarySystemFill)).frame(width: 140, height: 10)
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
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watchLater: WatchLaterStore

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                library.toggleFavorite(video)
            } label: {
                Label(
                    library.isFavorite(video) ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: library.isFavorite(video) ? "heart.slash" : "heart"
                )
            }

            Button {
                // Signed in this is a write to the account playlist, so it leaves the main
                // thread; the list updates optimistically and rolls back if YouTube refuses.
                Task { await watchLater.toggle(video) }
            } label: {
                Label(
                    watchLater.contains(video) ? "Remove from Watch Later" : "Add to Watch Later",
                    systemImage: watchLater.contains(video) ? "clock.badge.xmark" : "clock"
                )
            }

            if let url = video.watchURL {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
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
