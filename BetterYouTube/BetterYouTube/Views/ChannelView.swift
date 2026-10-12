import SwiftUI

struct ChannelView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var auth: GoogleAuthService
    @EnvironmentObject private var notificationStore: NotificationStore
    @EnvironmentObject private var notifications: NotificationService
    @StateObject private var viewModel: ChannelViewModel
    @State private var confirmsUnsubscribe = false
    @State private var section = Section.videos

    /// The two halves of a channel page, as on YouTube.
    private enum Section: Hashable {
        case videos, playlists
    }
    private let initialChannel: Channel?
    private let channelId: String
    /// The signed-in account's own channel, opened from Library: nothing to subscribe to and
    /// nothing to be notified about, so neither the button nor the bell is shown.
    private let isOwnChannel: Bool

    init(channelId: String, initialChannel: Channel? = nil, isOwnChannel: Bool = false) {
        _viewModel = StateObject(wrappedValue: ChannelViewModel(channelId: channelId))
        self.initialChannel = initialChannel
        self.channelId = channelId
        self.isOwnChannel = isOwnChannel
    }

    private var channel: Channel? { viewModel.channel ?? initialChannel }

    var body: some View {
        Group {
            if viewModel.isLoading && channel == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = viewModel.errorMessage, channel == nil {
                ContentUnavailableView("Couldn't Load Channel", systemImage: "exclamationmark.triangle", description: Text(message))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if let channel {
                            ChannelHeaderView(channel: channel)
                        }

                        if !isOwnChannel {
                            subscribeButton
                                .frame(maxWidth: .infinity)
                        }

                        Picker("Show", selection: $section) {
                            Text("Videos").tag(Section.videos)
                            Text("Playlists").tag(Section.playlists)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal, Theme.Spacing.gutter)

                        switch section {
                        case .videos: videos
                        case .playlists: playlists
                        }
                    }
                }
                .minimizesPlayerBarOnScroll()
            }
        }
        .navigationTitle(channel?.title ?? String(localized: "Channel"))
        .inlineNavigationBar()
        .toolbar {
            if !isOwnChannel {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        toggleNotifications()
                    } label: {
                        Image(systemName: notificationStore.isOptedIn(channelId) ? "bell.fill" : "bell")
                    }
                    .accessibilityLabel(
                        notificationStore.isOptedIn(channelId)
                            ? "Turn off notifications for this channel"
                            : "Notify me about new videos from this channel"
                    )
                }
            }
        }
        .task {
            if viewModel.channel == nil { await viewModel.load() }
        }
        .task(id: auth.isSignedIn) {
            // A unit saved: nobody subscribes to their own channel.
            guard !isOwnChannel else { return }
            await viewModel.loadSubscription(isSignedIn: auth.isSignedIn)
        }
        // Felt when YouTube confirms the change, not on the tap: subscribing is a round trip, and
        // the first read of the state is no change at all.
        .sensoryFeedback(trigger: viewModel.subscription) { old, new in
            guard old != .unknown, new != .unknown else { return nil }
            return .impact(weight: .medium)
        }
        .sensoryFeedback(.error, trigger: viewModel.subscriptionError) { _, new in new != nil }
        .confirmationDialog(
            channel.map { Text("Unsubscribe from \($0.title)?") } ?? Text("Unsubscribe from this channel?"),
            isPresented: $confirmsUnsubscribe,
            titleVisibility: .visible
        ) {
            Button("Unsubscribe", role: .destructive) {
                Task { await viewModel.toggleSubscription() }
            }
        }
        .alert("Subscription", isPresented: Binding(
            get: { viewModel.subscriptionError != nil },
            set: { if !$0 { viewModel.subscriptionError = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.subscriptionError = nil }
        } message: {
            Text(viewModel.subscriptionError ?? "")
        }
    }

    /// The uploads, newest first.
    @ViewBuilder
    private var videos: some View {
        if viewModel.videos.isEmpty {
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if viewModel.errorMessage == nil {
                // Most people's own channel, opened from Library, has never uploaded anything.
                ContentUnavailableView(
                    "No Videos",
                    systemImage: "play.rectangle",
                    description: Text("This channel hasn't uploaded any videos.")
                )
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 440), spacing: 18)], spacing: 24) {
                ForEach(viewModel.videos) { video in
                    FeedVideoCard(video: video, onPlay: {
                        player.play(video, upNext: viewModel.videos.after(video))
                    })
                    .videoContextMenu(video)
                }
            }
            .padding(.horizontal, Theme.Spacing.gutter)

            if viewModel.canLoadMore {
                LoadMoreFooter(
                    error: viewModel.loadMoreError,
                    trigger: viewModel.videos.count
                ) {
                    await viewModel.loadMore()
                }
            }
        }
    }

    /// The playlists the channel has made public — read the first time this half is shown, so a
    /// visit for the latest video costs nothing more.
    @ViewBuilder
    private var playlists: some View {
        if viewModel.playlists.isEmpty {
            if let error = viewModel.playlistsError {
                ContentUnavailableView {
                    Label("Couldn't Load Playlists", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") {
                        Task { await viewModel.loadPlaylists() }
                    }
                }
            } else if viewModel.hasLoadedPlaylists {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text("This channel has no public playlists.")
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .task {
                        // Its own task: switching back to Videos mid-request would cancel the
                        // view's, and the cancelled request would come back as an error.
                        await Task { await viewModel.loadPlaylists() }.value
                    }
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 440), spacing: 18)], spacing: 24) {
                ForEach(viewModel.playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(playlist: playlist)
                    } label: {
                        PlaylistCardView(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.gutter)

            if viewModel.canLoadMorePlaylists {
                LoadMoreFooter(
                    error: viewModel.playlistsError,
                    trigger: viewModel.playlists.count
                ) {
                    await viewModel.loadPlaylists()
                }
            }
        }
    }

    /// The account's real subscription — a `subscriptions.insert` or `delete` on YouTube, the
    /// same list Library's Subscriptions reads. Only shown signed in, once the state is known.
    @ViewBuilder
    private var subscribeButton: some View {
        switch viewModel.subscription {
        case .unknown:
            EmptyView()
        case .notSubscribed:
            Button {
                Task { await viewModel.toggleSubscription() }
            } label: {
                Text("Subscribe")
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(viewModel.isChangingSubscription)
        case .subscribed:
            Button {
                confirmsUnsubscribe = true
            } label: {
                Label("Subscribed", systemImage: "checkmark")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(viewModel.isChangingSubscription)
        }
    }

    /// Turning the bell on for the first time also asks for system permission.
    private func toggleNotifications() {
        let wasOptedIn = notificationStore.isOptedIn(channelId)
        notificationStore.toggleOptIn(channelId)
        guard !wasOptedIn else { return }
        Task {
            if notifications.authorizationStatus == .notDetermined {
                await notifications.requestAuthorization()
            }
        }
    }
}

struct ChannelHeaderView: View {
    let channel: Channel

    var body: some View {
        VStack(spacing: 12) {
            AvatarView(url: channel.thumbnailURL, size: 96)
                .artworkShadow()

            VStack(spacing: 4) {
                Text(channel.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(statsLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !channel.description.isEmpty {
                Text(channel.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, Theme.Spacing.gutter)
    }

    private var statsLine: String {
        var parts: [String] = []
        if let subs = channel.subscriberCount {
            parts.append(CountFormatter.subscribers(subs))
        }
        if let videos = channel.videoCount {
            parts.append(CountFormatter.videos(videos))
        }
        return parts.joined(separator: " · ")
    }
}

#Preview {
    NavigationStack {
        ChannelView(channelId: "UC1", initialChannel: Channel(
            id: "UC1",
            title: "Example Channel",
            description: "A channel used for previews.",
            thumbnailURL: nil,
            subscriberCount: 128_000,
            videoCount: 342
        ))
    }
    .environmentObject(LibraryStore.shared)
    .environmentObject(WatchLaterStore.shared)
        .environmentObject(NotificationStore.shared)
        .environmentObject(NotificationService.shared)
        .environmentObject(DownloadStore.shared)
        .environmentObject(DownloadManager.shared)
        .environmentObject(DownloadSettings.shared)
        .environmentObject(PlayerManager.shared)
}
