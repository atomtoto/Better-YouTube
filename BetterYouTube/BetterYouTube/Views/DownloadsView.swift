import SwiftUI

/// The Downloads folder, as a screen.
///
/// Two lists, because they answer different questions. What is *here* — playable right now, on a
/// plane, with the phone in flight mode — comes first, because that is what the screen is for.
/// What is still *coming*, or stopped, or went wrong, sits underneath with the buttons to do
/// something about it.
struct DownloadsView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var store: DownloadStore
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var settings: DownloadSettings

    @State private var showsRemoveAllConfirmation = false

    var body: some View {
        Group {
            if store.records.isEmpty {
                emptyState
            } else {
                List {
                    if !store.readyRecords.isEmpty {
                        readySection
                    }
                    if !store.activeRecords.isEmpty {
                        pendingSection
                    }
                    storageSection
                }
                .listStyle(.insetGrouped)
                .minimizesPlayerBarOnScroll()
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.readyRecords.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let videos = store.downloadedVideos
                        guard let first = videos.first else { return }
                        player.play(first, upNext: Array(videos.dropFirst()))
                    } label: {
                        Label("Play All", systemImage: "play.fill")
                    }
                }
            }
        }
        .alert("Download failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) { manager.lastError = nil }
        } message: {
            Text(manager.lastError ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { manager.lastError != nil },
            set: { if !$0 { manager.lastError = nil } }
        )
    }

    // MARK: - Sections

    private var readySection: some View {
        Section {
            ForEach(store.readyRecords) { record in
                Button {
                    // The queue is the rest of the folder, so a downloaded video rolls on into
                    // the next downloaded one rather than stopping dead with no network.
                    let videos = store.downloadedVideos
                    player.play(record.video, upNext: videos.after(record.video))
                } label: {
                    DownloadRowView(record: record)
                }
                .buttonStyle(.plain)
                .videoContextMenu(record.video)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        manager.remove(record.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("On This Device")
        } footer: {
            Text("These play with no network at all — here, and anywhere else the video turns up in the app.")
        }
    }

    private var pendingSection: some View {
        Section("Downloading") {
            ForEach(store.activeRecords) { record in
                DownloadProgressRow(record: record)
            }
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent(
                "Storage Used",
                value: ByteCountFormatter.string(fromByteCount: store.bytesOnDisk(), countStyle: .file)
            )
            Button("Remove All Downloads", role: .destructive) {
                showsRemoveAllConfirmation = true
            }
        } footer: {
            Text("The folder is “Downloads” in the app's documents, which the Files app shows under “Better YouTube”.")
        }
        .confirmationDialog(
            "Remove all downloads?",
            isPresented: $showsRemoveAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) { manager.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files go from this device. Nothing changes on your YouTube account, and you can download them again.")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if settings.isConfigured {
            EmptyStateView(
                title: "No downloads yet",
                systemImage: "arrow.down.circle",
                message: "Hold any video and choose Download. It lands in the Downloads folder and plays from there wherever you find it again — including with no network."
            )
        } else {
            VStack(spacing: 14) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary)
                Text("Downloads are off")
                    .font(.headline)
                Text("""
                The app plays video through YouTube's own embed, which never exposes a media file — \
                so it has no way to fetch one on its own. Point it at a download service you run \
                and everything here starts working.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

                NavigationLink {
                    SettingsView()
                } label: {
                    Text("Open Settings")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(Theme.Spacing.gutter * 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A finished download: artwork from the disk, so the row draws with no network.
struct DownloadRowView: View {
    let record: DownloadRecord
    @EnvironmentObject private var store: DownloadStore

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ArtworkView(url: store.artworkURL(for: record.video), duration: record.video.duration)
                .frame(width: Theme.Size.compactThumbnail, height: Theme.Size.compactThumbnail * 9 / 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.video.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                Text(record.video.channelTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            Image(systemName: "arrow.down.circle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts = [record.quality.title]
        if !record.sizeDescription.isEmpty { parts.append(record.sizeDescription) }
        return parts.joined(separator: " · ")
    }
}

/// A download that hasn't landed yet — or stopped on the way, which is the case worth designing
/// for: it says what happened and offers the one button that helps.
struct DownloadProgressRow: View {
    let record: DownloadRecord
    @EnvironmentObject private var store: DownloadStore
    @EnvironmentObject private var manager: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ArtworkView(url: store.artworkURL(for: record.video))
                    .frame(width: 88, height: 88 * 9 / 16)

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.video.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(isFailed ? Color.orange : Color.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if !isFailed {
                ProgressView(value: fraction)
                    .tint(.red)
            }

            HStack(spacing: 14) {
                switch record.state {
                case .downloading, .resolving, .queued:
                    Button("Pause") { manager.pause(record.id) }
                case .paused:
                    Button("Resume") { manager.resume(record.id) }
                case .failed:
                    Button("Try Again") { manager.retry(record.id) }
                case .ready:
                    EmptyView()
                }

                Button("Remove", role: .destructive) { manager.remove(record.id) }

                Spacer()
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var isFailed: Bool {
        if case .failed = record.state { return true }
        return false
    }

    /// Live progress while a transfer is running, and the manifest's own figure otherwise — which
    /// is what keeps a paused download's bar where it was rather than at zero.
    private var fraction: Double {
        manager.progress[record.id] ?? record.fraction
    }

    private var statusLine: String {
        switch record.state {
        case .queued:
            return "Waiting…"
        case .resolving:
            return "Finding the file…"
        case .downloading:
            let percent = Int((fraction * 100).rounded())
            let size = record.totalBytes > 0
                ? " of \(ByteCountFormatter.string(fromByteCount: record.totalBytes, countStyle: .file))"
                : ""
            return record.totalBytes > 0 ? "\(percent)%\(size)" : "Downloading…"
        case .paused:
            return "Paused"
        case .ready:
            return "Downloaded"
        case .failed(let reason):
            return reason
        }
    }
}

// MARK: - The download action, wherever a video is offered

/// The Download entry in a video's menu.
///
/// One button covering every state a video can be in, because a menu row that changes its mind is
/// easier to use than four rows that are usually disabled: it downloads, or it cancels what is in
/// flight, or it removes what is already here.
struct DownloadMenuButton: View {
    let video: Video
    /// Handed in rather than read from the environment, for the same reason `PlayerActions` is:
    /// this is built inside a menu, which is a presentation of its own, and an
    /// `@EnvironmentObject` resolved in there has no owner to find.
    @ObservedObject var store: DownloadStore
    @ObservedObject var manager: DownloadManager

    var body: some View {
        switch store.state(for: video.id) {
        case .none:
            Button {
                manager.download(video)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }

        case .ready:
            Button(role: .destructive) {
                manager.remove(video.id)
            } label: {
                Label("Remove Download", systemImage: "trash")
            }

        case .failed:
            Button {
                manager.retry(video.id)
            } label: {
                Label("Retry Download", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                manager.remove(video.id)
            } label: {
                Label("Cancel Download", systemImage: "xmark")
            }

        case .paused:
            Button {
                manager.resume(video.id)
            } label: {
                Label("Resume Download", systemImage: "arrow.down.circle")
            }
            Button(role: .destructive) {
                manager.remove(video.id)
            } label: {
                Label("Cancel Download", systemImage: "xmark")
            }

        case .some:
            Button(role: .destructive) {
                manager.remove(video.id)
            } label: {
                Label("Cancel Download", systemImage: "xmark")
            }
        }
    }
}

/// The small mark on a card's artwork saying this one is on the device.
///
/// Deliberately the same glyph in the same corner everywhere, because its whole job is to be
/// recognised without being read.
struct DownloadedBadge: View {
    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.caption)
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.55), in: Circle())
            .padding(6)
    }
}

#Preview {
    NavigationStack { DownloadsView() }
        .environmentObject(PlayerManager.shared)
        .environmentObject(DownloadStore.shared)
        .environmentObject(DownloadManager.shared)
        .environmentObject(DownloadSettings.shared)
        .environmentObject(LibraryStore.shared)
        .environmentObject(WatchLaterStore.shared)
}
