import SwiftUI

/// Apple Music-style library: category rows on top, recently watched artwork underneath.
struct LibraryView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watchLater: WatchLaterStore
    @EnvironmentObject private var auth: GoogleAuthService
    @StateObject private var viewModel = LibraryViewModel()

    var body: some View {
        List {
            if auth.isSignedIn {
                Section {
                    NavigationLink {
                        SubscriptionsView(channels: viewModel.subscriptions)
                    } label: {
                        LibraryRow(icon: "person.2.fill", tint: .red, title: "Subscriptions", count: viewModel.subscriptions.count)
                    }

                    NavigationLink {
                        PlaylistsView(playlists: viewModel.playlists)
                    } label: {
                        LibraryRow(icon: "music.note.list", tint: .orange, title: "Playlists", count: viewModel.playlists.count)
                    }

                    NavigationLink {
                        VideoListView(title: "Liked Videos", videos: viewModel.likedVideos)
                    } label: {
                        LibraryRow(icon: "hand.thumbsup.fill", tint: .blue, title: "Liked Videos", count: viewModel.likedVideos.count)
                    }
                } header: {
                    Text(viewModel.account?.title ?? "YouTube Account")
                } footer: {
                    if let message = viewModel.errorMessage {
                        Text(message)
                    }
                }
            } else {
                Section {
                    signInPrompt
                }
            }

            // Watch Later stands apart from the rest: signed in it is a real playlist in the
            // account, signed out it is this device's own list.
            Section {
                NavigationLink {
                    VideoListView(
                        title: "Watch Later",
                        videos: watchLater.videos,
                        onDelete: { offsets in
                            Task { await watchLater.remove(atOffsets: offsets) }
                        }
                    )
                } label: {
                    LibraryRow(
                        icon: "clock.fill",
                        tint: .indigo,
                        title: "Watch Later",
                        count: watchLater.videos.count
                    )
                }
            } header: {
                Text(watchLater.isSynced ? "Watch Later · Synced with YouTube" : "Watch Later · On This Device")
            } footer: {
                if let message = watchLater.errorMessage {
                    Text(message)
                } else if watchLater.isSynced {
                    Text("Kept in the “\(WatchLaterStore.playlistTitle)” playlist on your account — YouTube's own Watch Later is closed to apps.")
                }
            }

            Section("On This Device") {
                NavigationLink {
                    VideoListView(title: "Favorites", videos: library.favorites, onDelete: library.removeFavorites)
                } label: {
                    LibraryRow(icon: "heart.fill", tint: .pink, title: "Favorites", count: library.favorites.count)
                }

                NavigationLink {
                    VideoListView(title: "History", videos: library.history, onDelete: library.removeFromHistory)
                } label: {
                    LibraryRow(icon: "arrow.counterclockwise", tint: .gray, title: "History", count: library.history.count)
                }
            }

            if !library.history.isEmpty {
                Section("Recently Watched") {
                    ForEach(library.history.prefix(6)) { video in
                        Button {
                            player.play(video)
                        } label: {
                            VideoRowView(video: video)
                        }
                        .buttonStyle(.plain)
                        .videoContextMenu(video)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .minimizesPlayerBarOnScroll()
        .navigationTitle("Library")
        .navigationDestination(for: Channel.self) { ChannelView(channelId: $0.id, initialChannel: $0) }
        .refreshable {
            await watchLater.refresh()
            if auth.isSignedIn { await viewModel.load() }
        }
        .task(id: auth.isSignedIn) {
            await watchLater.refresh()
            if auth.isSignedIn {
                await viewModel.load()
            } else {
                viewModel.reset()
            }
        }
    }

    private var signInPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your YouTube library", systemImage: "person.crop.circle.badge.plus")
                .font(.headline)
            Text("Sign in with Google from Settings to browse your subscriptions, playlists and liked videos, and to keep Watch Later as a playlist on your account rather than only on this device. Watch history stays here either way — YouTube's API has never exposed it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            NavigationLink {
                SettingsView()
            } label: {
                Text("Open Settings")
                    .font(.subheadline.weight(.semibold))
            }
        }
        .padding(.vertical, 6)
    }
}

private struct LibraryRow: View {
    let icon: String
    let tint: Color
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text(title)
                .font(.body)

            Spacer()

            if let count, count > 0 {
                Text("\(count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack { LibraryView() }
        .environmentObject(LibraryStore.shared)
        .environmentObject(WatchLaterStore.shared)
        .environmentObject(GoogleAuthService.shared)
        .environmentObject(NotificationStore.shared)
}
