import SwiftUI

/// Large artwork-forward card used in the home carousels.
struct VideoCardView: View {
    let video: Video
    var width: CGFloat = Theme.Size.carouselCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(url: video.thumbnailURL, duration: video.duration, cornerRadius: Theme.Radius.card)
                .frame(width: width, height: width * 9 / 16)
                .artworkShadow()

            VStack(alignment: .leading, spacing: 2) {
                Text(video.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(video.channelTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

/// Full-width feed card: big artwork, then avatar + title + metadata, the way the YouTube app
/// lays out its home feed — with Apple's type scale, corner radii and materials.
struct FeedVideoCard: View {
    let video: Video
    var avatarURL: URL?

    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ArtworkView(url: video.thumbnailURL, duration: video.duration, cornerRadius: Theme.Radius.card)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .artworkShadow()

            HStack(alignment: .top, spacing: 10) {
                AvatarView(url: avatarURL, size: 36)

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

                Menu {
                    Button {
                        library.toggleWatchLater(video)
                    } label: {
                        Label(
                            library.isInWatchLater(video) ? "Remove from Watch Later" : "Save to Watch Later",
                            systemImage: library.isInWatchLater(video) ? "clock.badge.xmark" : "clock"
                        )
                    }
                    Button {
                        library.toggleFavorite(video)
                    } label: {
                        Label(
                            library.isFavorite(video) ? "Remove from Favorites" : "Add to Favorites",
                            systemImage: library.isFavorite(video) ? "heart.slash" : "heart"
                        )
                    }
                    if let url = video.watchURL {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.gutter)
        .contentShape(Rectangle())
    }

    private var metadataLine: String {
        var parts: [String] = []
        if !video.channelTitle.isEmpty { parts.append(video.channelTitle) }
        if let views = video.viewCount { parts.append("\(CountFormatter.abbreviated(views)) views") }
        if let date = video.publishedAt { parts.append(RelativeDateFormatter.string(from: date)) }
        return parts.joined(separator: " · ")
    }
}

/// Compact list row, mirroring the density of Apple Music's track rows.
struct VideoRowView: View {
    let video: Video
    var showsChannel: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ArtworkView(url: video.thumbnailURL, duration: video.duration)
                .frame(width: Theme.Size.compactThumbnail, height: Theme.Size.compactThumbnail * 9 / 16)

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
            parts.append("\(CountFormatter.abbreviated(views)) views")
        }
        if let date = video.publishedAt {
            parts.append(RelativeDateFormatter.string(from: date))
        }
        return parts.joined(separator: " · ")
    }
}

/// Full-bleed hero used at the top of Home, in the spirit of Apple Music's featured shelf.
struct FeaturedVideoCard: View {
    let video: Video

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(url: video.thumbnailURL, duration: video.duration, cornerRadius: Theme.Radius.hero)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .artworkShadow()
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.channelTitle.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.8))
                        Text(video.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        LinearGradient(
                            colors: [.black.opacity(0), .black.opacity(0.75)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .clipShape(
                        RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
                    )
                    .allowsHitTesting(false)
                }
        }
        .contentShape(Rectangle())
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
            return "\(CountFormatter.abbreviated(subs)) subscribers"
        }
        return "Channel"
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 24) {
            FeaturedVideoCard(video: .preview)
            VideoCardView(video: .preview)
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
