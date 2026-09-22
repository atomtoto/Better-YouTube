import SwiftUI

/// Custom playlists use the supported Data API and the Google account shown in Settings.
struct PlaylistPickerView: View {
    let videos: [Video]
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var watchLater: WatchLaterStore
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [Playlist] = []
    @State private var loading = true
    @State private var containedPlaylistIDs: Set<String> = []
    @State private var checkingPlaylistIDs: Set<String> = []
    @State private var cachedItemIDs: [String: [String]] = [:]
    @State private var mutatingID: String?
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    // Bulk Takeout import state
    @State private var savedID: String?
    @State private var savedCount = 0

    private var isSingleVideo: Bool { videos.count == 1 }
    private var singleVideo: Video? { videos.first }

    init(video: Video) { videos = [video] }
    init(videos: [Video]) { self.videos = videos }

    var body: some View {
        NavigationStack {
            List {
                headerSection

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                        if mutatingID == nil, auth.isSignedIn {
                            Button("Reload Playlists") { Task { await load() } }
                        }
                    }
                }

                if isSingleVideo {
                    singleVideoPlaylistSections
                } else {
                    bulkImportPlaylistSections
                }

                if let statusMessage, isSingleVideo {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(statusMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let savedID, !isSingleVideo {
                    Text(savedCount == 1 ? "1 video added." : "\(savedCount) videos added.")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Saved to \(savedID)")
                }
            }
            .navigationTitle("Add to Playlist")
            .inlineNavigationBar()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(mutatingID != nil)
                }
            }
            .interactiveDismissDisabled(mutatingID != nil)
            .task(id: auth.isSignedIn) { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 360)
        #endif
    }

    private var headerSection: some View {
        Section {
            if isSingleVideo, let video = singleVideo {
                Text(video.title)
                    .font(.headline)
                    .lineLimit(2)
                Text("Tap a playlist to add or remove this video.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(videos.count) videos from Google Takeout")
                    .font(.headline)
                Text("Choose the destination. Custom playlists use the Google account connected in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var singleVideoPlaylistSections: some View {
        if watchLater.usesYouTubeWatchLater, let video = singleVideo {
            Section {
                Button {
                    Task { await toggleWatchLater(for: video) }
                } label: {
                    HStack(spacing: 12) {
                        Label("Watch Later", systemImage: "clock")
                            .foregroundStyle(.primary)
                        Spacer()
                        if mutatingID == "WL" {
                            ProgressView()
                                .controlSize(.small)
                        } else if watchLater.contains(video) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Image(systemName: "circle")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(mutatingID != nil)
            }
        }

        if auth.isSignedIn {
            Section {
                if loading {
                    ProgressView("Loading playlists…")
                }
                ForEach(playlists) { playlist in
                    let isContained = containedPlaylistIDs.contains(playlist.id)
                    let isChecking = checkingPlaylistIDs.contains(playlist.id)
                    Button {
                        Task { await toggle(playlist: playlist) }
                    } label: {
                        HStack(spacing: 12) {
                            Label(playlist.title, systemImage: "music.note.list")
                                .foregroundStyle(.primary)
                            Spacer()
                            if mutatingID == playlist.id || isChecking {
                                ProgressView()
                                    .controlSize(.small)
                            } else if isContained {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Image(systemName: "circle")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(mutatingID != nil || isChecking)
                }

                if !loading, playlists.isEmpty, errorMessage == nil {
                    Text("No custom playlists found. Create one on YouTube, then reload.")
                    Button("Reload Playlists") { Task { await load() } }
                }
            }
        } else {
            Section {
                Text(
                    watchLater.usesYouTubeWatchLater
                        ? "Sign in with Google in Settings to manage your custom playlists."
                        : "Connect youtube.com for Watch Later, or sign in with Google for custom playlists."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                OpenSettingsButton()
            }
        }
    }

    @ViewBuilder
    private var bulkImportPlaylistSections: some View {
        if watchLater.usesYouTubeWatchLater {
            destinationButton(id: "WL", title: "Watch Later", systemImage: "clock") {
                await saveBulkToWatchLater()
            }
        }

        if auth.isSignedIn {
            if loading {
                ProgressView("Loading playlists…")
            }
            ForEach(playlists) { playlist in
                destinationButton(id: playlist.id, title: playlist.title, systemImage: "music.note.list") {
                    await saveBulk(to: playlist)
                }
            }
            if !loading, playlists.isEmpty, errorMessage == nil {
                Text("No custom playlists found. Create one on YouTube, then reload.")
                Button("Reload Playlists") { Task { await load() } }
            }
        } else {
            Section {
                Text(
                    watchLater.usesYouTubeWatchLater
                        ? "Sign in with Google in Settings to add videos to your custom playlists."
                        : "Connect youtube.com for Watch Later, or sign in with Google for custom playlists."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                OpenSettingsButton()
            }
        }
    }

    private func load() async {
        guard auth.isSignedIn else { playlists = []; loading = false; return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let fetched = try await YouTubeAPIService.shared.myPlaylists()
                .filter { $0.id != "WL" && $0.id != "HL" && $0.id != "LL" }
            playlists = fetched

            if let video = singleVideo, isSingleVideo {
                checkingPlaylistIDs = Set(fetched.map(\.id))
                await withTaskGroup(of: (String, [String]).self) { group in
                    for playlist in fetched {
                        group.addTask {
                            let items = (try? await YouTubeAPIService.shared.playlistItemIds(
                                playlistId: playlist.id,
                                videoId: video.id
                            )) ?? []
                            return (playlist.id, items)
                        }
                    }
                    for await (playlistId, items) in group {
                        _ = withAnimation {
                            checkingPlaylistIDs.remove(playlistId)
                        }
                        if !items.isEmpty {
                            cachedItemIDs[playlistId] = items
                            _ = withAnimation {
                                containedPlaylistIDs.insert(playlistId)
                            }
                        }
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleWatchLater(for video: Video) async {
        guard mutatingID == nil else { return }
        mutatingID = "WL"
        statusMessage = nil
        errorMessage = nil
        Haptics.light()
        defer { mutatingID = nil }

        let wasContained = watchLater.contains(video)
        if wasContained {
            await watchLater.remove(video)
            if let err = watchLater.errorMessage {
                errorMessage = err
            } else {
                withAnimation {
                    statusMessage = "Removed from Watch Later."
                }
            }
        } else {
            await watchLater.add(video)
            if let err = watchLater.errorMessage {
                errorMessage = err
            } else {
                withAnimation {
                    statusMessage = "Added to Watch Later."
                }
            }
        }
    }

    private func toggle(playlist: Playlist) async {
        guard let video = singleVideo, isSingleVideo else { return }
        guard mutatingID == nil else { return }
        mutatingID = playlist.id
        statusMessage = nil
        errorMessage = nil
        Haptics.light()
        defer { mutatingID = nil }

        let wasContained = containedPlaylistIDs.contains(playlist.id)
        do {
            if wasContained {
                let ids: [String]
                if let cached = cachedItemIDs[playlist.id], !cached.isEmpty {
                    ids = cached
                } else {
                    ids = try await YouTubeAPIService.shared.playlistItemIds(
                        playlistId: playlist.id,
                        videoId: video.id
                    )
                }
                for itemId in ids {
                    try await YouTubeAPIService.shared.removePlaylistItem(id: itemId)
                }
                cachedItemIDs[playlist.id] = []
                withAnimation {
                    containedPlaylistIDs.remove(playlist.id)
                    statusMessage = "Removed from \(playlist.title)."
                }
            } else {
                let newItemId = try await YouTubeAPIService.shared.addToPlaylist(
                    playlistId: playlist.id,
                    videoId: video.id
                )
                cachedItemIDs[playlist.id] = [newItemId]
                withAnimation {
                    containedPlaylistIDs.insert(playlist.id)
                    statusMessage = "Added to \(playlist.title)."
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveBulk(to playlist: Playlist) async {
        guard mutatingID == nil, savedID == nil else { return }
        mutatingID = playlist.id
        savedCount = 0
        errorMessage = nil
        defer { mutatingID = nil }
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

    private func saveBulkToWatchLater() async {
        guard mutatingID == nil, savedID == nil else { return }
        mutatingID = "WL"
        savedCount = 0
        errorMessage = nil
        defer { mutatingID = nil }
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
                if mutatingID == id { ProgressView() }
                if savedID == id || (id == "WL" && savedID == "Watch Later") {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
        .disabled(mutatingID != nil || savedID != nil)
    }
}
