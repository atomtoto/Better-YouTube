import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var bridge: WatchBridge
    @EnvironmentObject private var player: WatchPlayer

    var body: some View {
        NavigationStack {
            List {
                if let current = player.current {
                    NavigationLink {
                        WatchNowPlayingView()
                    } label: {
                        Label(current.title, systemImage: "waveform")
                            .lineLimit(2)
                    }
                }
                NavigationLink { WatchHomeView() } label: { Label("Home", systemImage: "house.fill") }
                NavigationLink { WatchSearchView() } label: { Label("Search", systemImage: "magnifyingglass") }
                NavigationLink { WatchLibraryView() } label: { Label("Library", systemImage: "rectangle.stack.fill") }
                NavigationLink { WatchDownloadsView() } label: { Label("Downloads", systemImage: "arrow.down.circle.fill") }
                if bridge.apiKey.isEmpty {
                    Text("Set an API key in the iPhone app for Home and Search.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Better YouTube")
        }
    }
}

private struct WatchVideoRow: View {
    let video: WatchVideo
    @EnvironmentObject private var downloads: WatchDownloads

    var body: some View {
        NavigationLink {
            WatchVideoDetail(video: video)
        } label: {
            HStack(spacing: 8) {
                AsyncImage(url: video.thumbnailURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "play.rectangle.fill").foregroundStyle(.secondary)
                }
                .frame(width: 48, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title).font(.footnote).lineLimit(2)
                    Text(video.channel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if downloads.localURL(for: video) != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
    }
}

struct WatchHomeView: View {
    @EnvironmentObject private var bridge: WatchBridge

    var body: some View {
        List {
            if bridge.snapshot.homeFeed.isEmpty {
                Text("Open YouTube Home in the iPhone app to sync your feed.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(bridge.snapshot.homeFeed) { WatchVideoRow(video: $0) }
        }
        .navigationTitle("Home")
        .toolbar { Button("Sync", systemImage: "arrow.clockwise") { Task { await bridge.refresh() } } }
    }
}

struct WatchSearchView: View {
    @EnvironmentObject private var bridge: WatchBridge
    @State private var query = ""
    @State private var results: [WatchSearchEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            TextField("Video or channel", text: $query)
                .onSubmit { Task { await search() } }
            Button("Search", systemImage: "magnifyingglass") { Task { await search() } }
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            if isLoading { ProgressView() }
            if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.secondary) }
            ForEach(results) { result in
                switch result {
                case .video(let video): WatchVideoRow(video: video)
                case .channel(let channel):
                    NavigationLink {
                        WatchAccountVideosView(kind: "channel", id: channel.id, title: channel.title)
                    } label: {
                        Label(channel.title, systemImage: "person.crop.circle")
                    }
                }
            }
        }
        .navigationTitle("Search")
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do { results = try await WatchCatalogue.shared.search(term, apiKey: bridge.apiKey); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}

struct WatchLibraryView: View {
    @EnvironmentObject private var bridge: WatchBridge
    @EnvironmentObject private var account: WatchAccountLibraryStore

    var body: some View {
        List {
            Section("On This Device") {
                NavigationLink { WatchVideoListView(title: "Favorites", videos: bridge.localLibrary?.favorites ?? bridge.snapshot.favorites) }
                    label: { Label("Favorites", systemImage: "heart.fill") }
                NavigationLink { WatchVideoListView(title: "Watch Later", videos: bridge.localLibrary?.watchLater ?? bridge.snapshot.watchLater) }
                    label: { Label("Watch Later", systemImage: "clock.fill") }
                NavigationLink { WatchVideoListView(title: "History", videos: bridge.localLibrary?.history ?? bridge.snapshot.history) }
                    label: { Label("History", systemImage: "arrow.counterclockwise") }
                NavigationLink { WatchDownloadsView() }
                    label: { Label("Downloads", systemImage: "arrow.down.circle.fill") }
            }
            Section("Google Account") {
                if bridge.snapshot.accountSignedIn {
                    NavigationLink { WatchChannelListView() }
                        label: { Label("Subscriptions", systemImage: "person.2.fill") }
                    NavigationLink { WatchPlaylistListView() }
                        label: { Label("Playlists", systemImage: "music.note.list") }
                    NavigationLink { WatchVideoListView(title: "Liked Videos", videos: account.library.likedVideos) }
                        label: { Label("Liked Videos", systemImage: "hand.thumbsup.fill") }
                } else {
                    Text("Connect your Google account on the iPhone.").foregroundStyle(.secondary)
                }
            }
            if let message = account.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Library")
        .toolbar { Button("Sync", systemImage: "arrow.clockwise") { Task { await refresh() } } }
        .task { await refresh() }
    }

    private func refresh() async {
        guard bridge.isReachable, bridge.snapshot.accountSignedIn else { return }
        do { _ = try await bridge.request("refreshLibrary") }
        catch { account.message = error.localizedDescription }
    }
}

private struct WatchVideoListView: View {
    let title: LocalizedStringKey
    let videos: [WatchVideo]

    var body: some View {
        List {
            if videos.isEmpty { Text("No synced videos.").foregroundStyle(.secondary) }
            ForEach(videos) { WatchVideoRow(video: $0) }
        }
        .navigationTitle(title)
    }
}

private struct WatchChannelListView: View {
    @EnvironmentObject private var account: WatchAccountLibraryStore

    var body: some View {
        List {
            if account.library.subscriptions.isEmpty {
                Text("No synced subscriptions.").foregroundStyle(.secondary)
            }
            ForEach(account.library.subscriptions) { channel in
                NavigationLink {
                    WatchAccountVideosView(kind: "channel", id: channel.id, title: channel.title)
                } label: { Text(channel.title).lineLimit(2) }
            }
        }
        .navigationTitle("Subscriptions")
    }
}

private struct WatchPlaylistListView: View {
    @EnvironmentObject private var account: WatchAccountLibraryStore

    var body: some View {
        List {
            if account.library.playlists.isEmpty {
                Text("No synced playlists.").foregroundStyle(.secondary)
            }
            ForEach(account.library.playlists) { playlist in
                NavigationLink {
                    WatchAccountVideosView(kind: "playlist", id: playlist.id, title: playlist.title)
                } label: { Text(playlist.title).lineLimit(2) }
            }
        }
        .navigationTitle("Playlists")
    }
}

private struct WatchAccountVideosView: View {
    let kind: String
    let id: String
    let title: String
    @EnvironmentObject private var account: WatchAccountLibraryStore
    @EnvironmentObject private var bridge: WatchBridge
    @State private var videos: [WatchVideo] = []
    @State private var isLoading = false

    var body: some View {
        List {
            if isLoading { ProgressView() }
            if videos.isEmpty && !isLoading {
                Text(account.message ?? String(localized: "No saved videos."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(videos) { WatchVideoRow(video: $0) }
        }
        .navigationTitle(title)
        .task {
            videos = account.cachedVideos(kind: kind, id: id)
            isLoading = true
            videos = await account.loadVideos(kind: kind, id: id, apiKey: bridge.apiKey)
            isLoading = false
        }
    }
}

struct WatchDownloadsView: View {
    @EnvironmentObject private var downloads: WatchDownloads
    @EnvironmentObject private var bridge: WatchBridge

    var body: some View {
        List {
            Section("On the Watch") {
                if downloads.records.isEmpty {
                    Text("Nothing available offline.").foregroundStyle(.secondary)
                }
                ForEach(downloads.records) { record in
                    WatchVideoRow(video: record.video)
                        .swipeActions { Button("Delete", role: .destructive) { downloads.delete(record.video) } }
                }
            }
            Section("On the iPhone") {
                if (bridge.localLibrary?.downloads ?? bridge.snapshot.downloads).isEmpty {
                    Text("No synced downloads.").foregroundStyle(.secondary)
                }
                ForEach(bridge.localLibrary?.downloads ?? bridge.snapshot.downloads) { video in WatchVideoRow(video: video) }
            }
        }
        .navigationTitle("Downloads")
    }
}

struct WatchVideoDetail: View {
    let video: WatchVideo
    @EnvironmentObject private var bridge: WatchBridge
    @EnvironmentObject private var downloads: WatchDownloads
    @EnvironmentObject private var player: WatchPlayer

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                AsyncImage(url: video.thumbnailURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "play.rectangle.fill").font(.largeTitle).foregroundStyle(.secondary)
                }
                .frame(height: 95)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(video.title).font(.headline).multilineTextAlignment(.center)
                Text(video.channel).font(.footnote).foregroundStyle(.secondary)
                if downloads.localURL(for: video) != nil {
                    Button("Listen", systemImage: "play.fill") { Task { await player.play(video) } }
                        .buttonStyle(.borderedProminent)
                    if player.current?.id == video.id {
                        NavigationLink("Now Playing") { WatchNowPlayingView() }
                    }
                    Button("Remove from Watch", role: .destructive) { downloads.delete(video) }
                } else {
                    Button("Download to Watch", systemImage: "arrow.down.circle") {
                        downloads.downloadOnWatch(video)
                    }
                    .disabled(!bridge.isReachable || downloads.downloadingID != nil)
                    if (bridge.localLibrary?.downloads ?? bridge.snapshot.downloads).contains(where: { $0.id == video.id }) {
                        Button("Transfer from iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right") {
                            downloads.transferFromPhone(video)
                        }
                        .disabled(!bridge.isReachable)
                    }
                    if !bridge.isReachable {
                        Text("Bring the iPhone closer to prepare the download.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if downloads.downloadingID == video.id {
                    ProgressView(value: downloads.progress)
                    Button("Stop", role: .cancel) { downloads.cancelDownload() }
                }
                if let message = downloads.message {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                }
                if let error = player.errorMessage {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Video")
    }
}

struct WatchNowPlayingView: View {
    @EnvironmentObject private var player: WatchPlayer

    var body: some View {
        VStack(spacing: 10) {
            Text(player.current?.title ?? String(localized: "Nothing Playing"))
                .font(.headline).lineLimit(3).multilineTextAlignment(.center)
            Text(player.current?.channel ?? "")
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 20) {
                Button("Skip Back", systemImage: "gobackward.15") { player.seek(by: -15) }
                Button(player.isPlaying ? "Pause" : "Play",
                       systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.toggle() }
                    .buttonStyle(.borderedProminent)
                Button("Skip Forward", systemImage: "goforward.15") { player.seek(by: 15) }
            }
            .labelStyle(.iconOnly)
            ProgressView(value: player.duration > 0 ? player.elapsed / player.duration : 0)
            Button("Stop", role: .cancel) { player.stop() }
        }
        .navigationTitle("Playback")
    }
}
