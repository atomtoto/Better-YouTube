import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var viewModel = HomeViewModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.section) {
                if viewModel.isLoading && viewModel.trending.isEmpty {
                    loadingState
                } else if let message = viewModel.errorMessage, viewModel.trending.isEmpty {
                    EmptyStateView(
                        title: "Nothing to show yet",
                        systemImage: "wifi.exclamationmark",
                        message: message
                    )
                    .padding(.top, 60)
                } else {
                    if let featured = viewModel.featured {
                        NavigationLink(value: featured) {
                            FeaturedVideoCard(video: featured)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Theme.Spacing.gutter)
                    }

                    if !viewModel.subscriptionFeed.isEmpty {
                        carousel(
                            title: "From Your Subscriptions",
                            subtitle: "New uploads",
                            videos: viewModel.subscriptionFeed
                        )
                    }

                    if !viewModel.trendingRest.isEmpty {
                        carousel(
                            title: "Trending Now",
                            subtitle: "Popular on YouTube",
                            videos: viewModel.trendingRest
                        )
                    }

                    if !library.history.isEmpty {
                        carousel(
                            title: "Continue Watching",
                            subtitle: "Recently played",
                            videos: Array(library.history.prefix(12))
                        )
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.gutter)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Home")
        .navigationDestination(for: Video.self) { VideoDetailView(video: $0) }
        .navigationDestination(for: Channel.self) { ChannelView(channelId: $0.id, initialChannel: $0) }
        .refreshable { await viewModel.load(isSignedIn: auth.isSignedIn) }
        .task {
            if viewModel.trending.isEmpty {
                await viewModel.load(isSignedIn: auth.isSignedIn)
            }
        }
    }

    private func carousel(title: String, subtitle: String, videos: [Video]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, subtitle: subtitle) {
                VideoListView(title: title, videos: videos)
            }
            .padding(.horizontal, Theme.Spacing.gutter)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.Spacing.card) {
                    ForEach(videos) { video in
                        NavigationLink(value: video) {
                            VideoCardView(video: video)
                        }
                        .buttonStyle(.plain)
                        .videoContextMenu(video)
                    }
                }
                .padding(.horizontal, Theme.Spacing.gutter)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 20) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
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
}
