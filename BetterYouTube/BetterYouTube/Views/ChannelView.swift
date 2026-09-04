import SwiftUI

struct ChannelView: View {
    @StateObject private var viewModel: ChannelViewModel
    private let initialChannel: Channel?

    init(channelId: String, initialChannel: Channel? = nil) {
        _viewModel = StateObject(wrappedValue: ChannelViewModel(channelId: channelId))
        self.initialChannel = initialChannel
    }

    private var displayChannel: Channel? { viewModel.channel ?? initialChannel }

    var body: some View {
        Group {
            if viewModel.isLoading && displayChannel == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message = viewModel.errorMessage, displayChannel == nil {
                EmptyStateView(title: "Couldn't load channel", message: message)
            } else {
                List {
                    if let channel = displayChannel {
                        Section {
                            ChannelHeaderView(channel: channel)
                                .listRowInsets(EdgeInsets())
                        }
                    }
                    Section("Videos") {
                        ForEach(viewModel.videos) { video in
                            NavigationLink(value: video) {
                                VideoRowView(video: video)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(displayChannel?.title ?? "Channel")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Video.self) { video in
            VideoDetailView(video: video)
        }
        .task {
            if viewModel.channel == nil {
                await viewModel.load()
            }
        }
    }
}

struct ChannelHeaderView: View {
    let channel: Channel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                AsyncImage(url: channel.thumbnailURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Circle().fill(Color.gray.opacity(0.25))
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.title)
                        .font(.headline)
                    if let subs = channel.subscriberCount {
                        Text("\(CountFormatter.abbreviated(subs)) subscribers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let count = channel.videoCount {
                        Text("\(count) videos")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !channel.description.isEmpty {
                Text(channel.description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding()
    }
}

#Preview {
    NavigationStack {
        ChannelView(channelId: "UC123")
    }
    .environmentObject(APIKeyStore.shared)
    .environmentObject(LibraryStore.shared)
}
