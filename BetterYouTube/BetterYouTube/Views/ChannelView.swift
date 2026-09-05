import SwiftUI

struct ChannelView: View {
    @StateObject private var viewModel: ChannelViewModel
    private let initialChannel: Channel?

    init(channelId: String, initialChannel: Channel? = nil) {
        _viewModel = StateObject(wrappedValue: ChannelViewModel(channelId: channelId))
        self.initialChannel = initialChannel
    }

    private var channel: Channel? { viewModel.channel ?? initialChannel }

    var body: some View {
        Group {
            if viewModel.isLoading && channel == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = viewModel.errorMessage, channel == nil {
                EmptyStateView(title: "Couldn't load channel", message: message)
            } else {
                List {
                    if let channel {
                        Section {
                            ChannelHeaderView(channel: channel)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }

                    Section("Latest Videos") {
                        if viewModel.videos.isEmpty && viewModel.isLoading {
                            ProgressView()
                        }
                        ForEach(viewModel.videos) { video in
                            NavigationLink(value: video) {
                                VideoRowView(video: video, showsChannel: false)
                            }
                            .videoContextMenu(video)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(channel?.title ?? "Channel")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Video.self) { VideoDetailView(video: $0) }
        .task {
            if viewModel.channel == nil { await viewModel.load() }
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
}
