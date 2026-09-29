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
                NavigationLink { WatchHomeView() } label: { Label("Accueil", systemImage: "house.fill") }
                NavigationLink { WatchSearchView() } label: { Label("Recherche", systemImage: "magnifyingglass") }
                NavigationLink { WatchLibraryView() } label: { Label("Bibliothèque", systemImage: "rectangle.stack.fill") }
                NavigationLink { WatchDownloadsView() } label: { Label("Téléchargements", systemImage: "arrow.down.circle.fill") }
                if bridge.apiKey.isEmpty {
                    Text("Configure une clé API dans l’app iPhone pour l’accueil et la recherche.")
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
                Text("Ouvre l’accueil YouTube dans l’app iPhone pour synchroniser ton flux.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(bridge.snapshot.homeFeed) { WatchVideoRow(video: $0) }
        }
        .navigationTitle("Accueil")
        .toolbar { Button("Synchroniser", systemImage: "arrow.clockwise") { Task { await bridge.refresh() } } }
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
            TextField("Vidéo ou chaîne", text: $query)
                .onSubmit { Task { await search() } }
            Button("Rechercher", systemImage: "magnifyingglass") { Task { await search() } }
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
        .navigationTitle("Recherche")
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
            Section("Sur cet appareil") {
                NavigationLink { WatchVideoListView(title: "Favoris", videos: bridge.localLibrary?.favorites ?? bridge.snapshot.favorites) }
                    label: { Label("Favoris", systemImage: "heart.fill") }
                NavigationLink { WatchVideoListView(title: "À regarder plus tard", videos: bridge.localLibrary?.watchLater ?? bridge.snapshot.watchLater) }
                    label: { Label("À regarder plus tard", systemImage: "clock.fill") }
                NavigationLink { WatchVideoListView(title: "Historique", videos: bridge.localLibrary?.history ?? bridge.snapshot.history) }
                    label: { Label("Historique", systemImage: "arrow.counterclockwise") }
                NavigationLink { WatchDownloadsView() }
                    label: { Label("Téléchargements", systemImage: "arrow.down.circle.fill") }
            }
            Section("Compte Google") {
                if bridge.snapshot.accountSignedIn {
                    NavigationLink { WatchChannelListView() }
                        label: { Label("Abonnements", systemImage: "person.2.fill") }
                    NavigationLink { WatchPlaylistListView() }
                        label: { Label("Playlists", systemImage: "music.note.list") }
                    NavigationLink { WatchVideoListView(title: "Vidéos aimées", videos: account.library.likedVideos) }
                        label: { Label("Vidéos aimées", systemImage: "hand.thumbsup.fill") }
                } else {
                    Text("Connecte ton compte Google sur l’iPhone.").foregroundStyle(.secondary)
                }
            }
            if let message = account.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Bibliothèque")
        .toolbar { Button("Synchroniser", systemImage: "arrow.clockwise") { Task { await refresh() } } }
        .task { await refresh() }
    }

    private func refresh() async {
        guard bridge.isReachable, bridge.snapshot.accountSignedIn else { return }
        do { _ = try await bridge.request("refreshLibrary") }
        catch { account.message = error.localizedDescription }
    }
}

private struct WatchVideoListView: View {
    let title: String
    let videos: [WatchVideo]

    var body: some View {
        List {
            if videos.isEmpty { Text("Aucune vidéo synchronisée.").foregroundStyle(.secondary) }
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
                Text("Aucun abonnement synchronisé.").foregroundStyle(.secondary)
            }
            ForEach(account.library.subscriptions) { channel in
                NavigationLink {
                    WatchAccountVideosView(kind: "channel", id: channel.id, title: channel.title)
                } label: { Text(channel.title).lineLimit(2) }
            }
        }
        .navigationTitle("Abonnements")
    }
}

private struct WatchPlaylistListView: View {
    @EnvironmentObject private var account: WatchAccountLibraryStore

    var body: some View {
        List {
            if account.library.playlists.isEmpty {
                Text("Aucune playlist synchronisée.").foregroundStyle(.secondary)
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
                Text(account.message ?? "Aucune vidéo enregistrée.")
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
            Section("Sur la montre") {
                if downloads.records.isEmpty {
                    Text("Aucun contenu hors ligne.").foregroundStyle(.secondary)
                }
                ForEach(downloads.records) { record in
                    WatchVideoRow(video: record.video)
                        .swipeActions { Button("Supprimer", role: .destructive) { downloads.delete(record.video) } }
                }
            }
            Section("Sur l’iPhone") {
                if (bridge.localLibrary?.downloads ?? bridge.snapshot.downloads).isEmpty {
                    Text("Aucun téléchargement synchronisé.").foregroundStyle(.secondary)
                }
                ForEach(bridge.localLibrary?.downloads ?? bridge.snapshot.downloads) { video in WatchVideoRow(video: video) }
            }
        }
        .navigationTitle("Téléchargements")
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
                    Button("Écouter", systemImage: "play.fill") { Task { await player.play(video) } }
                        .buttonStyle(.borderedProminent)
                    if player.current?.id == video.id {
                        NavigationLink("Lecture en cours") { WatchNowPlayingView() }
                    }
                    Button("Supprimer de la montre", role: .destructive) { downloads.delete(video) }
                } else {
                    Button("Télécharger sur la montre", systemImage: "arrow.down.circle") {
                        downloads.downloadOnWatch(video)
                    }
                    .disabled(!bridge.isReachable || downloads.downloadingID != nil)
                    if (bridge.localLibrary?.downloads ?? bridge.snapshot.downloads).contains(where: { $0.id == video.id }) {
                        Button("Transférer depuis l’iPhone", systemImage: "iphone.gen3.radiowaves.left.and.right") {
                            downloads.transferFromPhone(video)
                        }
                        .disabled(!bridge.isReachable)
                    }
                    if !bridge.isReachable {
                        Text("Rapproche l’iPhone pour préparer le téléchargement.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if downloads.downloadingID == video.id {
                    ProgressView(value: downloads.progress)
                    Button("Arrêter", role: .cancel) { downloads.cancelDownload() }
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
        .navigationTitle("Vidéo")
    }
}

struct WatchNowPlayingView: View {
    @EnvironmentObject private var player: WatchPlayer

    var body: some View {
        VStack(spacing: 10) {
            Text(player.current?.title ?? "Aucune lecture")
                .font(.headline).lineLimit(3).multilineTextAlignment(.center)
            Text(player.current?.channel ?? "")
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 20) {
                Button("Reculer", systemImage: "gobackward.15") { player.seek(by: -15) }
                Button(player.isPlaying ? "Pause" : "Lire",
                       systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.toggle() }
                    .buttonStyle(.borderedProminent)
                Button("Avancer", systemImage: "goforward.15") { player.seek(by: 15) }
            }
            .labelStyle(.iconOnly)
            ProgressView(value: player.duration > 0 ? player.elapsed / player.duration : 0)
            Button("Arrêter", role: .cancel) { player.stop() }
        }
        .navigationTitle("Lecture")
    }
}
