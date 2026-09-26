import SwiftUI

/// Everything below the video in the expanded player: title, actions, channel, description,
/// the up-next queue and comments.
struct PlayerDetailsView: View {
    let video: Video

    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var watchLater: WatchLaterStore
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var downloads: DownloadStore
    @EnvironmentObject private var downloadManager: DownloadManager
    @StateObject private var viewModel: VideoDetailViewModel
    @State private var isDescriptionExpanded = false
    @State private var newCommentText = ""
    @State private var watchLaterError: String?
    @State private var showsPlaylistPicker = false
    @State private var showsComments = false

    init(video: Video) {
        self.video = video
        _viewModel = StateObject(wrappedValue: VideoDetailViewModel(video: video))
    }

    /// Prefer the enriched copy (view/like counts, full description) once it arrives.
    private var displayed: Video { viewModel.video }

    private var canPostComment: Bool {
        !newCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            #if os(macOS)
            detailsContent
            #else
            ScrollView {
                detailsContent
            }
            .scrollIndicators(.hidden)
            #endif
        }
        .task { await viewModel.loadAll() }
        .sheet(isPresented: $showsPlaylistPicker) {
            PlaylistPickerView(video: displayed)
        }
        #if os(iOS)
        .sheet(isPresented: $showsComments) {
            NavigationStack {
                ScrollView {
                    commentsSection
                        .padding(Theme.Spacing.gutter)
                }
                .navigationTitle("Comments")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsComments = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        #endif
        .alert("Watch Later", isPresented: Binding(
            get: { watchLaterError != nil },
            set: { if !$0 { watchLaterError = nil } }
        )) {
            Button("OK", role: .cancel) { watchLaterError = nil }
        } message: {
            Text(watchLaterError ?? "")
        }
    }

    private var detailsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let issue = player.issue {
                playbackIssueBanner(issue)
            }

            if player.isLocal {
                Label("Playing from your downloads", systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
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

            #if os(macOS)
            commentsSection
            #else
            commentsPreview
            #endif

            if !player.upNext.isEmpty {
                upNextSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.gutter)
        .padding(.top, 16)
        .padding(.bottom, 40)
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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    PlayerActionPill(
                        title: displayed.likeCount.map(CountFormatter.abbreviated) ?? "Like",
                        systemImage: viewModel.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup",
                        isActive: viewModel.isLiked,
                        activeTint: .red,
                        isBusy: viewModel.isRating
                    ) {
                        Haptics.medium()
                        Task { await viewModel.toggleLike() }
                    }

                    PlayerActionPill(
                        title: viewModel.isDisliked ? "Dislike" : "",
                        systemImage: viewModel.isDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                        isActive: viewModel.isDisliked,
                        activeTint: .red,
                        isBusy: viewModel.isRating
                    ) {
                        Haptics.medium()
                        Task { await viewModel.toggleDislike() }
                    }
                    .accessibilityLabel("Dislike")

                    PlayerActionPill(
                        title: "Favorite",
                        systemImage: library.isFavorite(displayed) ? "heart.fill" : "heart",
                        isActive: library.isFavorite(displayed),
                        activeTint: .pink
                    ) {
                        if library.isFavorite(displayed) {
                            Haptics.light()
                        } else {
                            Haptics.medium()
                        }
                        library.toggleFavorite(displayed)
                    }

                    PlayerDownloadPill(
                        video: displayed,
                        store: downloads,
                        manager: downloadManager
                    )

                    PlayerActionPill(
                        title: "Later",
                        systemImage: watchLater.contains(displayed) ? "clock.fill" : "clock",
                        isActive: watchLater.contains(displayed),
                        activeTint: .indigo,
                        isBusy: watchLater.pendingVideoIDs.contains(displayed.id)
                    ) {
                        Haptics.medium()
                        Task {
                            await watchLater.toggle(displayed)
                            watchLaterError = watchLater.errorMessage
                        }
                    }

                    PlayerActionPill(
                        title: "Playlist",
                        systemImage: "text.badge.plus"
                    ) {
                        Haptics.light()
                        showsPlaylistPicker = true
                    }

                    if let url = displayed.watchURL {
                        ShareLink(item: url) {
                            PlayerPillFace(
                                title: "Share",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        .buttonStyle(PillButtonStyle())
                        .simultaneousGesture(TapGesture().onEnded {
                            Haptics.light()
                        })
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
            Haptics.light()
            // Leaving the player for a channel: shrink rather than stop, like the YouTube app.
            player.collapse()
            router.selectedTab = .home
            router.homePath.append(
                viewModel.channel ?? Channel(
                    id: displayed.channelId,
                    title: displayed.channelTitle,
                    description: "",
                    thumbnailURL: viewModel.channelAvatarURL
                )
            )
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: viewModel.channel?.thumbnailURL ?? viewModel.channelAvatarURL, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayed.channelTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let subs = viewModel.channel?.subscriberCount {
                        Text("\(CountFormatter.abbreviated(subs)) subscribers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("View channel")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .cardBackground()
        }
        .buttonStyle(CardButtonStyle())
    }

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayed.description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(isDescriptionExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)

            Button(isDescriptionExpanded ? "Show Less" : "Show More") {
                Haptics.light()
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

    private var commentsPreview: some View {
        Button { showsComments = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Comments")
                        .font(.title3.bold())
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if let comment = viewModel.comments.first {
                    HStack(alignment: .top, spacing: 10) {
                        AvatarView(url: comment.authorAvatarURL, size: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(comment.authorName)
                                .font(.caption.weight(.semibold))
                            Text(comment.text)
                                .font(.footnote)
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                } else if viewModel.isLoadingComments {
                    ProgressView().controlSize(.small)
                } else {
                    Text(viewModel.commentsError ?? "No comments yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .cardBackground()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens all comments")
    }

    private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            #if os(macOS)
            Text("Comments")
                .font(.title3.bold())
            #endif

            HStack(alignment: .center, spacing: 8) {
                TextField("Add a comment", text: $newCommentText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.appSecondaryBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onSubmit { postComment() }

                Button {
                    Haptics.medium()
                    postComment()
                } label: {
                    ZStack {
                        Circle()
                            .fill(canPostComment ? Color.accentColor : Color.appSecondaryBackground)
                            .frame(width: 38, height: 38)

                        if viewModel.isPostingComment {
                            ProgressView()
                                .controlSize(.small)
                                .tint(canPostComment ? .white : .secondary)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(canPostComment ? Color.white : Color.secondary.opacity(0.5))
                        }
                    }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(!canPostComment || viewModel.isPostingComment)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: canPostComment)
                .accessibilityLabel("Post comment")
            }

            if let error = viewModel.commentActionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                    CommentRowView(
                        comment: comment,
                        viewModel: viewModel
                    )
                }
            }
        }
    }

    private func postComment() {
        guard canPostComment else { return }
        let text = newCommentText
        Task {
            if await viewModel.addComment(text) {
                newCommentText = ""
            }
        }
    }
}

/// The download button in the player, in whichever of its four states the video is in.
///
/// It reports progress rather than just "working": a download is the one action in this app that
/// takes minutes, and a pill that only span would leave no way to tell a slow one from a stuck one.
private struct PlayerDownloadPill: View {
    let video: Video
    @ObservedObject var store: DownloadStore
    @ObservedObject var manager: DownloadManager

    var body: some View {
        switch store.state(for: video.id) {
        case .none:
            PlayerActionPill(
                title: "Download",
                systemImage: "arrow.down.circle"
            ) {
                Haptics.medium()
                manager.download(video)
            }

        case .ready:
            PlayerActionPill(
                title: "Downloaded",
                systemImage: "arrow.down.circle.fill",
                isActive: true,
                activeTint: .green
            ) {
                Haptics.light()
                manager.remove(video.id)
            }

        case .failed:
            PlayerActionPill(
                title: "Retry",
                systemImage: "exclamationmark.arrow.circlepath",
                isActive: true,
                activeTint: .orange
            ) {
                Haptics.medium()
                manager.retry(video.id)
            }

        case .paused:
            PlayerActionPill(
                title: "Paused",
                systemImage: "pause.circle",
                isActive: true,
                activeTint: .yellow
            ) {
                Haptics.medium()
                manager.resume(video.id)
            }

        case .some:
            PlayerActionPill(
                title: progressTitle,
                systemImage: "stop.circle",
                isActive: true,
                activeTint: .blue,
                isBusy: false
            ) {
                Haptics.light()
                manager.pause(video.id)
            }
        }
    }

    private var progressTitle: String {
        guard let fraction = manager.progress[video.id], fraction > 0 else { return "Downloading" }
        return "\(Int((fraction * 100).rounded()))%"
    }
}

/// Custom responsive button style giving iOS-like spring scaling and slight opacity change on press.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.82 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.62), value: configuration.isPressed)
    }
}

/// Responsive card button style for subtle press feedback.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

/// Visual face used by all player action pills including ShareLink to ensure strict geometric and design consistency.
struct PlayerPillFace: View {
    let title: String
    let systemImage: String
    var isActive: Bool = false
    var activeTint: Color = .red
    var isBusy: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .symbolEffect(.bounce, value: isActive)
            }

            if !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(isActive ? activeTint : Color.primary)
        .padding(.horizontal, 15)
        .frame(height: 38)
        .background(
            Capsule()
                .fill(isActive ? activeTint.opacity(0.16) : Color.appSecondaryBackground)
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    isActive ? activeTint.opacity(0.35) : Color.primary.opacity(0.06),
                    lineWidth: 0.8
                )
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isActive)
    }
}

private struct PlayerActionPill: View {
    let title: String
    let systemImage: String
    var isActive: Bool = false
    var activeTint: Color = .red
    /// Swaps the icon for a spinner while a write is in flight, so a tap that has to reach
    /// YouTube and back still looks like it landed.
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PlayerPillFace(
                title: title,
                systemImage: systemImage,
                isActive: isActive,
                activeTint: activeTint,
                isBusy: isBusy
            )
        }
        .buttonStyle(PillButtonStyle())
        .disabled(isBusy)
    }
}

struct CommentRowView: View {
    let comment: VideoComment
    @ObservedObject var viewModel: VideoDetailViewModel

