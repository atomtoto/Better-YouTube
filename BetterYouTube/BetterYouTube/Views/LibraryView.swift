import SwiftUI

/// Apple Music-style library: category rows on top, recently watched artwork underneath.
struct LibraryView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watchLater: WatchLaterStore
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var webSession: YouTubeWebSession
    @EnvironmentObject private var downloads: DownloadStore
    @StateObject private var viewModel = LibraryViewModel()

    var body: some View {
        List {
            Section {
                if auth.isSignedIn || webSession.isSignedIn {
                    if auth.isSignedIn {
                        NavigationLink {
                            SubscriptionsView(channels: viewModel.subscriptions)
                        } label: {
                            LibraryRow(icon: "person.2.fill", tint: .red, title: "Subscriptions", count: viewModel.subscriptions.count)
                        }

                        NavigationLink {
                            VideoListView(title: "Liked Videos", videos: viewModel.likedVideos)
                        } label: {
                            LibraryRow(icon: "hand.thumbsup.fill", tint: .blue, title: "Liked Videos", count: viewModel.likedVideos.count)
                        }
                    }

                    NavigationLink {
                        PlaylistsView(playlists: viewModel.playlists)
                    } label: {
                        LibraryRow(icon: "music.note.list", tint: .orange, title: "Playlists", count: viewModel.playlists.count)
                    }
                } else {
                    signInPrompt
                }

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
                Text(viewModel.account?.title ?? "YouTube Account")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let message = viewModel.errorMessage { Text(message) }
                    if let message = watchLater.errorMessage {
                        Text(message)
                    } else if watchLater.usesYouTubeWatchLater {
                        Text("Watch Later is synced with the account connected to youtube.com.")
                    } else {
                        Text("Watch Later is stored on this device.")
                    }
                }
            }

            Section("On This Device") {
                // First in the section on purpose: it is the only row here that still works with
                // the network off, which is exactly when someone goes looking for it.
                NavigationLink {
                    DownloadsView()
                } label: {
                    LibraryRow(
                        icon: "arrow.down.circle.fill",
                        tint: .green,
                        title: "Downloads",
                        count: downloads.readyRecords.count
                    )
                }

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
        .groupedListStyle()
        .minimizesPlayerBarOnScroll()
        .navigationTitle("Library")
        .refreshable { await reload() }
        // The whole toolbar is the Mac's: on a phone the pull above is the affordance, and an
        // empty `toolbar` block isn't a thing the builder accepts.
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { RefreshButton(action: reload) }
        }
        #endif
        .task(id: "\(auth.isSignedIn)-\(webSession.isSignedIn)-\(webSession.feedGeneration)-\(watchLater.sessionRevision)") {
            await watchLater.refresh()
            if auth.isSignedIn || webSession.isSignedIn {
                await viewModel.load(apiSignedIn: auth.isSignedIn, webSignedIn: webSession.isSignedIn)
            } else {
                viewModel.reset()
            }
        }
    }

    /// What a pull — or, on a Mac, the Refresh button — asks for.
    private func reload() async {
        await watchLater.refresh()
        if auth.isSignedIn || webSession.isSignedIn {
            await viewModel.load(apiSignedIn: auth.isSignedIn, webSignedIn: webSession.isSignedIn)
        }
    }

    private var signInPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your YouTube library", systemImage: "person.crop.circle.badge.plus")
                .font(.headline)
            Text("Sign in with Google from Settings to browse your subscriptions, playlists and liked videos, and to keep Watch Later as a playlist on your account rather than only on this device. Watch history stays here either way — YouTube's API has never exposed it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            OpenSettingsButton()
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
        .environmentObject(YouTubeWebSession.shared)
        .environmentObject(NotificationStore.shared)
        .environmentObject(DownloadStore.shared)
        .environmentObject(DownloadManager.shared)
        .environmentObject(DownloadSettings.shared)
        .environmentObject(PlayerManager.shared)
}
