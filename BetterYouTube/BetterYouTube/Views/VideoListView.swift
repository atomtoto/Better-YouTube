import SwiftUI

/// Reusable list of videos, used for "See All" destinations and every library category.
struct VideoListView: View {
    @EnvironmentObject private var player: PlayerManager
    let title: String
    let videos: [Video]
    var onDelete: ((IndexSet) -> Void)?

    var body: some View {
        Group {
            if videos.isEmpty {
                EmptyStateView(
                    title: "Nothing here yet",
                    systemImage: "tray",
                    message: "Videos you add will show up in this list."
                )
            } else {
                List {
                    ForEach(videos) { video in
                        Button {
                            player.play(video, upNext: videos.after(video))
                        } label: {
                            VideoRowView(video: video)
                        }
                        .buttonStyle(.plain)
                        .videoContextMenu(video)
                    }
                    .onDelete(perform: onDelete)
                }
                .listStyle(.plain)
                .minimizesPlayerBarOnScroll()
            }
        }
        .navigationTitle(title)
        .inlineNavigationBar()
    }
}

/// Grid of subscribed channels.
struct SubscriptionsView: View {
    let channels: [Channel]

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        Group {
            if channels.isEmpty {
                EmptyStateView(
                    title: "No subscriptions",
                    systemImage: "person.2",
                    message: "Channels you follow on YouTube appear here."
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(channels) { channel in
                            NavigationLink {
                                ChannelView(channelId: channel.id, initialChannel: channel)
                            } label: {
                                VStack(spacing: 8) {
                                    AvatarView(url: channel.thumbnailURL, size: 76)
                                        .artworkShadow()
                                    Text(channel.title)
                                        .font(.caption)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(Theme.Spacing.gutter)
                }
                .scrollIndicators(.hidden)
                .minimizesPlayerBarOnScroll()
            }
        }
        .navigationTitle("Subscriptions")
        .inlineNavigationBar()
    }
}

/// The signed-in account's playlists.
struct PlaylistsView: View {
    let playlists: [Playlist]

    var body: some View {
        Group {
            if playlists.isEmpty {
                EmptyStateView(
                    title: "No playlists",
                    systemImage: "music.note.list",
                    message: "Playlists you create or save on YouTube appear here."
                )
            } else {
                List(playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        HStack(spacing: 12) {
                            ArtworkView(url: playlist.thumbnailURL)
                                .frame(width: Theme.Size.compactThumbnail, height: Theme.Size.compactThumbnail * 9 / 16)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)
                                if let count = playlist.itemCount {
                                    Text("\(count) videos")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.plain)
                .minimizesPlayerBarOnScroll()
            }
        }
        .navigationTitle("Playlists")
        .inlineNavigationBar()
    }
}

/// Videos inside a playlist, fetched via `playlistItems.list` (1 quota unit).
struct PlaylistDetailView: View {
    let playlist: Playlist
    @EnvironmentObject private var player: PlayerManager
    @StateObject private var viewModel: PlaylistViewModel

    init(playlist: Playlist) {
        self.playlist = playlist
        _viewModel = StateObject(wrappedValue: PlaylistViewModel(playlistId: playlist.id))
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.videos.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = viewModel.errorMessage, viewModel.videos.isEmpty {
                EmptyStateView(title: "Couldn't load playlist", message: message)
            } else {
                List {
                    Section {
                        PlaylistHeaderView(
                            playlist: playlist,
                            videoCount: viewModel.videos.count,
                            onPlay: {
                                if let first = viewModel.videos.first {
                                    player.play(first, upNext: viewModel.videos.after(first))
                                }
                            },
                            onShuffle: {
                                let shuffled = viewModel.videos.shuffled()
                                if let first = shuffled.first {
                                    player.play(first, upNext: Array(shuffled.dropFirst()))
                                }
                            }
                        )
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }

                    Section {
                        if viewModel.videos.isEmpty && !viewModel.isLoading {
                            Text("This playlist has no videos.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                                .listRowSeparator(.hidden)
                        } else {
                            ForEach(viewModel.videos) { video in
                                Button {
                                    player.play(video, upNext: viewModel.videos.after(video))
                                } label: {
                                    VideoRowView(video: video)
                                }
                                .buttonStyle(.plain)
                                .videoContextMenu(video)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .minimizesPlayerBarOnScroll()
                .refreshable {
                    await viewModel.load()
                }
            }
        }
        .navigationTitle(playlist.title)
        .inlineNavigationBar()
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshButton { await viewModel.load() }
            }
        }
        #endif
        .task {
            if viewModel.videos.isEmpty { await viewModel.load() }
        }
    }
}

struct PlaylistHeaderView: View {
    let playlist: Playlist
    let videoCount: Int
    let onPlay: () -> Void
    let onShuffle: () -> Void
    @State private var isDescriptionExpanded = false

    var body: some View {
        VStack(spacing: 12) {
            ArtworkView(url: playlist.thumbnailURL, cornerRadius: Theme.Radius.card)
                .frame(width: 176, height: 99)
                .artworkShadow()

            VStack(spacing: 4) {
                Text(playlist.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let channel = playlist.channelTitle, !channel.isEmpty {
                        Text(channel)
                        Text("•")
                    }
                    let count = playlist.itemCount ?? videoCount
                    if count > 0 {
                        Text("\(count) \(count == 1 ? "video" : "videos")")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if !playlist.description.isEmpty {
                    Text(playlist.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(isDescriptionExpanded ? nil : 2)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                        .onTapGesture {
                            withAnimation(.snappy) {
                                isDescriptionExpanded.toggle()
                            }
                        }
                }
            }
            .padding(.horizontal, Theme.Spacing.gutter)

            if videoCount > 0 {
                HStack(spacing: 12) {
                    Button(action: onPlay) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.white)
                            Text("Play")
                                .foregroundStyle(.white)
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button(action: onShuffle) {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, Theme.Spacing.gutter)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

#Preview {
    NavigationStack {
        VideoListView(title: "Favorites", videos: [.preview])
    }
    .environmentObject(LibraryStore.shared)
    .environmentObject(WatchLaterStore.shared)
}
