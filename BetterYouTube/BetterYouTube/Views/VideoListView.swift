import SwiftUI

/// Reusable list of videos, used for "See All" destinations and every library category.
struct VideoListView: View {
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
                        NavigationLink(value: video) {
                            VideoRowView(video: video)
                        }
                        .videoContextMenu(video)
                    }
                    .onDelete(perform: onDelete)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Video.self) { VideoDetailView(video: $0) }
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
                            NavigationLink(value: channel) {
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
            }
        }
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Channel.self) { ChannelView(channelId: $0.id, initialChannel: $0) }
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
                    message: "Playlists you create on YouTube appear here."
                )
            } else {
                List(playlists) { playlist in
                    NavigationLink(value: playlist) {
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
            }
        }
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
    }
}

/// Videos inside a playlist, fetched via `playlistItems.list` (1 quota unit).
struct PlaylistDetailView: View {
    let playlist: Playlist
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
                        ForEach(viewModel.videos) { video in
                            NavigationLink(value: video) {
                                VideoRowView(video: video)
                            }
                            .videoContextMenu(video)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 10) {
                            ArtworkView(url: playlist.thumbnailURL, cornerRadius: Theme.Radius.card)
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .artworkShadow()
                            Text(playlist.title)
                                .font(.title3.bold())
                                .foregroundStyle(.primary)
                            if !playlist.description.isEmpty {
                                Text(playlist.description)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .textCase(nil)
                        .padding(.bottom, 8)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Video.self) { VideoDetailView(video: $0) }
        .task {
            if viewModel.videos.isEmpty { await viewModel.load() }
        }
    }
}

#Preview {
    NavigationStack {
        VideoListView(title: "Favorites", videos: [.preview])
    }
    .environmentObject(LibraryStore.shared)
}
