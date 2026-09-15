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
                if let issue = player.issue {
                    playbackIssueBanner(issue)
                }

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

    /// Surfaces what actually went wrong rather than leaving a silent black player.
    private func playbackIssueBanner(_ issue: PlaybackIssue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This video didn't start", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            Text(Self.explanation(for: issue))
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text(Self.detail(for: issue, videoId: displayed.id))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)

            if let url = displayed.watchURL {
                Link("Open in YouTube", destination: url)
                    .font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardBackground()
    }

    private static func explanation(for issue: PlaybackIssue) -> String {
        switch issue {
        case .playerError(let code):
            switch code {
            case 2: return "YouTube rejected the video ID."
            case 5: return "The video can't play in this HTML5 player."
            case 100: return "The video was removed or made private."
            case 101, 150: return "The channel doesn't allow this video to play outside YouTube."
            default: return "YouTube's player refused to start this video."
            }
        case .loadFailed:
            return "The player page couldn't load — check the network connection."
        case .noResponse:
            return "The player page loaded but never started. This is a bug in the app, not in the video."
        }
    }

    private static func detail(for issue: PlaybackIssue, videoId: String) -> String {
        switch issue {
        case .playerError(let code):
            return "player error \(code) · video \(videoId)"
        case .loadFailed(let message):
            return "load failed: \(message) · video \(videoId)"
        case .noResponse:
            return "no handshake after 8s · video \(videoId)"
        }
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

    /// The thumbs-up is the real like — a `videos.rate` write to the account, which is what
    /// puts the video in Liked videos here and in the YouTube app. The heart beside it is this
    /// device's own favourites list, which is what the thumbs-up used to be: tapping it looked
    /// like liking a video on YouTube and never left the phone.
    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    PlayerActionPill(
                        title: displayed.likeCount.map(CountFormatter.abbreviated) ?? "Like",
                        systemImage: viewModel.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup",
                        isActive: viewModel.isLiked,
                        isBusy: viewModel.isRating
                    ) {
                        Task { await viewModel.toggleLike() }
                    }

                    PlayerActionPill(
                        title: "Favorite",
                        systemImage: library.isFavorite(displayed) ? "heart.fill" : "heart",
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

            // Nearly always "sign in with Google", which is the one thing worth saying here.
            if let ratingError = viewModel.ratingError {
                Text(ratingError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
    /// Swaps the icon for a spinner while a write is in flight, so a tap that has to reach
    /// YouTube and back still looks like it landed.
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            pill
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
        .disabled(isBusy)
    }

    private var pill: some View {
        Label {
            Text(title)
        } icon: {
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }
        }
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
