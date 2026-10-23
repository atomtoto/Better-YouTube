import SwiftUI

/// Full-width feed card: big artwork, then avatar + title + metadata, the way the YouTube app
/// lays out its home feed — with Apple's type scale, corner radii and materials.
struct FeedVideoCard: View {
    @State private var saveError: String?
    @State private var showsPlaylistPicker = false
    let video: Video
    var avatarURL: URL?
    /// Off on the channel's own page, where the avatar would only open the page you are on.
    var linksToChannel = true
    var onPlay: () -> Void
    var onNotInterested: (() -> Void)? = nil

    @EnvironmentObject private var downloads: DownloadStore
    @ObservedObject private var positions = PlaybackPositionStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onPlay) {
                ArtworkView(
                    url: downloads.artworkURL(for: video),
                    duration: video.duration,
                    cornerRadius: Theme.Radius.card,
                    progress: positions.watchedFraction(for: video.id)
                )
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .artworkShadow()
                    .downloadedBadge(video, downloads: downloads)
            }
            .buttonStyle(.plain)

            HStack(alignment: .top, spacing: 10) {
                avatar

                Button(action: onPlay) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(video.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            Text(metadataLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    VideoMenuItems(
                        video: video,
                        showPlaylistPicker: { showsPlaylistPicker = true },
                        reportWatchLaterError: { saveError = $0 },
                        onNotInterested: onNotInterested
                    )
                } label: {
                    #if os(macOS)
                    Label("More", systemImage: "chevron.down.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 23))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                        .frame(width: 42, height: 42)
                        .contentShape(Rectangle())
                    #else
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        // The glyph keeps its place in the 28 points it always had; the finger
                        // gets the 44 a touch target needs, reaching into the space around it.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .padding(-8)
                    #endif
                }
                #if os(macOS)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                #endif
            }
        }
        .contentShape(Rectangle())
        .sheet(isPresented: $showsPlaylistPicker) { PlaylistPickerView(video: video) }
        .alert("Watch Later", isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    /// The avatar opens the channel, like the YouTube app's; the rest of the card plays.
    @ViewBuilder
    private var avatar: some View {
        if linksToChannel, !video.channelId.isEmpty {
            NavigationLink(value: Channel(
                id: video.channelId,
                title: video.channelTitle,
                description: "",
                thumbnailURL: avatarURL
            )) {
                AvatarView(url: avatarURL, size: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(video.channelTitle.isEmpty ? String(localized: "Channel") : video.channelTitle)
            .accessibilityHint("Opens the channel")
        } else {
            AvatarView(url: avatarURL, size: 36)
        }
    }

    private var metadataLine: String {
        var parts: [String] = []
        if !video.channelTitle.isEmpty { parts.append(video.channelTitle) }
        if let views = video.viewCount { parts.append(CountFormatter.views(views)) }
        if let date = video.publishedAt { parts.append(RelativeDateFormatter.string(from: date)) }
        return parts.joined(separator: " · ")
    }
}

/// Compact list row, mirroring the density of Apple Music's track rows.
struct VideoRowView: View {
    let video: Video
    var showsChannel: Bool = true

    @EnvironmentObject private var downloads: DownloadStore
    @ObservedObject private var positions = PlaybackPositionStore.shared

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ArtworkView(
                url: downloads.artworkURL(for: video),
                duration: video.duration,
                progress: positions.watchedFraction(for: video.id)
            )
                .frame(width: Theme.Size.compactThumbnail, height: Theme.Size.compactThumbnail * 9 / 16)
                .downloadedBadge(video, downloads: downloads)

            VStack(alignment: .leading, spacing: 3) {
                Text(video.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                if showsChannel {
                    Text(video.channelTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !metadataLine.isEmpty {
                    Text(metadataLine)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var metadataLine: String {
        var parts: [String] = []
        if let views = video.viewCount {
            parts.append(CountFormatter.views(views))
        }
        if let date = video.publishedAt {
            parts.append(RelativeDateFormatter.string(from: date))
        }
        return parts.joined(separator: " · ")
    }
}

/// Channel row with a circular avatar, used in search results and subscription lists.
struct ChannelRowView: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: channel.thumbnailURL, size: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        if let subs = channel.subscriberCount {
            return CountFormatter.subscribers(subs)
        }
        return String(localized: "Channel")
    }
}

extension View {
    /// Marks artwork whose video is already on the device.
    ///
    /// Every card and row takes this, so "is this downloaded?" is answered in the same place and
    /// the same way wherever a video appears — which is the point of downloading it at all.
    @ViewBuilder
    func downloadedBadge(_ video: Video, downloads: DownloadStore) -> some View {
        if downloads.isDownloaded(video.id) {
            overlay(alignment: .topLeading) { DownloadedBadge() }
        } else {
            self
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 24) {
            FeedVideoCard(video: .preview, onPlay: {})
            VideoRowView(video: .preview)
            ChannelRowView(channel: Channel(
                id: "UC1",
                title: "Example Channel",
                description: "",
                thumbnailURL: nil,
                subscriberCount: 128_000
            ))
        }
        .padding()
    }
    .environmentObject(DownloadStore.shared)
    .environmentObject(DownloadManager.shared)
    .environmentObject(PlayerManager.shared)
}

extension Video {
    /// Sample data for SwiftUI previews.
    static let preview = Video(
        id: "dQw4w9WgXcQ",
        title: "A fairly long example video title that needs two lines to render",
        channelId: "UC1",
        channelTitle: "Example Channel",
        description: "An example description.",
        thumbnailURL: nil,
        publishedAt: Date().addingTimeInterval(-86_400 * 3),
        viewCount: 1_284_000,
        likeCount: 42_000,
        duration: "12:04"
    )
}
