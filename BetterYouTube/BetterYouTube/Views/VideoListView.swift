import SwiftUI

/// Reusable list of videos, used for "See All" destinations and every library category.
struct VideoListView: View {
    @EnvironmentObject private var player: PlayerManager
    let title: LocalizedStringKey
    let videos: [Video]
    var onDelete: ((IndexSet) -> Void)?
    var onRefresh: (@Sendable () async -> Void)? = nil
    @State private var filter = ""

    /// The videos the filter leaves, in the list's own order.
    private var shown: [Video] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return videos }
        return videos.filter {
            $0.title.localizedStandardContains(query) || $0.channelTitle.localizedStandardContains(query)
        }
    }

    var body: some View {
        Group {
            if videos.isEmpty {
                ContentUnavailableView(
                    "Nothing Here Yet",
                    systemImage: "tray",
                    description: Text("Videos you add will show up in this list.")
                )
            } else {
                List {
                    ForEach(shown) { video in
                        Button {
                            player.play(video, upNext: shown.after(video))
                        } label: {
                            VideoRowView(video: video)
                        }
                        .buttonStyle(.plain)
                        .videoContextMenu(video)
                    }
                    .onDelete(perform: onDelete.map { delete in
                        // Rows are counted in the filtered list; the store counts in its own.
                        { offsets in
                            let shown = shown
                            let ids = Set(offsets.map { shown[$0].id })
                            delete(IndexSet(videos.indices.filter { ids.contains(videos[$0].id) }))
                        }
                    })
                }
                .listStyle(.plain)
                .overlay {
                    if shown.isEmpty {
                        ContentUnavailableView.search(text: filter)
                    }
                }
                .listFilter($filter, prompt: "Filter by title or channel")
                .minimizesPlayerBarOnScroll()
                .optionalRefreshable(action: onRefresh)
            }
        }
        .navigationTitle(title)
        .inlineNavigationBar()
    }
}

/// Grid of subscribed channels.
struct SubscriptionsView: View {
    let channels: [Channel]
    /// Shown as loading rather than empty until the first list arrives.
    var isLoading = false
    var onRefresh: (@Sendable () async -> Void)? = nil
    @State private var filter = ""

    private var shown: [Channel] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return channels }
        return channels.filter { $0.title.localizedStandardContains(query) }
    }

    /// As many columns as the width holds: three on a phone, more on an iPad or a Mac window,
    /// rather than three that leave a wide screen mostly gaps.
    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 16)]

    var body: some View {
        Group {
            if channels.isEmpty, isLoading {
                ProgressView()
            } else if channels.isEmpty {
                ContentUnavailableView(
                    "No Subscriptions",
                    systemImage: "person.2",
                    description: Text("Channels you follow on YouTube appear here.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(shown) { channel in
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
                .overlay {
                    if shown.isEmpty {
                        ContentUnavailableView.search(text: filter)
                    }
                }
                .listFilter($filter, prompt: "Filter channels")
                .minimizesPlayerBarOnScroll()
                .optionalRefreshable(action: onRefresh)
            }
        }
        .navigationTitle("Subscriptions")
        .inlineNavigationBar()
    }
}

/// The signed-in account's playlists.
struct PlaylistsView: View {
    let playlists: [Playlist]
    /// Shown as loading rather than empty until the first list arrives.
    var isLoading = false
    var onRefresh: (@Sendable () async -> Void)? = nil
    @State private var filter = ""

    private var displayedPlaylists: [Playlist] {
        playlists.filter { !$0.isLikedVideos }
    }

    private var shown: [Playlist] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return displayedPlaylists }
        return displayedPlaylists.filter { $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        Group {
            if displayedPlaylists.isEmpty, isLoading {
                ProgressView()
            } else if displayedPlaylists.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text("Playlists you create or save on YouTube appear here.")
                )
            } else {
                List(shown) { playlist in
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
                .overlay {
                    if shown.isEmpty {
                        ContentUnavailableView.search(text: filter)
                    }
                }
                .listFilter($filter, prompt: "Filter playlists")
                .minimizesPlayerBarOnScroll()
                .optionalRefreshable(action: onRefresh)
            }
        }
        .navigationTitle("Playlists")
        .inlineNavigationBar()
    }
}

/// A playlist as a card, the shape of a video's in a feed: its artwork, with how many videos it
/// holds where a video shows its length, and its title.
struct PlaylistCardView: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ArtworkView(
                url: playlist.thumbnailURL,
                duration: playlist.itemCount.map { String(localized: "\($0) videos") },
                cornerRadius: Theme.Radius.card
            )
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .artworkShadow()

            Label {
                Text(playlist.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            } icon: {
                Image(systemName: "list.and.film")
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
    }
}

/// Videos inside a playlist, fetched via `playlistItems.list` (1 quota unit).
struct PlaylistDetailView: View {
    @EnvironmentObject private var player: PlayerManager
    @StateObject private var viewModel: PlaylistViewModel

    init(playlist: Playlist) {
        _viewModel = StateObject(wrappedValue: PlaylistViewModel(playlist: playlist))
    }

    /// What the list it came from said — or, opened from a link, what the API has said since.
    private var playlist: Playlist { viewModel.playlist }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.videos.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = viewModel.errorMessage, viewModel.videos.isEmpty {
                ContentUnavailableView("Couldn't Load Playlist", systemImage: "exclamationmark.triangle", description: Text(message))
            } else {
                List {
                    Section {
                        PlaylistHeaderView(
                            playlist: playlist,
                            videoCount: viewModel.videos.count,
                            isPreparing: viewModel.isLoadingAll,
                            onPlay: {
                                Task {
                                    await viewModel.loadAll()
                                    if let first = viewModel.videos.first {
                                        player.play(first, upNext: viewModel.videos.after(first))
                                    }
                                }
                            },
                            onShuffle: {
                                Task {
                                    await viewModel.loadAll()
                                    let shuffled = viewModel.videos.shuffled()
                                    if let first = shuffled.first {
                                        player.play(first, upNext: Array(shuffled.dropFirst()))
                                    }
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

                            if viewModel.canLoadMore {
                                LoadMoreFooter(
                                    error: viewModel.loadMoreError,
                                    trigger: viewModel.videos.count
                                ) {
                                    await viewModel.loadMore()
                                }
                                .listRowSeparator(.hidden)
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
    /// True while the rest of the list is fetched before playing it.
    var isPreparing = false
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
                        Text("\(count) videos")
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
                        // In a List row a Label draws its icon in the accent color rather than in the
                        // button style's foreground, which on the prominent button's accent fill
                        // leaves it invisible.
                        Label {
                            Text("Play")
                        } icon: {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: onShuffle) {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(isPreparing)
                .overlay {
                    if isPreparing { ProgressView() }
                }
                .font(.headline)
                .controlSize(.large)
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


private extension View {
    @ViewBuilder
    func optionalRefreshable(action: (@Sendable () async -> Void)?) -> some View {
        if let action {
            self.refreshable(action: action)
        } else {
            self
        }
    }
}
