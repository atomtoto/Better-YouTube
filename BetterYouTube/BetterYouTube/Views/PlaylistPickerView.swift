import SwiftUI

/// Custom playlists use the supported Data API and the Google account shown in Settings.
struct PlaylistPickerView: View {
    let videos: [Video]
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var watchLater: WatchLaterStore
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [Playlist] = []
    @State private var loading = true
    @State private var savingID: String?
    @State private var savedID: String?
    @State private var savedCount = 0
    @State private var errorMessage: String?

    init(video: Video) { videos = [video] }
    init(videos: [Video]) { self.videos = videos }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if videos.count == 1 {
                        Text(videos[0].title).font(.headline)
                    } else {
                        Text("\(videos.count) videos from Google Takeout").font(.headline)
                    }
                    Text("Choose the destination. Custom playlists use the Google account connected in Settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                        if savingID == nil, auth.isSignedIn {
                            Button("Reload Playlists") { Task { await load() } }
                        }
                    }
                }

                if watchLater.usesYouTubeWatchLater {
                    destinationButton(id: "WL", title: "Watch Later", systemImage: "clock") {
                        await saveToWatchLater()
                    }
                }

                if auth.isSignedIn {
                    if loading { ProgressView("Loading playlists…") }
                    ForEach(playlists) { playlist in
                        destinationButton(id: playlist.id, title: playlist.title,
                                          systemImage: "music.note.list") {
                            await save(to: playlist)
                        }
                    }
                    if !loading, playlists.isEmpty, errorMessage == nil {
                        Text("No custom playlists found. Create one on YouTube, then reload.")
                        Button("Reload Playlists") { Task { await load() } }
                    }
                } else if !watchLater.usesYouTubeWatchLater {
                    Text("Connect youtube.com for Watch Later, or sign in with Google for custom playlists.")
                    OpenSettingsButton()
                }

                if let savedID {
                    Text(savedCount == 1 ? "1 video added." : "\(savedCount) videos added.")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Saved to \(savedID)")
                }
            }
            .navigationTitle("Add to Playlist")
            .inlineNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(savingID != nil)
                }
            }
            .interactiveDismissDisabled(savingID != nil)
            .task(id: auth.isSignedIn) { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 360)
        #endif
    }

    private func load() async {
        guard auth.isSignedIn else { playlists = []; loading = false; return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            playlists = try await YouTubeAPIService.shared.myPlaylists()
                .filter { $0.id != "WL" && $0.id != "HL" && $0.id != "LL" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(to playlist: Playlist) async {
        guard savingID == nil, savedID == nil else { return }
        savingID = playlist.id
        savedCount = 0
        errorMessage = nil
        defer { savingID = nil }
        do {
            let existing = try await YouTubeAPIService.shared.entries(inPlaylist: playlist.id)
            let known = Set(existing.map(\.video.id))
            for video in videos where !known.contains(video.id) {
                _ = try await YouTubeAPIService.shared.addToPlaylist(
                    playlistId: playlist.id,
                    videoId: video.id
                )
                savedCount += 1
            }
            savedID = playlist.id
        } catch {
            errorMessage = savedCount == 0
                ? error.localizedDescription
                : "Added \(savedCount) videos, then stopped: \(error.localizedDescription)"
        }
    }

    private func saveToWatchLater() async {
        guard savingID == nil, savedID == nil else { return }
        savingID = "WL"
        savedCount = 0
        errorMessage = nil
        defer { savingID = nil }
        for video in videos where !watchLater.contains(video) {
            await watchLater.add(video)
            if let failure = watchLater.errorMessage {
                errorMessage = savedCount == 0
                    ? failure
                    : "Added \(savedCount) videos, then stopped: \(failure)"
                return
            }
            savedCount += 1
        }
        savedID = "Watch Later"
    }

    private func destinationButton(
        id: String,
        title: String,
        systemImage: String,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button { Task { await action() } } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if savingID == id { ProgressView() }
                if savedID == id || (id == "WL" && savedID == "Watch Later") {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
        .disabled(savingID != nil || savedID != nil)
    }
}
