import SwiftUI

struct VideoDetailView: View {
    @StateObject private var viewModel: VideoDetailViewModel
    @EnvironmentObject private var library: LibraryStore
    @State private var isDescriptionExpanded = false

    init(video: Video) {
        _viewModel = StateObject(wrappedValue: VideoDetailViewModel(video: video))
    }

    private var video: Video { viewModel.video }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                YouTubePlayerView(videoId: video.id)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .artworkShadow()
                    .padding(.horizontal, Theme.Spacing.gutter)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 6) {
                    Text(video.title)
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)

                    Text(metadataLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.Spacing.gutter)

                actionRow
                    .padding(.horizontal, Theme.Spacing.gutter)

                channelCard
                    .padding(.horizontal, Theme.Spacing.gutter)

                if !video.description.isEmpty {
                    descriptionCard
                        .padding(.horizontal, Theme.Spacing.gutter)
                }

                commentsSection
                    .padding(.horizontal, Theme.Spacing.gutter)
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let url = video.watchURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationDestination(for: Channel.self) { channel in
            ChannelView(channelId: channel.id, initialChannel: channel.title.isEmpty ? nil : channel)
        }
        .task { viewModel.onAppear() }
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

    private var actionRow: some View {
        HStack(spacing: 10) {
            ActionPill(
                title: video.likeCount.map(CountFormatter.abbreviated) ?? "Like",
                systemImage: library.isFavorite(video) ? "hand.thumbsup.fill" : "hand.thumbsup",
                isActive: library.isFavorite(video)
            ) {
                library.toggleFavorite(video)
            }

            ActionPill(
                title: "Later",
                systemImage: library.isInWatchLater(video) ? "clock.fill" : "clock",
                isActive: library.isInWatchLater(video)
            ) {
                library.toggleWatchLater(video)
            }

            if let url = video.watchURL {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
    }

    private var channelCard: some View {
        NavigationLink(value: Channel(
            id: video.channelId,
            title: video.channelTitle,
            description: "",
            thumbnailURL: nil
        )) {
            HStack(spacing: 12) {
                AvatarView(url: nil, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.channelTitle)
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
            Text(video.description)
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

private struct ActionPill: View {
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
                    isActive ? AnyShapeStyle(Color.red.opacity(0.15)) : AnyShapeStyle(Color(uiColor: .secondarySystemBackground)),
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
        }
    }
}

#Preview {
    NavigationStack {
        VideoDetailView(video: .preview)
    }
    .environmentObject(LibraryStore.shared)
    .environmentObject(GoogleAuthService.shared)
}
