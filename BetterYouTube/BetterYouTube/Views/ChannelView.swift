import SwiftUI

struct ChannelView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var notificationStore: NotificationStore
    @EnvironmentObject private var notifications: NotificationService
    @StateObject private var viewModel: ChannelViewModel
    private let initialChannel: Channel?
    private let channelId: String

    init(channelId: String, initialChannel: Channel? = nil) {
        _viewModel = StateObject(wrappedValue: ChannelViewModel(channelId: channelId))
        self.initialChannel = initialChannel
        self.channelId = channelId
    }

    private var channel: Channel? { viewModel.channel ?? initialChannel }

    var body: some View {
        Group {
            if viewModel.isLoading && channel == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = viewModel.errorMessage, channel == nil {
                EmptyStateView(title: "Couldn't load channel", message: message)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if let channel {
                            ChannelHeaderView(channel: channel)
                        }

                        Text("Latest Videos")
                            .font(.headline)
                            .padding(.horizontal, Theme.Spacing.gutter)
                        if viewModel.videos.isEmpty {
                            if viewModel.isLoading {
                                ProgressView()
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
                        }
                    }
                }
                .minimizesPlayerBarOnScroll()
            }
        }
        .navigationTitle(channel?.title ?? "Channel")
        .inlineNavigationBar()
        .toolbar {
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
        .task {
            if viewModel.channel == nil { await viewModel.load() }
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
            parts.append("\(CountFormatter.abbreviated(subs)) subscribers")
        }
        if let videos = channel.videoCount {
            parts.append("\(CountFormatter.abbreviated(videos)) videos")
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
