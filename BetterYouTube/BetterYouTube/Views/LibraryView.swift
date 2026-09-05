import SwiftUI

/// Apple Music-style library: category rows on top, recently watched artwork underneath.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
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

            Section("On This Device") {
                NavigationLink {
                    VideoListView(title: "Favorites", videos: library.favorites, onDelete: library.removeFavorites)
                } label: {
                    LibraryRow(icon: "heart.fill", tint: .pink, title: "Favorites", count: library.favorites.count)
                }

                NavigationLink {
                    VideoListView(title: "Watch Later", videos: library.watchLater, onDelete: library.removeWatchLater)
                } label: {
                    LibraryRow(icon: "clock.fill", tint: .indigo, title: "Watch Later", count: library.watchLater.count)
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
                        NavigationLink(value: video) {
                            VideoRowView(video: video)
                        }
                        .videoContextMenu(video)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Library")
        .navigationDestination(for: Video.self) { VideoDetailView(video: $0) }
        .navigationDestination(for: Channel.self) { ChannelView(channelId: $0.id, initialChannel: $0) }
        .refreshable {
            if auth.isSignedIn { await viewModel.load() }
        }
        .task(id: auth.isSignedIn) {
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
            Text("Sign in with Google from Settings to browse your subscriptions, playlists and liked videos. Watch Later and watch history stay on this device — YouTube's API has never exposed them.")
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
        .environmentObject(GoogleAuthService.shared)
}
