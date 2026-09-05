import SwiftUI

/// Everything below the video in the expanded player: title, actions, channel, description,
/// the up-next queue and comments.
struct PlayerDetailsView: View {
    let video: Video

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var router: AppRouter
    @StateObject private var viewModel: VideoDetailViewModel
    @State private var isDescriptionExpanded = false

    init(video: Video) {
        self.video = video
        _viewModel = StateObject(wrappedValue: VideoDetailViewModel(video: video))
    }

    /// Prefer the enriched copy (view/like counts, full description) once it arrives.
    private var displayed: Video { viewModel.video }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(displayed.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(metadataLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                actionRow
                channelRow

                if !displayed.description.isEmpty {
                    descriptionCard
                }

                if !player.upNext.isEmpty {
                    upNextSection
                }

                commentsSection
            }
            .padding(.horizontal, Theme.Spacing.gutter)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .task { await viewModel.loadAll() }
    }

    private var metadataLine: String {
        var parts: [String] = []
        if let views = displayed.viewCount {
            parts.append("\(CountFormatter.abbreviated(views)) views")
        }
        if let date = displayed.publishedAt {
            parts.append(RelativeDateFormatter.string(from: date))
        }
        return parts.joined(separator: " · ")
    }

    private var actionRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                PlayerActionPill(
                    title: displayed.likeCount.map(CountFormatter.abbreviated) ?? "Like",
                    systemImage: library.isFavorite(displayed) ? "hand.thumbsup.fill" : "hand.thumbsup",
                    isActive: library.isFavorite(displayed)
                ) {
                    library.toggleFavorite(displayed)
                }

                PlayerActionPill(
                    title: "Later",
                    systemImage: library.isInWatchLater(displayed) ? "clock.fill" : "clock",
                    isActive: library.isInWatchLater(displayed)
                ) {
                    library.toggleWatchLater(displayed)
                }

                if let url = displayed.watchURL {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private var channelRow: some View {
        Button {
            // Leaving the player for a channel: shrink rather than stop, like the YouTube app.
            player.collapse()
            router.selectedTab = .home
            router.homePath.append(
                Channel(
                    id: displayed.channelId,
                    title: displayed.channelTitle,
                    description: "",
                    thumbnailURL: nil
                )
            )
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: nil, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayed.channelTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("View channel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .cardBackground()
        }
        .buttonStyle(.plain)
    }

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayed.description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(isDescriptionExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)

            Button(isDescriptionExpanded ? "Show Less" : "Show More") {
                withAnimation(.easeInOut(duration: 0.2)) { isDescriptionExpanded.toggle() }
            }
            .font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardBackground()
    }

    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Up Next")
                .font(.title3.bold())

            ForEach(player.upNext.prefix(10)) { video in
                Button {
                    let index = player.upNext.firstIndex(of: video) ?? 0
                    player.play(video, upNext: Array(player.upNext.dropFirst(index + 1)))
                } label: {
                    VideoRowView(video: video)
                }
                .buttonStyle(.plain)
                .videoContextMenu(video)
            }
        }
    }

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Comments")
                .font(.title3.bold())

            if viewModel.isLoadingComments {
                ProgressView().frame(maxWidth: .infinity)
            } else if let error = viewModel.commentsError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if viewModel.comments.isEmpty {
                Text("No comments yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.comments) { comment in
                    CommentRowView(comment: comment)
                }
            }
        }
    }
}

private struct PlayerActionPill: View {
    let title: String
    let systemImage: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    isActive
                        ? AnyShapeStyle(Color.red.opacity(0.15))
                        : AnyShapeStyle(Color(uiColor: .secondarySystemBackground)),
                    in: Capsule()
                )
                .foregroundStyle(isActive ? Color.red : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

struct CommentRowView: View {
    let comment: VideoComment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: comment.authorAvatarURL, size: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.authorName)
                        .font(.caption.weight(.semibold))
                    Text(RelativeDateFormatter.string(from: comment.publishedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(comment.text)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                if comment.likeCount > 0 {
                    Label("\(comment.likeCount)", systemImage: "hand.thumbsup")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
    }
}
