import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var notificationStore: NotificationStore
    @StateObject private var viewModel = HomeViewModel()

    @State private var showsNotifications = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                Picker("Feed", selection: $viewModel.feed) {
                    ForEach(HomeViewModel.Feed.allCases) { feed in
                        Text(feed.title).tag(feed)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Theme.Spacing.gutter)

                if viewModel.isLoading && viewModel.videos.isEmpty {
                    placeholderFeed
                } else if viewModel.videos.isEmpty {
                    emptyState
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
                }
            }
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
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
        .refreshable { await viewModel.load(isSignedIn: auth.isSignedIn, library: library) }
        .task(id: auth.isSignedIn) {
            await viewModel.load(isSignedIn: auth.isSignedIn, library: library)
        }
    }

    // MARK: Pieces

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
                library.toggleWatchLater(video)
            } label: {
                Label(
                    library.isInWatchLater(video) ? "Remove from Watch Later" : "Add to Watch Later",
                    systemImage: library.isInWatchLater(video) ? "clock.badge.xmark" : "clock"
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
        .environmentObject(GoogleAuthService.shared)
        .environmentObject(NotificationStore.shared)
        .environmentObject(AppRouter.shared)
}
