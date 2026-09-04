import SwiftUI

struct VideoDetailView: View {
    @StateObject private var viewModel: VideoDetailViewModel
    @State private var isDescriptionExpanded = false

    init(video: Video) {
        _viewModel = StateObject(wrappedValue: VideoDetailViewModel(video: video))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                YouTubePlayerView(videoId: viewModel.video.id)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)

                VStack(alignment: .leading, spacing: 16) {
                    Text(viewModel.video.title)
                        .font(.title3.weight(.semibold))

                    metadataRow

                    actionRow

                    Divider()

                    NavigationLink(value: Channel(
                        id: viewModel.video.channelId,
                        title: viewModel.video.channelTitle,
                        description: "",
                        thumbnailURL: nil
                    )) {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(viewModel.video.channelTitle)
                                    .font(.subheadline.weight(.semibold))
                                Text("View channel")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)

                    if !viewModel.video.description.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text(viewModel.video.description)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(isDescriptionExpanded ? nil : 3)
                            Button(isDescriptionExpanded ? "Show less" : "Show more") {
                                withAnimation { isDescriptionExpanded.toggle() }
                            }
                            .font(.caption.weight(.semibold))
                        }
                    }

                    Divider()
                    commentsSection
                }
                .padding()
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Channel.self) { channel in
            ChannelView(channelId: channel.id, initialChannel: channel.title.isEmpty ? nil : channel)
        }
        .task { viewModel.onAppear() }
    }

    private var metadataRow: some View {
        HStack {
            if let views = viewModel.video.viewCount {
                Text("\(CountFormatter.abbreviated(views)) views")
            }
            if viewModel.video.viewCount != nil && viewModel.video.publishedAt != nil {
                Text("•")
            }
            if let date = viewModel.video.publishedAt {
                Text(RelativeDateFormatter.string(from: date))
            }
            Spacer()
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var actionRow: some View {
        HStack(spacing: 24) {
            Button {
                viewModel.toggleFavorite()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: viewModel.isFavorite ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(viewModel.isFavorite ? .red : .primary)
                    Text("Like")
                        .font(.caption2)
                }
            }

            Button {
                viewModel.toggleWatchLater()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: viewModel.isInWatchLater ? "clock.badge.checkmark.fill" : "clock.badge.plus")
                        .font(.title3)
                    Text("Watch later")
                        .font(.caption2)
                }
            }

            if let likes = viewModel.video.likeCount {
                VStack(spacing: 4) {
                    Image(systemName: "hand.thumbsup")
                        .font(.title3)
                    Text(CountFormatter.abbreviated(likes))
                        .font(.caption2)
                }
            }

            Spacer()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comments")
                .font(.headline)

            if viewModel.isLoadingComments {
                ProgressView()
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

struct CommentRowView: View {
    let comment: VideoComment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: comment.authorAvatarURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Circle().fill(Color.gray.opacity(0.25))
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(comment.authorName)
                        .font(.caption.weight(.semibold))
                    Text(RelativeDateFormatter.string(from: comment.publishedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(comment.text)
                    .font(.footnote)
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
        VideoDetailView(video: Video(
            id: "dQw4w9WgXcQ",
            title: "Example video",
            channelId: "UC123",
            channelTitle: "Example Channel",
            description: "A sample description that is reasonably long so the show more button has something to do.",
            thumbnailURL: nil,
            publishedAt: Date(),
            viewCount: 1_234_567,
            likeCount: 12_345,
            duration: "3:45"
        ))
    }
    .environmentObject(APIKeyStore.shared)
    .environmentObject(LibraryStore.shared)
}