    @State private var showsReplies = false
    @State private var showsReplyComposer = false
    @State private var replyText = ""

    private var canPostReply: Bool {
        !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            commentContent(comment, avatarSize: 32)

            HStack(spacing: 16) {
                Button {
                    Haptics.light()
                    Task { await viewModel.toggleCommentLike(comment) }
                } label: {
                    Label(
                        comment.likeCount > 0 ? CountFormatter.abbreviated(comment.likeCount) : "Like",
                        systemImage: comment.isLiked ? "hand.thumbsup.fill" : "hand.thumbsup"
                    )
                    .foregroundStyle(comment.isLiked ? Color.red : Color.secondary)
                }
                .accessibilityHint("Likes or unlikes this comment")
                .disabled(viewModel.ratingComments.contains(comment.id))

                Button("Reply") {
                    withAnimation(.easeInOut(duration: 0.2)) { showsReplyComposer.toggle() }
                }

                if comment.totalReplyCount > 0 || !(viewModel.repliesByParent[comment.id] ?? []).isEmpty {
                    Button(replyButtonTitle) {
                        showsReplies.toggle()
                        if showsReplies {
                            Task { await viewModel.loadReplies(to: comment.id) }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 42)

            if showsReplyComposer {
                replyComposer
                    .padding(.leading, 42)
            }

            if showsReplies {
                replies
                    .padding(.leading, 42)
            }
        }
    }

    private var replyButtonTitle: String {
        let count = max(comment.totalReplyCount, viewModel.repliesByParent[comment.id]?.count ?? 0)
        return showsReplies ? "Hide replies" : "\(count) repl\(count == 1 ? "y" : "ies")"
    }

    @ViewBuilder
    private var replies: some View {
        if viewModel.loadingReplies.contains(comment.id) {
            ProgressView().controlSize(.small)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(viewModel.repliesByParent[comment.id] ?? []) { reply in
                    commentContent(reply, avatarSize: 26)
                }
            }
        }
    }

    private var replyComposer: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("Write a reply", text: $replyText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.appSecondaryBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onSubmit { postReply() }

            Button {
                Haptics.medium()
                postReply()
            } label: {
                ZStack {
                    Circle()
                        .fill(canPostReply ? Color.accentColor : Color.appSecondaryBackground)
                        .frame(width: 32, height: 32)

                    if viewModel.sendingReplyTo.contains(comment.id) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(canPostReply ? .white : .secondary)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(canPostReply ? Color.white : Color.secondary.opacity(0.5))
                    }
                }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(!canPostReply || viewModel.sendingReplyTo.contains(comment.id))
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: canPostReply)
            .accessibilityLabel("Post reply")
        }
    }

    private func commentContent(_ item: VideoComment, avatarSize: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: item.authorAvatarURL, size: avatarSize)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.authorName).font(.caption.weight(.semibold))
                    Text(RelativeDateFormatter.string(from: item.publishedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(item.text)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func postReply() {
        guard canPostReply else { return }
        let text = replyText
        Task {
            if await viewModel.reply(text, to: comment.id) {
                replyText = ""
                showsReplyComposer = false
                showsReplies = true
                await viewModel.loadReplies(to: comment.id)
            }
        }
    }

}
